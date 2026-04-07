//
//  Subscription.m
//  ADK
//

#import "Subscription.h"
#import "LogTracer.h"

@implementation Subscription

- (instancetype)initWithConnectionID:(NSString *)connectionID
                       channelConfig:(ChannelConfig *)channelConfig
                    websocketHandler:(id<WebsocketHandler>)websocketHandler
                             process:(NSString *)process {
    self = [super initWithConnectionID:connectionID
                         channelConfig:channelConfig
                      websocketHandler:websocketHandler
                               process:process];
    return self;
}

- (void)listen:(void (^)(NSDictionary<NSString *, id> *))callback {

    NSDictionary<NSString *, NSMutableArray<NSDictionary *> *> *bufferCopy =
        [self.messageBuffer copy];
    for (NSString *evt in bufferCopy) {
        NSArray<NSDictionary *> *msgs = bufferCopy[evt];
        for (NSDictionary *reqData in msgs) {
            callback(@{
                @"event" : evt,
                @"content" : reqData[@"content"] ?: [NSNull null]
            });
            [self acknowledge:reqData returnFlag:@"CA"];
        }
    }
    [self.messageBuffer removeAllObjects];

    [self.emitter on:@"all"
             handler:^(id data) {
               if ([data isKindOfClass:[NSDictionary class]]) {
                   callback((NSDictionary *)data);
               }
             }];
}

- (void)bind:(NSString *)event callback:(void (^)(id))callback {

    NSMutableArray<NSDictionary *> *msgs = self.messageBuffer[event];
    if (msgs) {
        for (NSDictionary *reqData in msgs) {
            callback(reqData[@"content"] ?: [NSNull null]);
            [self acknowledge:reqData returnFlag:@"CA"];
        }
        [self.messageBuffer removeObjectForKey:event];
    }

    [self.emitter on:event handler:callback];
}

- (void)remove:(NSString *)event {
    [self.emitter offEvent:event];
    [self.messageBuffer removeObjectForKey:event];
}

- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload {

    NSString *returnFlag = payload[@"return_flag"];
    if (![returnFlag isKindOfClass:[NSString class]])
        returnFlag = @"";

    if ([returnFlag isEqualToString:@"SA"]) {
        [self handleMessageAcks:event returnFlag:returnFlag data:payload];
        return;
    }

    [self acknowledge:payload returnFlag:@"MA"];

    NSMutableDictionary *mutablePayload = [payload mutableCopy];

    // -------------------------------------------------------
    // SECURE CHANNEL DECRYPT
    // -------------------------------------------------------
    if ([self.channelConfig.channelType isEqualToString:@"secure"]) {

        __weak typeof(self) weakSelf = self;
        NSString *fromUsername =
            [payload[@"from_username"] isKindOfClass:[NSString class]]
                ? payload[@"from_username"]
                : @"";

        [self.websocketHandler
            pushForSecureLine:@"secured_public_key"
                         data:@{@"username" : fromUsername}
                       listen:YES
                   completion:^(id _Nullable secureResult,
                                NSError *secureError) {
                     __strong typeof(weakSelf) strongSelf = weakSelf;
                     if (!strongSelf)
                         return;

                     if (secureError) {
                         [LogTracer
                             log:[NSString
                                     stringWithFormat:@" Decryption error: %@",
                                                      secureError]];
                         return;
                     }

                     NSDictionary *secureDict = nil;
                     if ([secureResult isKindOfClass:[NSDictionary class]])
                         secureDict = secureResult;
                     NSDictionary *innerData = secureDict[@"data"];
                     if (![innerData isKindOfClass:[NSDictionary class]])
                         return;

                     NSString *pubKey = innerData[@"public_key"];
                     if (![pubKey isKindOfClass:[NSString class]])
                         return;

                     if ([[innerData[@"status"] description]
                             isEqualToString:@"unsuccessfull"])
                         return;

                     NSString *encryptedData = mutablePayload[@"data"];
                     if ([encryptedData isKindOfClass:[NSString class]]) {
                         [strongSelf.websocketHandler
                                 decryptData:encryptedData
                             senderPublicKey:pubKey
                                  completion:^(NSString *decrypted,
                                               NSError *decError) {
                                    if (decError) {
                                        [LogTracer
                                            log:[NSString stringWithFormat:
                                                              @" Decryption "
                                                              @"error: %@",
                                                              decError]];
                                        return;
                                    }
                                    mutablePayload[@"data"] = decrypted;
                                    [strongSelf
                                        processContentAndEmit:event
                                                      payload:mutablePayload];
                                  }];
                     } else {
                         [strongSelf processContentAndEmit:event
                                                   payload:mutablePayload];
                     }
                   }];

    } else {
        [self processContentAndEmit:event payload:mutablePayload];
    }
}

- (void)processContentAndEmit:(NSString *)event
                      payload:(NSDictionary *)mutablePayload {

    // -------------------------------------------------------
    // PARSE CONTENT
    // -------------------------------------------------------
    id content = @{};

    id dataVal = mutablePayload[@"data"];
    if (dataVal) {
        if ([dataVal isKindOfClass:[NSString class]]) {
            NSData *jsonData =
                [(NSString *)dataVal dataUsingEncoding:NSUTF8StringEncoding];
            if (jsonData) {
                id parsed = [NSJSONSerialization JSONObjectWithData:jsonData
                                                            options:0
                                                              error:nil];
                if (parsed) {
                    content = parsed;
                } else {
                    content = dataVal;
                }
            } else {
                content = dataVal;
            }
        } else {
            content = dataVal;
        }
    } else {
        // Fallback: re-serialize and parse the whole payload
        NSData *fullData =
            [NSJSONSerialization dataWithJSONObject:mutablePayload
                                            options:0
                                              error:nil];
        if (fullData) {
            id parsed = [NSJSONSerialization JSONObjectWithData:fullData
                                                        options:0
                                                          error:nil];
            if (parsed) {
                content = parsed;
            }
        }
    }

    // -------------------------------------------------------
    // PRESENCE EVENT
    // -------------------------------------------------------
    if ([event isEqualToString:@"art_presence"]) {
        [self.emitter emit:@"art_presence" data:content];
        return;
    }

    // -------------------------------------------------------
    // EMIT TO LISTENERS
    // -------------------------------------------------------
    if (!self.isSubscribed)
        return;

    BOOL hasSpecific = [self.emitter listenerCount:event] > 0;
    BOOL hasAll = [self.emitter listenerCount:@"all"] > 0;

    if (hasSpecific || hasAll) {

        if (hasSpecific) {
            [self.emitter emit:event data:content];
        }

        if (hasAll) {
            [self.emitter emit:@"all"
                          data:@{@"event" : event, @"content" : content}];
        }

        [self acknowledge:mutablePayload returnFlag:@"CA"];

    } else {

        // Buffer for later
        NSArray<NSString *> *keys = @[
            @"id", @"from", @"channel", @"to", @"pipeline_id", @"attempt_id",
            @"interceptor_name", @"to_username"
        ];

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"content"] = content;
        for (NSString *key in keys) {
            id val = mutablePayload[key];
            if (val)
                entry[key] = val;
        }

        NSMutableArray<NSDictionary *> *eventBuffer = self.messageBuffer[event];
        if (!eventBuffer) {
            eventBuffer = [NSMutableArray array];
            self.messageBuffer[event] = eventBuffer;
        }
        [eventBuffer addObject:entry];
    }
}

@end
