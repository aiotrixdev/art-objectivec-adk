//
//  BaseSubscription.m
//  ADK
//

#import "BaseSubscription.h"
#import "ARTStorageModels.h"
#import "ARTSupport.h"
#import "BaseSubscription+Internal.h"
#import "HelperFunctions.h"
#import "Utils.h"

typedef void (^ARTPushCompletion)(NSString *_Nullable refId,
                                  NSError *_Nullable error);

@interface PendingAck : NSObject
@property(nonatomic, copy) ARTPushCompletion callback;
@property(nonatomic, strong, nullable) dispatch_block_t timer;
@end

@implementation PendingAck
@end

@interface BaseSubscription ()

@property(nonatomic, strong)
    NSMutableDictionary<NSString *, PendingAck *> *pendingAcks;
@property(nonatomic, assign) NSInteger messageCount;

// In-order inbound delivery (see `enqueueEvent:payload:`).
@property(nonatomic, strong, readonly) dispatch_queue_t inboundQueue;
@property(nonatomic, strong, readonly) NSMutableArray<NSArray *> *inboundFrames;
@property(nonatomic, assign) BOOL inboundBusy;

@end

@implementation BaseSubscription

+ (NSSet<NSString *> *)reservedChannels {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      set = [NSSet setWithArray:@[ @"art_config", @"art_secure" ]];
    });
    return set;
}

+ (NSSet<NSString *> *)controlChannels {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      set = [NSSet setWithArray:@[ @"art_config", @"art_secure", @"art_presence" ]];
    });
    return set;
}

- (instancetype)initWithConnectionID:(NSString *)connectionID
                       channelConfig:(ChannelConfig *)channelConfig
                    websocketHandler:(id<WebsocketHandler>)websocketHandler
                             process:(NSString *)process {
    self = [super init];
    if (self) {
        _connectionID = [connectionID copy];
        _websocketHandler = websocketHandler;
        _channelConfig = channelConfig;
        _presenceUsers = [channelConfig.presenceUsers copy] ?: @[];
        _emitter = [[EventEmitter alloc] init];
        _stateLock = [[NSObject alloc] init];
        _bufferStorage = [[ARTEventBuffer alloc] init];
        _pendingAcks = [NSMutableDictionary dictionary];
        _ackTimeoutMs = 50000;
        _messageCount = 0;
        _inboundFrames = [NSMutableArray array];
        NSString *label = [NSString
            stringWithFormat:@"com.art.adk.subscription.%@",
                             channelConfig.channelName ?: @"channel"];
        _inboundQueue =
            dispatch_queue_create(label.UTF8String, DISPATCH_QUEUE_SERIAL);

        if ([process isEqualToString:@"subscribe"]) {
            _isSubscribed = YES;
        } else if ([process isEqualToString:@"presence"]) {
            _isListening = YES;
        }
    }
    return self;
}

#pragma mark - Buffer snapshot

- (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)messageBuffer {
    @synchronized(self.stateLock) {
        return [self.bufferStorage dictionary];
    }
}

- (void)setMessageBuffer:
    (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)messageBuffer {
    ARTEventBuffer *fresh = [ARTEventBuffer bufferWithDictionary:messageBuffer ?: @{}];
    @synchronized(self.stateLock) {
        [self.bufferStorage drainAll];
        for (NSArray *item in [fresh drainAll]) {
            [self.bufferStorage appendEvent:item[0] entry:item[1]];
        }
    }
}

#pragma mark - Inbound queue

- (void)enqueueEvent:(NSString *)event payload:(NSDictionary *)payload {
    @synchronized(self.inboundFrames) {
        [self.inboundFrames addObject:@[ event ?: @"", payload ?: @{} ]];
        if (self.inboundBusy) {
            return;
        }
        self.inboundBusy = YES;
    }
    dispatch_async(self.inboundQueue, ^{
      [self drainInbound];
    });
}

- (void)drainInbound {
    NSArray *frame = nil;
    @synchronized(self.inboundFrames) {
        if (self.inboundFrames.count == 0) {
            self.inboundBusy = NO;
            return;
        }
        frame = self.inboundFrames.firstObject;
        [self.inboundFrames removeObjectAtIndex:0];
    }

    __block BOOL finished = NO;
    NSObject *once = [[NSObject alloc] init];
    [self handleMessage:frame[0]
                payload:frame[1]
             completion:^{
               @synchronized(once) {
                   if (finished) {
                       return;
                   }
                   finished = YES;
               }
               dispatch_async(self.inboundQueue, ^{
                 [self drainInbound];
               });
             }];
}

- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload {
}

- (void)handleMessage:(NSString *)event
              payload:(NSDictionary *)payload
           completion:(void (^)(void))completion {
    [self handleMessage:event payload:payload];
    completion();
}

#pragma mark - Validate subscription

- (void)validateSubscription:(NSString *)process {
    [self validateSubscription:process completion:nil];
}

- (void)validateSubscription:(NSString *)process
                  completion:(void (^)(void))completion {
    ChannelConfig *config = self.channelConfig;
    if ([[BaseSubscription reservedChannels] containsObject:config.channelName]) {
        if (completion) {
            completion();
        }
        return;
    }

    NSString *channelName = config.channelName;
    if (config.channelNamespace.length > 0) {
        channelName = [NSString
            stringWithFormat:@"%@:%@", channelName, config.channelNamespace];
    }

    __weak typeof(self) weakSelf = self;
    [HelperFunctions
        subscribeToChannel:channelName
                   process:process
          websocketHandler:self.websocketHandler
                completion:^(ChannelConfig *fresh, NSError *error) {
                  __strong typeof(weakSelf) strongSelf = weakSelf;
                  if (strongSelf) {
                      if (error) {
                          ARTLogError(@"validateSubscription(%@) failed for "
                                      @"%@: %@",
                                      process, channelName,
                                      error.localizedDescription);
                      } else {
                          strongSelf.channelConfig = fresh;
                          if ([process isEqualToString:@"presence"]) {
                              strongSelf.isListening = YES;
                          }
                      }
                  }
                  if (completion) {
                      completion();
                  }
                }];
}

#pragma mark - Presence

- (void)fetchPresence:(BOOL)unique
             callback:(void (^)(NSArray<NSString *> *))callback
           completion:(void (^)(PresenceUnsubscribe _Nullable,
                                NSError *_Nullable))completion {

    NSArray<NSString *> *previousPresenceData = self.presenceUsers;
    if (previousPresenceData.count > 0) {
        callback(previousPresenceData);
    }

    __weak typeof(self) weakSelf = self;
    [self
        validateSubscription:@"presence"
                  completion:^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) {
                        completion(nil, MakeError(ErrorCodeNotConnected,
                                                  @"Subscription deallocated"));
                        return;
                    }
                    if (!strongSelf.isListening) {
                        completion(nil,
                                   MakeError(ErrorCodeServerError,
                                             @"Not subscribed for presence"));
                        return;
                    }

                    NSUUID *listenerId = [strongSelf.emitter
                             on:@"art_presence"
                        handler:^(id payload) {
                          __strong typeof(weakSelf) self2 = weakSelf;
                          if (!self2 ||
                              ![payload isKindOfClass:[NSDictionary class]]) {
                              return;
                          }
                          NSDictionary *data = (NSDictionary *)payload;
                          // Any truthy `error` suppresses the update.
                          if ([ARTJSON isTruthy:data[@"error"]]) {
                              return;
                          }
                          NSArray *usernames = data[@"usernames"];
                          if (![usernames isKindOfClass:[NSArray class]]) {
                              return;
                          }

                          self2.presenceUsers = usernames;

                          NSMutableArray<NSString *> *response =
                              [NSMutableArray array];
                          if (unique) {
                              NSMutableSet<NSString *> *seen = [NSMutableSet set];
                              for (id user in usernames) {
                                  NSString *name =
                                      [[[user description]
                                          componentsSeparatedByString:@":"]
                                          firstObject]
                                          ?: @"";
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
                                ARTLogWarn(@"Presence request failed: %@",
                                           pushError.localizedDescription);
                            }
                          }];

                    PresenceUnsubscribe unsub = ^(void (^_Nullable done)(void)) {
                      __strong typeof(weakSelf) self3 = weakSelf;
                      if (!self3) {
                          if (done) {
                              done();
                          }
                          return;
                      }
                      [self3.emitter off:@"art_presence" identifier:listenerId];
                      ChannelConfig *config = self3.channelConfig;
                      [HelperFunctions
                          unsubscribeFromChannel:config.channelName
                                  subscriptionID:config.subscriptionID ?: @""
                                         process:@"presence"
                                websocketHandler:self3.websocketHandler
                                      completion:^(BOOL success, NSError *error) {
                                        if (done) {
                                            done();
                                        }
                                      }];
                    };

                    completion(unsub, nil);
                  }];
}

#pragma mark - Acknowledgements

- (void)acknowledge:(NSDictionary<NSString *, id> *)request
         returnFlag:(NSString *)returnFlag {

    ChannelConfig *config = self.channelConfig;
    if (![config.channelType isEqualToString:@"targeted"] &&
        ![config.channelType isEqualToString:@"secure"]) {
        return;
    }

    NSString *channel = request[@"channel"];
    if (![channel isKindOfClass:[NSString class]] ||
        [[BaseSubscription controlChannels] containsObject:channel]) {
        return;
    }

    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"channel"] = channel;
    response[@"return_flag"] = returnFlag;

    for (NSString *key in @[
             @"namespace", @"id", @"ref_id", @"from", @"to_username", @"to",
             @"pipeline_id", @"interceptor_name", @"attempt_id"
         ]) {
        id value = request[key];
        if (value) {
            response[key] = value;
        }
    }

    NSString *frame = [ARTJSON stringify:response error:nil];
    if (frame) {
        [self.websocketHandler sendMessage:frame];
    }
}

- (void)handleMessageAcks:(NSString *)event
               returnFlag:(NSString *)returnFlag
                     data:(NSDictionary *)data {
    if (![returnFlag isEqualToString:@"SA"]) {
        return;
    }
    NSString *refId = data[@"ref_id"];
    if (![refId isKindOfClass:[NSString class]]) {
        return;
    }

    PendingAck *ack = nil;
    @synchronized(self.stateLock) {
        ack = self.pendingAcks[refId];
        [self.pendingAcks removeObjectForKey:refId];
    }
    if (ack) {
        if (ack.timer) {
            dispatch_block_cancel(ack.timer);
        }
        ack.callback(refId, nil);
    }
}

- (void)failPendingAck:(NSString *)refId error:(NSError *)error {
    PendingAck *ack = nil;
    @synchronized(self.stateLock) {
        ack = self.pendingAcks[refId];
        [self.pendingAcks removeObjectForKey:refId];
    }
    if (ack) {
        ack.callback(nil, error);
    }
}

#pragma mark - Subscribe / unsubscribe

- (void)subscribe:(void (^)(void))completion {
    if ([[BaseSubscription reservedChannels]
            containsObject:self.channelConfig.channelName]) {
        if (completion) {
            completion();
        }
        return;
    }

    self.isSubscribed = YES;

    NSString *channelName = self.channelConfig.channelName;
    __weak typeof(self) weakSelf = self;
    [HelperFunctions
        subscribeToChannel:channelName
                   process:@"subscribe"
          websocketHandler:self.websocketHandler
                completion:^(ChannelConfig *config, NSError *error) {
                  __strong typeof(weakSelf) strongSelf = weakSelf;
                  if (strongSelf) {
                      if (error) {
                          ARTLogError(@"subscribe failed for %@: %@",
                                      channelName, error.localizedDescription);
                          strongSelf.isSubscribed = NO;
                      } else {
                          strongSelf.channelConfig = config;
                      }
                  }
                  if (completion) {
                      completion();
                  }
                }];
}

- (void)unsubscribe:(void (^)(void))completion {
    ChannelConfig *config = self.channelConfig;
    NSString *subID = config.subscriptionID;
    if (subID.length == 0) {
        if (completion) {
            completion();
        }
        return;
    }

    __weak typeof(self) weakSelf = self;
    [HelperFunctions
        unsubscribeFromChannel:config.channelName
                subscriptionID:subID
                       process:@"subscribe"
              websocketHandler:self.websocketHandler
                    completion:^(BOOL ok, NSError *error) {
                      __strong typeof(weakSelf) strongSelf = weakSelf;
                      if (strongSelf) {
                          if (ok) {
                              [strongSelf.websocketHandler
                                  removeSubscription:config.channelName];
                          } else {
                              ARTLogError(@"Failed to unsubscribe from channel "
                                          @"%@: %@",
                                          config.channelName,
                                          error.localizedDescription
                                              ?: @"no response");
                          }
                      }
                      if (completion) {
                          completion();
                      }
                    }];
}

- (void)reconnect {
    NSString *name = self.channelConfig.channelName;
    if ([name isEqualToString:@"art_config"] ||
        [name isEqualToString:@"art_secure"]) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (!strongSelf) {
              return;
          }
          void (^resubscribe)(void) = ^{
            [weakSelf subscribe:nil];
          };
          if (strongSelf.isListening) {
              [strongSelf validateSubscription:@"presence" completion:resubscribe];
          } else {
              resubscribe();
          }
        });
}

#pragma mark - Push

- (void)push:(NSString *)event
          data:(NSDictionary<NSString *, id> *)data
       options:(PushConfig *)options
    completion:(void (^)(NSError *_Nullable))completion {
    [self pushEvent:event
               data:data
            options:options
         completion:^(NSString *refId, NSError *error) {
           if (completion) {
               completion(error);
           }
         }];
}

- (void)pushEvent:(NSString *)event
             data:(NSDictionary<NSString *, id> *)data
          options:(PushConfig *)options
       completion:(ARTPushCompletion)completion {
    [self sendFrame:event content:data ?: @{} options:options completion:completion];
}

- (void)pushArray:(NSString *)event
             data:(NSArray<NSDictionary *> *)data
       completion:(void (^)(NSError *_Nullable))completion {
    [self sendFrame:event
            content:data ?: @[]
            options:nil
         completion:^(NSString *refId, NSError *error) {
           if (completion) {
               completion(error);
           }
         }];
}

/// Builds and sends a push frame for any JSON-compatible content.
- (void)sendFrame:(NSString *)event
          content:(id)content
          options:(nullable PushConfig *)options
       completion:(ARTPushCompletion)completion {
    __weak typeof(self) weakSelf = self;
    [self.websocketHandler wait:^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          completion(nil, MakeError(ErrorCodeNotConnected,
                                    @"Subscription deallocated"));
          return;
      }

      ConnectionDetail *connection = [strongSelf.websocketHandler getConnection];
      if (!connection) {
          completion(nil, MakeError(ErrorCodeNotConnected, @"Not connected"));
          return;
      }

      ChannelConfig *config = strongSelf.channelConfig;
      NSArray<NSString *> *to = options.to ?: @[];

      NSError *jsonError = nil;
      NSString *messageStr = [ARTJSON stringify:content error:&jsonError];
      if (!messageStr) {
          completion(nil, jsonError);
          return;
      }

      // Targeted and secure channels deliver to exactly one user.
      if (([config.channelType isEqualToString:@"secure"] ||
           [config.channelType isEqualToString:@"targeted"]) &&
          to.count != 1 && ![event isEqualToString:@"art_presence"]) {
          completion(nil, MakeError(ErrorCodeServerError,
                                    @"Exactly one user must be specified for "
                                    @"targeted/secure channel"));
          return;
      }

      if (![config.channelType isEqualToString:@"secure"] ||
          [event isEqualToString:@"art_presence"]) {
          [strongSelf transmit:connection
                        config:config
                         event:event
                            to:to
                       options:options
                    contentStr:messageStr
                    completion:completion];
          return;
      }

      // Secure channel: encrypt for the recipient's public key.
      [strongSelf.websocketHandler
          pushForSecureLine:@"secured_public_key"
                       data:@{@"username" : to[0]}
                     listen:YES
                 completion:^(id _Nullable secureResult, NSError *secureError) {
                   __strong typeof(weakSelf) self2 = weakSelf;
                   if (!self2) {
                       completion(nil, MakeError(ErrorCodeNotConnected,
                                                 @"Subscription deallocated"));
                       return;
                   }
                   NSDictionary *inner =
                       [secureResult isKindOfClass:[NSDictionary class]]
                           ? ((NSDictionary *)secureResult)[@"data"]
                           : nil;
                   if (secureError || ![inner isKindOfClass:[NSDictionary class]]) {
                       completion(nil, MakeError(ErrorCodeEncryptionError,
                                                 @"Could not fetch public key"));
                       return;
                   }
                   if ([[inner[@"status"] description]
                           isEqualToString:@"unsuccessfull"]) {
                       NSString *errStr = inner[@"error"];
                       completion(nil,
                                  MakeError(ErrorCodeEncryptionError,
                                            [errStr isKindOfClass:[NSString class]]
                                                ? errStr
                                                : @"Unknown error"));
                       return;
                   }
                   NSString *pubKey = inner[@"public_key"];
                   if (![pubKey isKindOfClass:[NSString class]]) {
                       completion(nil, MakeError(ErrorCodeEncryptionError,
                                                 @"Could not fetch public key"));
                       return;
                   }

                   [self2.websocketHandler
                              encryptData:messageStr
                       recipientPublicKey:pubKey
                               completion:^(NSString *encrypted,
                                            NSError *encError) {
                                 if (encError || !encrypted) {
                                     completion(nil,
                                                encError
                                                    ?: MakeError(
                                                           ErrorCodeEncryptionError,
                                                           @"Encryption failed"));
                                     return;
                                 }
                                 [self2 transmit:connection
                                          config:config
                                           event:event
                                              to:to
                                         options:options
                                      contentStr:encrypted
                                      completion:completion];
                               }];
                 }];
    }];
}

- (void)transmit:(ConnectionDetail *)connection
          config:(ChannelConfig *)config
           event:(NSString *)event
              to:(NSArray<NSString *> *)to
         options:(nullable PushConfig *)options
      contentStr:(NSString *)contentStr
      completion:(ARTPushCompletion)completion {

    NSString *refId = nil;
    BOOL awaitsAck = NO;
    if (![[BaseSubscription controlChannels] containsObject:config.channelName]) {
        NSInteger count;
        @synchronized(self.stateLock) {
            count = ++self.messageCount;
        }
        refId = [NSString stringWithFormat:@"%@_%@_%ld", connection.connectionId,
                                           config.channelName, (long)count];
        // This compares the channel *name* with "secure", so in practice
        // only targeted channels wait for the server's acknowledgement.
        awaitsAck = [config.channelType isEqualToString:@"targeted"] ||
                    [config.channelName isEqualToString:@"secure"];
    }

    NSString *channelFull = config.channelName;
    if (config.channelNamespace.length > 0) {
        channelFull = [NSString
            stringWithFormat:@"%@:%@", channelFull, config.channelNamespace];
    }

    NSMutableDictionary *message = [NSMutableDictionary dictionary];
    message[@"from"] = connection.connectionId ?: @"";
    message[@"to"] = to;
    message[@"channel"] = channelFull;
    message[@"event"] = event;
    message[@"content"] = contentStr;
    // Always sent; null when there is no thread.
    message[@"thread_id"] =
        options.threadID.length > 0 ? options.threadID : [NSNull null];
    if (refId) {
        message[@"ref_id"] = refId;
    }
    if (options.fileMeta.count > 0) {
        NSMutableArray *fileMeta = [NSMutableArray array];
        for (ARTFileMeta *meta in options.fileMeta) {
            [fileMeta addObject:[meta JSONObject]];
        }
        message[@"file_meta"] = fileMeta;
    }

    NSError *jsonError = nil;
    NSString *frame = [ARTJSON stringify:message error:&jsonError];
    if (!frame) {
        completion(nil, jsonError);
        return;
    }

    if (!awaitsAck || !refId) {
        [self.websocketHandler sendMessage:frame];
        completion(refId, nil);
        return;
    }

    // Register the acknowledgement before sending, so a fast `SA` can't be
    // missed.
    PendingAck *ack = [[PendingAck alloc] init];
    ack.callback = completion;
    __weak typeof(self) weakSelf = self;
    NSString *pendingRef = refId;
    ack.timer = dispatch_block_create(0, ^{
      [weakSelf failPendingAck:pendingRef
                         error:MakeError(ErrorCodeAckTimeout, @"ACK timeout")];
    });
    @synchronized(self.stateLock) {
        self.pendingAcks[refId] = ack;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(self.ackTimeoutMs * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                   ack.timer);
    [self.websocketHandler sendMessage:frame];
}

@end
