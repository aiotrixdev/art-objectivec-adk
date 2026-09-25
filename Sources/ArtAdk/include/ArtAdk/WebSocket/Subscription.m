//
//  Subscription.m
//  ADK
//

#import "Subscription.h"
#import "ARTStorage.h"
#import "ARTSupport.h"
#import "BaseSubscription+Internal.h"
#import "OrchestratorThread.h"
#import "Utils.h"

@interface Subscription ()
/// Buffered thread-scoped events: thread id → ordered event buffer.
/// Guarded by `stateLock`.
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, ARTEventBuffer *> *threadBufferStorage;
/// Live OrchestratorThreads registered on this subscription, keyed by id.
/// Guarded by `stateLock`.
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, OrchestratorThread *> *threads;
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
        _threadBufferStorage = [NSMutableDictionary dictionary];
        _threads = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Listeners

- (NSUUID *)listen:(void (^)(NSDictionary<NSString *, id> *))callback {
    NSArray<NSArray *> *drained;
    NSUUID *identifier;
    // Drain and register together, so a frame can't fall in between.
    @synchronized(self.stateLock) {
        drained = [self.bufferStorage drainAll];
        identifier = [self.emitter on:@"all"
                              handler:^(id data) {
                                if ([data isKindOfClass:[NSDictionary class]]) {
                                    callback((NSDictionary *)data);
                                }
                              }];
    }
    [self deliver:drained to:callback];
    return identifier;
}

- (NSUUID *)bind:(NSString *)event callback:(void (^)(id))callback {
    NSArray<NSDictionary *> *drained;
    NSUUID *identifier;
    @synchronized(self.stateLock) {
        drained = [self.bufferStorage takeEvent:event];
        identifier = [self.emitter on:event handler:callback];
    }
    for (NSDictionary *entry in drained) {
        callback(entry[@"content"] ?: [NSNull null]);
        [self acknowledge:entry returnFlag:@"CA"];
    }
    return identifier;
}

- (void)remove:(NSString *)event {
    [self.emitter offEvent:event];
    @synchronized(self.stateLock) {
        [self.bufferStorage takeEvent:event];
    }
}

- (void)remove:(NSString *)event identifier:(NSUUID *)identifier {
    [self.emitter off:event identifier:identifier];
    @synchronized(self.stateLock) {
        [self.bufferStorage takeEvent:event];
    }
}

- (void)deliver:(NSArray<NSArray *> *)drained
             to:(void (^)(NSDictionary<NSString *, id> *))callback {
    for (NSArray *item in drained) {
        NSDictionary *entry = item[1];
        callback(@{
            @"event" : item[0],
            @"content" : entry[@"content"] ?: [NSNull null]
        });
        [self acknowledge:entry returnFlag:@"CA"];
    }
}

#pragma mark - Inbound frames

- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload {
    [self handleMessage:event
                payload:payload
             completion:^{
             }];
}

- (void)handleMessage:(NSString *)event
              payload:(NSDictionary *)payload
           completion:(void (^)(void))completion {

    NSString *returnFlag = [payload[@"return_flag"] isKindOfClass:[NSString class]]
                               ? payload[@"return_flag"]
                               : @"";

    // Server acknowledgement of one of our pushes.
    if ([returnFlag isEqualToString:@"SA"]) {
        [self handleMessageAcks:event returnFlag:returnFlag data:payload];
        completion();
        return;
    }

    [self acknowledge:payload returnFlag:@"MA"];

    if (![self.channelConfig.channelType isEqualToString:@"secure"]) {
        [self processContent:event payload:payload];
        completion();
        return;
    }

    // Secure channel: decrypt with the sender's public key first.
    id fromUsername = payload[@"from_username"];
    NSString *sender = [fromUsername isKindOfClass:[NSString class]]
                           ? (NSString *)fromUsername
                           : @"";
    __weak typeof(self) weakSelf = self;
    [self.websocketHandler
        pushForSecureLine:@"secured_public_key"
                     data:@{@"username" : sender}
                   listen:YES
               completion:^(id _Nullable secureResult, NSError *secureError) {
                 __strong typeof(weakSelf) strongSelf = weakSelf;
                 if (!strongSelf) {
                     completion();
                     return;
                 }
                 NSDictionary *innerData =
                     [secureResult isKindOfClass:[NSDictionary class]]
                         ? ((NSDictionary *)secureResult)[@"data"]
                         : nil;
                 if (secureError ||
                     ![innerData isKindOfClass:[NSDictionary class]]) {
                     ARTLogError(@"secured_public_key lookup failed for %@",
                                 sender);
                     completion();
                     return;
                 }
                 if ([[innerData[@"status"] description]
                         isEqualToString:@"unsuccessfull"]) {
                     ARTLogError(@"secured_public_key: %@",
                                 innerData[@"error"] ?: @"unsuccessful");
                     completion();
                     return;
                 }
                 NSString *pubKey = innerData[@"public_key"];
                 if (![pubKey isKindOfClass:[NSString class]]) {
                     completion();
                     return;
                 }

                 id encrypted = payload[@"data"];
                 if (![encrypted isKindOfClass:[NSString class]]) {
                     [strongSelf processContent:event payload:payload];
                     completion();
                     return;
                 }
                 [strongSelf.websocketHandler
                         decryptData:encrypted
                     senderPublicKey:pubKey
                          completion:^(NSString *decrypted, NSError *decError) {
                            if (decError || !decrypted) {
                                ARTLogError(
                                    @"Failed to decrypt secure message: %@",
                                    decError.localizedDescription
                                        ?: @"no data");
                                completion();
                                return;
                            }
                            NSMutableDictionary *decryptedPayload =
                                [payload mutableCopy];
                            decryptedPayload[@"data"] = decrypted;
                            [weakSelf processContent:event
                                             payload:decryptedPayload];
                            completion();
                          }];
               }];
}

/// Parses `data`, attaches the HITL `reply` block when feedback is
/// requested, then emits or buffers the event.
- (void)processContent:(NSString *)event payload:(NSDictionary *)payload {

    // `data` arrives as JSON text.
    id content = @{};
    id dataVal = payload[@"data"];
    if (dataVal) {
        id parsed = [dataVal isKindOfClass:[NSString class]]
                        ? [ARTJSON parse:(NSString *)dataVal]
                        : nil;
        content = parsed ?: dataVal;
    } else {
        content = payload;
    }

    // Human-in-the-loop: when the server asks for feedback, attach a
    // `reply` block (`void (^)(id)`) to the content so apps can answer. It
    // is not JSON; strip it before serializing the content.
    NSString *returnFlag = [payload[@"return_flag"] isKindOfClass:[NSString class]]
                               ? payload[@"return_flag"]
                               : @"";
    NSString *contentType = nil;
    if ([content isKindOfClass:[NSDictionary class]]) {
        id type = ((NSDictionary *)content)[@"type"];
        contentType = [type isKindOfClass:[NSString class]] ? type : nil;
    }
    BOOL humanFeedbackRequest =
        [returnFlag isEqualToString:@"requestFeedback"] ||
        [event isEqualToString:@"human_input_request"] ||
        [contentType isEqualToString:@"human_input_request"];
    if (humanFeedbackRequest && [content isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *withReply = [(NSDictionary *)content mutableCopy];
        NSDictionary *originalReq = [payload copy];
        __weak typeof(self) weakSelf = self;
        void (^reply)(id) = ^(id replyData) {
          [weakSelf sendHumanFeedback:originalReq replyData:replyData];
        };
        withReply[@"reply"] = [reply copy];
        content = [withReply copy];
    }

    id tid = payload[@"thread_id"];
    NSString *threadId = ([tid isKindOfClass:[NSString class]] &&
                          [(NSString *)tid length] > 0)
                             ? (NSString *)tid
                             : nil;

    if ([event isEqualToString:@"art_presence"]) {
        [self.emitter emit:@"art_presence" data:content];
        return;
    }

    // Diagnostic `trace` frames go straight to their listeners, without the
    // subscribed-state check or buffering.
    if ([event isEqualToString:@"trace"]) {
        [self emitThreadEvent:@"trace" content:content threadId:threadId];
        return;
    }

    if (!self.isSubscribed) {
        return;
    }

    // Thread events route on "<threadId>-<event>" / "<threadId>-all"; others
    // keep the plain `event` / "all" keys.
    NSString *eventKey =
        threadId ? [NSString stringWithFormat:@"%@-%@", threadId, event] : event;
    NSString *allKey =
        threadId ? [NSString stringWithFormat:@"%@-all", threadId] : @"all";

    // Check-or-buffer under the same lock as listener registration, so a
    // frame can't fall between a drain and an attach.
    BOOL hasSpecific;
    BOOL hasAll;
    @synchronized(self.stateLock) {
        hasSpecific = [self.emitter listenerCount:eventKey] > 0;
        hasAll = [self.emitter listenerCount:allKey] > 0;
        if (!hasSpecific && !hasAll) {
            // `thread_id` is kept so the entry replays into its thread.
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"content"] = content;
            for (NSString *key in @[
                     @"id", @"from", @"channel", @"to", @"pipeline_id",
                     @"thread_id", @"attempt_id", @"interceptor_name",
                     @"to_username"
                 ]) {
                id value = payload[key];
                if (value) {
                    entry[key] = value;
                }
            }
            [self bufferEventLocked:event entry:entry];
        }
    }
    if (!hasSpecific && !hasAll) {
        return;
    }

    if (hasSpecific) {
        [self emitThreadEvent:event content:content threadId:threadId];
    }
    if (hasAll) {
        [self emitThreadEvent:@"all"
                      content:@{@"event" : event, @"content" : content}
                     threadId:threadId];
    }
    [self acknowledge:payload returnFlag:@"CA"];
}

#pragma mark - Storage (orchestrator-enabled channels)

- (nullable NSError *)storageUnavailableError {
    if (self.channelConfig.orchestratorEnabled) {
        return nil;
    }
    return [NSError
        errorWithDomain:ARTUploadErrorDomain
                   code:ARTUploadStepValidate
               userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"Storage requires an orchestrator-enabled channel",
                   ARTUploadStepNameKey : ARTUploadStepName(ARTUploadStepValidate)
               }];
}

- (void)uploadFileURL:(NSURL *)fileURL
              options:(ARTUploadOptions *)options
           completion:(void (^)(ARTFileRef *_Nullable,
                                NSError *_Nullable))completion {
    NSError *error = [self storageUnavailableError];
    if (error) {
        completion(nil, error);
        return;
    }
    ARTUploadOptions *scoped = options ? [options copy] : [[ARTUploadOptions alloc] init];
    scoped.configId = self.channelConfig.channelName;
    [[[ARTStorage alloc] init] uploadFileURL:fileURL
                                     options:scoped
                                  completion:completion];
}

- (void)uploadData:(NSData *)data
          filename:(NSString *)filename
       contentType:(NSString *)contentType
           options:(ARTUploadOptions *)options
        completion:(void (^)(ARTFileRef *_Nullable,
                             NSError *_Nullable))completion {
    NSError *error = [self storageUnavailableError];
    if (error) {
        completion(nil, error);
        return;
    }
    ARTUploadOptions *scoped = options ? [options copy] : [[ARTUploadOptions alloc] init];
    scoped.configId = self.channelConfig.channelName;
    [[[ARTStorage alloc] init] uploadData:data
                                 filename:filename
                              contentType:contentType
                                  options:scoped
                               completion:completion];
}

- (void)listFilesWithOptions:(ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable,
                                       NSError *_Nullable))completion {
    NSError *error = [self storageUnavailableError];
    if (error) {
        completion(nil, error);
        return;
    }
    ARTListOptions *scoped = options ? [options copy] : [[ARTListOptions alloc] init];
    scoped.configId = self.channelConfig.channelName;
    [[[ARTStorage alloc] init] listFilesWithOptions:scoped completion:completion];
}

#pragma mark - Thread-scoped routing

- (nullable OrchestratorThread *)thread:(nullable NSString *)threadId {
    if (!self.channelConfig.orchestratorEnabled) {
        ARTLogWarn(@"Thread works only on orchestrator-enabled channels; %@ "
                   @"is not one",
                   self.channelConfig.channelName);
        return nil;
    }
    return [self threadUnchecked:threadId];
}

- (OrchestratorThread *)threadUnchecked:(nullable NSString *)threadId {
    @synchronized(self.stateLock) {
        if (threadId.length > 0) {
            OrchestratorThread *existing = self.threads[threadId];
            if (existing && !existing.isDisposed) {
                return existing;
            }
        }
        OrchestratorThread *thread =
            [[OrchestratorThread alloc] initWithSubscription:self
                                                    threadId:threadId];
        self.threads[thread.threadId] = thread;
        return thread;
    }
}

- (nullable OrchestratorThread *)getThread:(NSString *)threadId {
    @synchronized(self.stateLock) {
        return self.threads[threadId];
    }
}

- (void)unregisterThread:(NSString *)threadId {
    @synchronized(self.stateLock) {
        [self.threads removeObjectForKey:threadId];
        [self.threadBufferStorage removeObjectForKey:threadId];
    }
}

- (NSDictionary<NSString *, NSDictionary<NSString *, NSArray<NSDictionary *> *> *> *)
    threadBuffers {
    @synchronized(self.stateLock) {
        NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
        [self.threadBufferStorage
            enumerateKeysAndObjectsUsingBlock:^(
                NSString *threadId, ARTEventBuffer *buffer, BOOL *stop) {
              snapshot[threadId] = [buffer dictionary];
            }];
        return [snapshot copy];
    }
}

- (NSUUID *)attachThreadListener:(NSString *)threadId
                        callback:
                            (void (^)(NSDictionary<NSString *, id> *))callback {
    NSArray<NSArray *> *drained;
    NSUUID *identifier;
    @synchronized(self.stateLock) {
        drained = [self.threadBufferStorage[threadId] drainAll] ?: @[];
        [self.threadBufferStorage removeObjectForKey:threadId];
        identifier = [self.emitter
                 on:[NSString stringWithFormat:@"%@-all", threadId]
            handler:^(id data) {
              if ([data isKindOfClass:[NSDictionary class]]) {
                  callback((NSDictionary *)data);
              }
            }];
    }
    [self deliver:drained to:callback];
    return identifier;
}

- (NSUUID *)attachThreadBind:(NSString *)threadId
                       event:(NSString *)event
                    callback:(void (^)(id))callback {
    NSArray<NSDictionary *> *drained;
    NSUUID *identifier;
    @synchronized(self.stateLock) {
        drained = [self.threadBufferStorage[threadId] takeEvent:event] ?: @[];
        identifier = [self.emitter
                 on:[NSString stringWithFormat:@"%@-%@", threadId, event]
            handler:callback];
    }
    for (NSDictionary *entry in drained) {
        callback(entry[@"content"] ?: [NSNull null]);
        [self acknowledge:entry returnFlag:@"CA"];
    }
    return identifier;
}

- (void)detachThreadListener:(NSString *)threadId event:(NSString *)event {
    [self.emitter offEvent:[NSString stringWithFormat:@"%@-%@", threadId, event]];
    @synchronized(self.stateLock) {
        [self.threadBufferStorage[threadId] takeEvent:event];
    }
}

- (void)detachThreadListener:(NSString *)threadId
                       event:(NSString *)event
                  identifier:(NSUUID *)identifier {
    [self.emitter off:[NSString stringWithFormat:@"%@-%@", threadId, event]
           identifier:identifier];
    @synchronized(self.stateLock) {
        [self.threadBufferStorage[threadId] takeEvent:event];
    }
}

- (void)emitThreadEvent:(NSString *)event
                content:(id)content
               threadId:(nullable NSString *)threadId {
    NSString *key = threadId.length > 0
                        ? [NSString stringWithFormat:@"%@-%@", threadId, event]
                        : event;
    [self.emitter emit:key data:content];
}

/// Must be called with `stateLock` held.
- (void)bufferEventLocked:(NSString *)event entry:(NSDictionary *)entry {
    id tid = entry[@"thread_id"];
    if ([tid isKindOfClass:[NSString class]] && [(NSString *)tid length] > 0) {
        ARTEventBuffer *buffer = self.threadBufferStorage[tid];
        if (!buffer) {
            buffer = [[ARTEventBuffer alloc] init];
            self.threadBufferStorage[tid] = buffer;
        }
        [buffer appendEvent:event entry:entry];
    } else {
        [self.bufferStorage appendEvent:event entry:entry];
    }
}

#pragma mark - Human-in-the-loop reply

/// Sends a `return_flag: "HF"` frame answering a `human_input_request`,
/// echoing the routing fields from the original request.
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
        id value = originalReq[key];
        if (value) {
            reply[key] = value;
        }
    }

    // The reply goes back to the original sender, if any.
    id from = originalReq[@"from"];
    reply[@"to"] = [ARTJSON isTruthy:from] ? @[ from ] : @[];

    // The reply is JSON-encoded, so text answers are quoted.
    NSError *jsonError = nil;
    NSString *content = [ARTJSON stringify:replyData ?: [NSNull null]
                                     error:&jsonError];
    if (!content) {
        ARTLogError(@"HITL reply is not JSON-serializable: %@",
                    jsonError.localizedDescription);
        return;
    }
    reply[@"content"] = content;

    NSString *frame = [ARTJSON stringify:reply error:nil];
    if (frame) {
        [self.websocketHandler sendMessage:frame];
    }
}

@end
