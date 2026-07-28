//
//  Subscription.m
//  ADK
//

#import "Subscription.h"
#import "OrchestratorThread.h"

@interface Subscription ()
/// Buffered thread-scoped events keyed by threadId → event → entries, replayed
/// when a thread listener attaches.
@property(nonatomic, strong)
    NSMutableDictionary<NSString *,
                        NSMutableDictionary<NSString *,
                                            NSMutableArray<NSDictionary *> *> *>
        *threadBuffers;
/// Live OrchestratorThreads registered on this subscription, keyed by id.
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, OrchestratorThread *> *threads;
- (void)emitThreadEvent:(NSString *)event
                content:(id)content
               threadId:(nullable NSString *)threadId;
- (void)bufferEvent:(NSString *)event entry:(NSDictionary *)entry;
- (void)sendHumanFeedback:(NSDictionary *)originalReq replyData:(id)replyData;
@end

@implementation Subscription

- (instancetype)initWithConnectionID:(NSString *)connectionID
                       channelConfig:(ChannelConfig *)channelConfig
                    websocketHandler:(id<WebsocketHandler>)websocketHandler
                             process:(NSString *)process {
    self = [super initWithConnectionID:connectionID
                         channelConfig:channelConfig
                      websocketHandler:websocketHandler
                               process:process];
    if (self) {
        _threadBuffers = [NSMutableDictionary dictionary];
        _threads = [NSMutableDictionary dictionary];
    }
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
    // HUMAN-IN-THE-LOOP (HITL)
    // -------------------------------------------------------
    // When the server requests feedback, attach a `reply` block to the content
    // so consumers can answer (sends `return_flag: "HF"`). Stored under the
    // "reply" key as a `void(^)(id)`; strip it before serializing content for
    // display. Mirrors js-adk-common subscription.ts (requestFeedback).
    NSString *returnFlag =
        [mutablePayload[@"return_flag"] isKindOfClass:[NSString class]]
            ? mutablePayload[@"return_flag"]
            : @"";
    NSString *contentType = nil;
    if ([content isKindOfClass:[NSDictionary class]]) {
        id t = ((NSDictionary *)content)[@"type"];
        if ([t isKindOfClass:[NSString class]]) {
            contentType = (NSString *)t;
        }
    }
    BOOL humanFeedbackRequest =
        [returnFlag isEqualToString:@"requestFeedback"] ||
        [event isEqualToString:@"human_input_request"] ||
        [contentType isEqualToString:@"human_input_request"];
    if (humanFeedbackRequest && [content isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *withReply = [(NSDictionary *)content mutableCopy];
        NSDictionary *originalReq = [mutablePayload copy];
        __weak typeof(self) weakSelf = self;
        withReply[@"reply"] = ^(id replyData) {
          [weakSelf sendHumanFeedback:originalReq replyData:replyData];
        };
        content = withReply;
    }

    // -------------------------------------------------------
    // PRESENCE EVENT
    // -------------------------------------------------------
    if ([event isEqualToString:@"art_presence"]) {
        [self.emitter emit:@"art_presence" data:content];
        return;
    }

    // -------------------------------------------------------
    // TRACE (diagnostic / telemetry) FRAMES
    // -------------------------------------------------------
    // Emitted directly to their listeners, bypassing the subscribed-state gate
    // + the normal buffering path (mirrors js-adk-common subscription.ts).
    // Consumers attach via `AgentThread.listenTrace` /
    // `OrchestratorThread.listenTrace`.
    if ([event isEqualToString:@"trace"]) {
        id traceTid = mutablePayload[@"thread_id"];
        NSString *traceThreadId =
            ([traceTid isKindOfClass:[NSString class]] &&
             [(NSString *)traceTid length] > 0)
                ? (NSString *)traceTid
                : nil;
        [self emitThreadEvent:@"trace" content:content threadId:traceThreadId];
        return;
    }

    // -------------------------------------------------------
    // EMIT TO LISTENERS (thread-aware)
    // -------------------------------------------------------
    if (!self.isSubscribed)
        return;

    // Thread-scoped events route on "<threadId>-<event>" / "<threadId>-all";
    // flat events keep the plain `event` / "all" keys.
    NSString *threadId = nil;
    id tid = mutablePayload[@"thread_id"];
    if ([tid isKindOfClass:[NSString class]] && [(NSString *)tid length] > 0) {
        threadId = (NSString *)tid;
    }
    NSString *eventKey =
        threadId ? [NSString stringWithFormat:@"%@-%@", threadId, event] : event;
    NSString *allKey =
        threadId ? [NSString stringWithFormat:@"%@-all", threadId] : @"all";

    BOOL hasSpecific = [self.emitter listenerCount:eventKey] > 0;
    BOOL hasAll = [self.emitter listenerCount:allKey] > 0;

    if (hasSpecific || hasAll) {

        if (hasSpecific) {
            [self emitThreadEvent:event content:content threadId:threadId];
        }
        if (hasAll) {
            [self emitThreadEvent:@"all"
                          content:@{@"event" : event, @"content" : content}
                         threadId:threadId];
        }
        [self acknowledge:mutablePayload returnFlag:@"CA"];

    } else {

        // Buffer for later. `thread_id` is copied so the buffer router can
        // replay into the right per-thread queue.
        NSArray<NSString *> *keys = @[
            @"id", @"from", @"channel", @"to", @"pipeline_id", @"thread_id",
            @"attempt_id", @"interceptor_name", @"to_username"
        ];
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"content"] = content;
        for (NSString *key in keys) {
            id val = mutablePayload[key];
            if (val)
                entry[key] = val;
        }
        [self bufferEvent:event entry:entry];
    }
}

#pragma mark - Thread-scoped routing

- (nullable OrchestratorThread *)thread:(nullable NSString *)threadId {
    if (!self.channelConfig.orchestratorEnabled) {
        NSLog(@"[ADK] Channel %@ is not orchestrator-enabled",
              self.channelConfig.channelName);
        return nil;
    }
    return [self threadUnchecked:threadId];
}

- (OrchestratorThread *)threadUnchecked:(nullable NSString *)threadId {
    if (threadId.length > 0) {
        OrchestratorThread *existing = self.threads[threadId];
        if (existing && !existing.isDisposed) {
            return existing;
        }
    }
    OrchestratorThread *t =
        [[OrchestratorThread alloc] initWithSubscription:self threadId:threadId];
    self.threads[t.threadId] = t;
    return t;
}

- (nullable OrchestratorThread *)getThread:(NSString *)threadId {
    return self.threads[threadId];
}

- (void)unregisterThread:(NSString *)threadId {
    [self.threads removeObjectForKey:threadId];
    [self.threadBuffers removeObjectForKey:threadId];
}

- (void)attachThreadListener:(NSString *)threadId
                    callback:
                        (void (^)(NSDictionary<NSString *, id> *))callback {
    NSDictionary *buf = [self.threadBuffers[threadId] copy];
    if (buf) {
        for (NSString *evt in buf) {
            for (NSDictionary *reqData in buf[evt]) {
                callback(@{
                    @"event" : evt,
                    @"content" : reqData[@"content"] ?: [NSNull null]
                });
                [self acknowledge:reqData returnFlag:@"CA"];
            }
        }
        [self.threadBuffers removeObjectForKey:threadId];
    }
    NSString *key = [NSString stringWithFormat:@"%@-all", threadId];
    [self.emitter on:key
             handler:^(id data) {
               if ([data isKindOfClass:[NSDictionary class]]) {
                   callback((NSDictionary *)data);
               }
             }];
}

- (void)attachThreadBind:(NSString *)threadId
                   event:(NSString *)event
                callback:(void (^)(id))callback {
    NSMutableDictionary *buf = self.threadBuffers[threadId];
    NSMutableArray *msgs = buf[event];
    if (msgs) {
        for (NSDictionary *reqData in msgs) {
            callback(reqData[@"content"] ?: [NSNull null]);
            [self acknowledge:reqData returnFlag:@"CA"];
        }
        [buf removeObjectForKey:event];
    }
    NSString *key = [NSString stringWithFormat:@"%@-%@", threadId, event];
    [self.emitter on:key handler:callback];
}

- (void)detachThreadListener:(NSString *)threadId event:(NSString *)event {
    NSString *key = [NSString stringWithFormat:@"%@-%@", threadId, event];
    [self.emitter offEvent:key];
    NSMutableDictionary *buf = self.threadBuffers[threadId];
    [buf removeObjectForKey:event];
}

- (void)emitThreadEvent:(NSString *)event
                content:(id)content
               threadId:(nullable NSString *)threadId {
    NSString *key = (threadId.length > 0)
                        ? [NSString stringWithFormat:@"%@-%@", threadId, event]
                        : event;
    [self.emitter emit:key data:content];
}

- (void)bufferEvent:(NSString *)event entry:(NSDictionary *)entry {
    id tid = entry[@"thread_id"];
    if ([tid isKindOfClass:[NSString class]] && [(NSString *)tid length] > 0) {
        NSString *threadId = (NSString *)tid;
        NSMutableDictionary *perThread = self.threadBuffers[threadId];
        if (!perThread) {
            perThread = [NSMutableDictionary dictionary];
            self.threadBuffers[threadId] = perThread;
        }
        NSMutableArray *arr = perThread[event];
        if (!arr) {
            arr = [NSMutableArray array];
            perThread[event] = arr;
        }
        [arr addObject:entry];
    } else {
        NSMutableArray *arr = self.messageBuffer[event];
        if (!arr) {
            arr = [NSMutableArray array];
            self.messageBuffer[event] = arr;
        }
        [arr addObject:entry];
    }
}

#pragma mark - Human-in-the-loop reply

- (void)sendHumanFeedback:(NSDictionary *)originalReq replyData:(id)replyData {
    ConnectionDetail *conn = [self.websocketHandler getConnection];
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    reply[@"return_flag"] = @"HF";
    reply[@"from"] = conn.connectionId ?: @"";

    for (NSString *key in @[
             @"channel", @"namespace", @"id", @"ref_id", @"to_username",
             @"from_username", @"thread_id", @"node_id", @"iteration_id",
             @"root_workflow_id", @"agent_node_id", @"agent_id",
             @"environment_id", @"pipeline_id", @"attempt_id",
             @"interceptor_name"
         ]) {
        id v = originalReq[key];
        if (v) {
            reply[key] = v;
        }
    }

    id from = originalReq[@"from"];
    if (from) {
        reply[@"to"] = @[ from ];
    }

    if ([NSJSONSerialization isValidJSONObject:replyData]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:replyData
                                                    options:0
                                                      error:nil];
        NSString *s = d ? [[NSString alloc] initWithData:d
                                                encoding:NSUTF8StringEncoding]
                        : nil;
        reply[@"content"] = s ?: @"";
    } else if ([replyData isKindOfClass:[NSString class]]) {
        reply[@"content"] = replyData;
    } else {
        reply[@"content"] = [NSString stringWithFormat:@"%@", replyData];
    }

    NSData *msgData = [NSJSONSerialization dataWithJSONObject:reply
                                                     options:0
                                                       error:nil];
    if (msgData) {
        NSString *msgStr =
            [[NSString alloc] initWithData:msgData
                                  encoding:NSUTF8StringEncoding];
        if (msgStr) {
            [self.websocketHandler sendMessage:msgStr];
        }
    }
}

@end
