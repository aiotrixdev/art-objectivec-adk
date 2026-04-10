//
//  BaseSubscription.m
//  ADK
//

#import "BaseSubscription.h"
#import "HelperFunctions.h"
#import "LogTracer.h"
#import "Utils.h"

@interface PendingAck : NSObject
@property(nonatomic, copy) void (^callback)
    (NSString *_Nullable refId, NSError *_Nullable error);
@property(nonatomic, strong, nullable) dispatch_block_t timer;
@end

@implementation PendingAck
@end

@interface BaseSubscription ()

@property(nonatomic, strong)
    NSMutableDictionary<NSString *, PendingAck *> *pendingAcks;
@property(nonatomic, strong) NSLock *pendingAcksLock;
@property(nonatomic, assign) NSInteger messageCount;

@end

@implementation BaseSubscription

- (instancetype)initWithConnectionID:(NSString *)connectionID
                       channelConfig:(ChannelConfig *)channelConfig
                    websocketHandler:(id<WebsocketHandler>)websocketHandler
                             process:(NSString *)process {
    self = [super init];
    if (self) {
        _connectionID = [connectionID copy];
        _websocketHandler = websocketHandler;
        _channelConfig = channelConfig;
        _presenceUsers = [channelConfig.presenceUsers copy];
        _emitter = [[EventEmitter alloc] init];
        _messageBuffer = [NSMutableDictionary dictionary];
        _pendingAcks = [NSMutableDictionary dictionary];
        _pendingAcksLock = [[NSLock alloc] init];
        _messageCount = 0;

        if ([process isEqualToString:@"subscribe"]) {
            _isSubscribed = YES;
        } else if ([process isEqualToString:@"presence"]) {
            _isListening = YES;
        }
    }
    return self;
}

- (void)validateSubscription:(NSString *)process {

    if ([@[ @"art_config", @"art_secure" ]
            containsObject:self.channelConfig.channelName])
        return;

    NSString *channelName = self.channelConfig.channelName;
    if (self.channelConfig.channelNamespace.length > 0) {
        channelName =
            [NSString stringWithFormat:@"%@:%@", channelName,
                                       self.channelConfig.channelNamespace];
    }

    __weak typeof(self) weakSelf = self;
    [HelperFunctions
        subscribeToChannel:channelName
                   process:process
          websocketHandler:self.websocketHandler
                completion:^(ChannelConfig *config, NSError *error) {
                  __strong typeof(weakSelf) strongSelf = weakSelf;
                  if (!strongSelf)
                      return;

                  if (error) {
                      [LogTracer
                          log:[NSString stringWithFormat:
                                            @" validateSubscription error: %@",
                                            error]];
                      return;
                  }

                  strongSelf.channelConfig = config;
                  if ([process isEqualToString:@"presence"]) {
                      strongSelf.isListening = YES;
                  }
                }];
}

- (void)fetchPresence:(BOOL)unique
             callback:(void (^)(NSArray<NSString *> *))callback
           completion:(void (^)(PresenceUnsubscribe _Nullable,
                                NSError *_Nullable))completion {

    NSArray<NSString *> *previousPresenceData = self.presenceUsers;
    if (previousPresenceData.count > 0) {
        callback(previousPresenceData);
    }

    __weak typeof(self) weakSelf = self;

    [self validateSubscription:@"presence"];

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (!strongSelf)
              return;

          if (!strongSelf.isListening) {
              completion(nil, MakeError(ErrorCodeServerError,
                                        @"Not subscribed for presence"));
              return;
          }

          [strongSelf.emitter
                   on:@"art_presence"
              handler:^(id payload) {
                __strong typeof(weakSelf) self2 = weakSelf;
                if (!self2)
                    return;

                if (![payload isKindOfClass:[NSDictionary class]])
                    return;
                NSDictionary *data = (NSDictionary *)payload;

                NSArray<NSString *> *usernames = data[@"usernames"];
                if (![usernames isKindOfClass:[NSArray class]])
                    return;

                NSNumber *errorFlag = data[@"error"];
                if ([errorFlag isKindOfClass:[NSNumber class]] &&
                    errorFlag.boolValue)
                    return;

                self2.presenceUsers = usernames;

                NSMutableArray<NSString *> *response = [NSMutableArray array];

                if (unique) {
                    NSMutableSet<NSString *> *seen = [NSMutableSet set];
                    for (NSString *user in usernames) {
                        NSArray<NSString *> *parts =
                            [user componentsSeparatedByString:@":"];
                        NSString *name = parts.firstObject ?: @"";
                        if (![seen containsObject:name]) {
                            [seen addObject:name];
                            [response addObject:name];
                        }
                    }
                } else {
                    [response addObjectsFromArray:usernames];
                }

                callback([response copy]);
              }];

          [strongSelf push:@"art_presence"
              data:@{}
              options:nil
              completion:^(NSError *pushError) {
                if (pushError) {
                    [LogTracer
                        log:[NSString
                                stringWithFormat:@" presence push error: %@",
                                                 pushError]];
                }
              }];

          PresenceUnsubscribe unsub = ^(void (^_Nullable done)(void)) {
            __strong typeof(weakSelf) self3 = weakSelf;
            if (!self3) {
                if (done)
                    done();
                return;
            }

            [HelperFunctions
                unsubscribeFromChannel:self3.channelConfig.channelName
                        subscriptionID:self3.channelConfig.subscriptionID ?: @""
                               process:@"presence"
                      websocketHandler:self3.websocketHandler
                            completion:^(BOOL success, NSError *error) {
                              if (done)
                                  done();
                            }];
          };

          completion(unsub, nil);
        });
}

- (void)acknowledge:(NSDictionary<NSString *, id> *)request
         returnFlag:(NSString *)returnFlag {

    if (![self.channelConfig.channelType isEqualToString:@"targeted"] &&
        ![self.channelConfig.channelType isEqualToString:@"secure"]) {
        return;
    }

    NSString *channel = request[@"channel"];
    if (![channel isKindOfClass:[NSString class]])
        return;
    if ([@[ @"art_config", @"art_secure", @"art_presence" ]
            containsObject:channel])
        return;

    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"channel"] = channel;
    response[@"return_flag"] = returnFlag;

    NSArray<NSString *> *keys = @[
        @"id", @"ref_id", @"from", @"to_username", @"to", @"pipeline_id",
        @"interceptor_name", @"attempt_id"
    ];

    for (NSString *key in keys) {
        id value = request[key];
        if (value)
            response[key] = value;
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:response
                                                       options:0
                                                         error:nil];
    if (jsonData) {
        NSString *str = [[NSString alloc] initWithData:jsonData
                                              encoding:NSUTF8StringEncoding];
        if (str) {
            [self.websocketHandler sendMessage:str];
        }
    }
}

- (void)handleMessageAcks:(NSString *)event
               returnFlag:(NSString *)returnFlag
                     data:(NSDictionary *)data {

    if (![returnFlag isEqualToString:@"SA"])
        return;

    NSString *refId = data[@"ref_id"];
    if (![refId isKindOfClass:[NSString class]])
        return;

    // Pop the pending ack under the lock, then fire the callback outside
    // the lock to avoid holding it across app code.
    PendingAck *ack = nil;
    [self.pendingAcksLock lock];
    ack = self.pendingAcks[refId];
    if (ack) {
        [self.pendingAcks removeObjectForKey:refId];
    }
    [self.pendingAcksLock unlock];

    if (ack) {
        if (ack.timer) {
            dispatch_block_cancel(ack.timer);
        }
        if (ack.callback) {
            ack.callback(refId, nil);
        }
    }
}

- (void)subscribe:(void (^)(void))completion {

    if ([@[ @"art_config", @"art_secure" ]
            containsObject:self.channelConfig.channelName]) {
        if (completion)
            completion();
        return;
    }

    self.isSubscribed = YES;

    __weak typeof(self) weakSelf = self;
    [HelperFunctions
        subscribeToChannel:self.channelConfig.channelName
                   process:@"subscribe"
          websocketHandler:self.websocketHandler
                completion:^(ChannelConfig *config, NSError *error) {
                  __strong typeof(weakSelf) strongSelf = weakSelf;
                  if (!strongSelf) {
                      if (completion)
                          completion();
                      return;
                  }

                  if (error) {
                      [LogTracer
                          log:[NSString
                                  stringWithFormat:@" subscribe error: %@",
                                                   error]];
                      strongSelf.isSubscribed = NO;
                  } else {
                      strongSelf.channelConfig = config;
                  }
                  if (completion)
                      completion();
                }];
}

- (void)unsubscribe:(void (^)(void))completion {

    NSString *subID = self.channelConfig.subscriptionID;
    if (!subID) {
        if (completion)
            completion();
        return;
    }

    __weak typeof(self) weakSelf = self;
    [HelperFunctions
        unsubscribeFromChannel:self.channelConfig.channelName
                subscriptionID:subID
                       process:@"subscribe"
              websocketHandler:self.websocketHandler
                    completion:^(BOOL ok, NSError *error) {
                      __strong typeof(weakSelf) strongSelf = weakSelf;
                      if (!strongSelf) {
                          if (completion)
                              completion();
                          return;
                      }

                      if (error) {
                          [LogTracer
                              log:[NSString
                                      stringWithFormat:
                                          @" unsubscribe error: %@", error]];
                      } else if (ok) {
                          [strongSelf.websocketHandler
                              removeSubscription:strongSelf.channelConfig
                                                     .channelName];
                      }
                      if (completion)
                          completion();
                    }];
}

- (void)reconnect {

    if ([self.channelConfig.channelName isEqualToString:@"art_config"] ||
        [self.channelConfig.channelName isEqualToString:@"art_secure"]) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (!strongSelf)
              return;

          if (strongSelf.isListening) {
              [strongSelf validateSubscription:@"presence"];
          }
          [strongSelf subscribe:nil];
        });
}

- (void)push:(NSString *)event
          data:(NSDictionary<NSString *, id> *)data
       options:(PushConfig *)options
    completion:(void (^)(NSError *_Nullable))completion {

    __weak typeof(self) weakSelf = self;
    [self.websocketHandler wait:^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          completion(
              MakeError(ErrorCodeNotConnected, @"Subscription deallocated"));
          return;
      }

      ConnectionDetail *connection =
          [strongSelf.websocketHandler getConnection];
      if (!connection) {
          completion(MakeError(ErrorCodeNotConnected, @"Not connected"));
          return;
      }

      NSArray<NSString *> *to = options.to ?: @[];

      NSError *jsonError = nil;
      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:data
                                                         options:0
                                                           error:&jsonError];
      if (jsonError) {
          completion(jsonError);
          return;
      }
      NSString *messageStr =
          [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]
              ?: @"{}";

      // Targeted / secure validation
      if ([strongSelf.channelConfig.channelType isEqualToString:@"secure"] ||
          [strongSelf.channelConfig.channelType isEqualToString:@"targeted"]) {
          if (to.count != 1 && ![event isEqualToString:@"art_presence"]) {
              completion(MakeError(ErrorCodeServerError,
                                   @"Exactly one user must be specified for "
                                   @"targeted/secure channel"));
              return;
          }
      }

      // Secure channel encryption
      if ([strongSelf.channelConfig.channelType isEqualToString:@"secure"] &&
          ![event isEqualToString:@"art_presence"]) {

          [strongSelf.websocketHandler
              pushForSecureLine:@"secured_public_key"
                           data:@{@"username" : to[0]}
                         listen:YES
                     completion:^(id _Nullable secureResult,
                                  NSError *secureError) {
                       __strong typeof(weakSelf) self2 = weakSelf;
                       if (!self2) {
                           completion(MakeError(ErrorCodeNotConnected,
                                                @"Deallocated"));
                           return;
                       }

                       if (secureError) {
                           completion(MakeError(ErrorCodeEncryptionError,
                                                @"Could not fetch public key"));
                           return;
                       }

                       NSDictionary *secureDict = nil;
                       if ([secureResult isKindOfClass:[NSDictionary class]])
                           secureDict = secureResult;
                       NSDictionary *inner = secureDict[@"data"];
                       if (![inner isKindOfClass:[NSDictionary class]]) {
                           completion(MakeError(ErrorCodeEncryptionError,
                                                @"Could not fetch public key"));
                           return;
                       }

                       if ([[inner[@"status"] description]
                               isEqualToString:@"unsuccessfull"]) {
                           NSString *errStr = inner[@"error"];
                           if (![errStr isKindOfClass:[NSString class]])
                               errStr = @"Unknown error";
                           completion(
                               MakeError(ErrorCodeEncryptionError, errStr));
                           return;
                       }

                       NSString *pubKey = inner[@"public_key"];
                       if (![pubKey isKindOfClass:[NSString class]]) {
                           completion(MakeError(ErrorCodeEncryptionError,
                                                @"Could not fetch public key"));
                           return;
                       }

                       [self2.websocketHandler
                                  encryptData:messageStr
                           recipientPublicKey:pubKey
                                   completion:^(NSString *encrypted,
                                                NSError *encError) {
                                     if (encError || !encrypted) {
                                         completion(
                                             encError
                                                 ?: MakeError(
                                                        ErrorCodeEncryptionError,
                                                        @"Encryption failed"));
                                         return;
                                     }
                                     [self2 sendPushMessage:connection
                                                      event:event
                                                         to:to
                                                 contentStr:encrypted
                                                 completion:completion];
                                   }];
                     }];

      } else {
          [strongSelf sendPushMessage:connection
                                event:event
                                   to:to
                           contentStr:messageStr
                           completion:completion];
      }
    }];
}

- (void)sendPushMessage:(ConnectionDetail *)connection
                  event:(NSString *)event
                     to:(NSArray<NSString *> *)to
             contentStr:(NSString *)contentStr
             completion:(void (^)(NSError *_Nullable))completion {

    NSString *refId = nil;
    if (![@[ @"art_config", @"art_secure", @"art_presence" ]
            containsObject:self.channelConfig.channelName]) {
        self.messageCount += 1;
        refId =
            [NSString stringWithFormat:@"%@_%@_%ld", connection.connectionId,
                                       self.channelConfig.channelName,
                                       (long)self.messageCount];
    }

    NSString *channelFull = self.channelConfig.channelName;
    if (self.channelConfig.channelNamespace.length > 0) {
        channelFull =
            [NSString stringWithFormat:@"%@:%@", channelFull,
                                       self.channelConfig.channelNamespace];
    }

    NSMutableDictionary *message = [NSMutableDictionary dictionary];
    message[@"from"] = connection.connectionId;
    message[@"to"] = to;
    message[@"channel"] = channelFull;
    message[@"event"] = event;
    message[@"content"] = contentStr;
    if (refId) {
        message[@"ref_id"] = refId;
    }

    NSData *msgData = [NSJSONSerialization dataWithJSONObject:message
                                                      options:0
                                                        error:nil];
    if (msgData) {
        NSString *msgStr = [[NSString alloc] initWithData:msgData
                                                 encoding:NSUTF8StringEncoding];
        if (msgStr) {
            [LogTracer
                printJSONString:msgStr
                          title:@"\n✅ Pushing Message Data=============>"];
            [self.websocketHandler sendMessage:msgStr];
        }
    }

    completion(nil);
}

- (void)pushArray:(NSString *)event
             data:(NSArray<NSDictionary *> *)data
       completion:(void (^)(NSError *_Nullable))completion {

    __weak typeof(self) weakSelf = self;
    [self.websocketHandler wait:^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          completion(
              MakeError(ErrorCodeNotConnected, @"Subscription deallocated"));
          return;
      }

      ConnectionDetail *connection =
          [strongSelf.websocketHandler getConnection];
      if (!connection) {
          completion(MakeError(ErrorCodeNotConnected, @"Not connected"));
          return;
      }

      NSError *jsonError = nil;
      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:data
                                                         options:0
                                                           error:&jsonError];
      if (jsonError) {
          completion(jsonError);
          return;
      }
      NSString *messageStr =
          [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]
              ?: @"[]";

      strongSelf.messageCount += 1;
      NSString *refId =
          [NSString stringWithFormat:@"%@_%@_%ld", connection.connectionId,
                                     strongSelf.channelConfig.channelName,
                                     (long)strongSelf.messageCount];

      NSString *channelFull = strongSelf.channelConfig.channelName;
      if (strongSelf.channelConfig.channelNamespace.length > 0) {
          channelFull = [NSString
              stringWithFormat:@"%@:%@", channelFull,
                               strongSelf.channelConfig.channelNamespace];
      }

      NSDictionary *message = @{
          @"from" : connection.connectionId,
          @"to" : @[],
          @"channel" : channelFull,
          @"event" : event,
          @"content" : messageStr,
          @"ref_id" : refId
      };

      NSData *msgData = [NSJSONSerialization dataWithJSONObject:message
                                                        options:0
                                                          error:nil];
      if (msgData) {
          NSString *msgStr =
              [[NSString alloc] initWithData:msgData
                                    encoding:NSUTF8StringEncoding];
          if (msgStr) {
              [LogTracer printJSONString:msgStr title:@"CRDT Push"];
              [strongSelf.websocketHandler sendMessage:msgStr];
          }
      }

      completion(nil);
    }];
}

- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload {
}

@end
