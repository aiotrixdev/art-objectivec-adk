//
//  OrchestratorThread.m
//  ADK
//

#import "OrchestratorThread.h"
#import "ARTStorage.h"
#import "ARTSupport.h"
#import "ARTThreadStateStore.h"
#import "AgentEvents.h"
#import "AgentThread.h"
#import "SocketTypes.h"
#import "Subscription.h"

@interface OrchestratorThread ()
@property(nonatomic, strong) Subscription *subscription;
@property(nonatomic, strong) NSMutableSet<NSString *> *attachedEvents;
/// Channel-level `trace` listeners added by `listenTrace:`, removed one by
/// one on `dispose` so other threads keep theirs.
@property(nonatomic, strong) NSMutableArray<NSUUID *> *traceTokens;
@property(nonatomic, strong, nullable) NSUUID *stateBindToken;
@property(nonatomic, assign) BOOL stateBindPending;
@property(nonatomic, assign, readwrite, getter=isDisposed) BOOL disposed;
@property(nonatomic, strong) ARTThreadStateStore *stateStore;
@end

@implementation OrchestratorThread

- (instancetype)initWithSubscription:(Subscription *)subscription
                            threadId:(NSString *)threadId {
    self = [super init];
    if (self) {
        _subscription = subscription;
        _threadId = threadId.length ? [threadId copy] : [AgentThread generateThreadId];
        _attachedEvents = [NSMutableSet set];
        _traceTokens = [NSMutableArray array];
        _disposed = NO;
        _stateStore = [[ARTThreadStateStore alloc] initWithThreadId:_threadId
                                                   enforcesSequence:NO];
    }
    return self;
}

- (BOOL)isDisposed {
    @synchronized(self) {
        return _disposed;
    }
}

- (BOOL)guardActive:(NSString *)operation {
    if (self.isDisposed) {
        ARTLogWarn(@"OrchestratorThread %@ has been disposed; ignoring %@",
                   self.threadId, operation);
        return NO;
    }
    return YES;
}

- (nullable NSError *)disposedError {
    if (!self.isDisposed) {
        return nil;
    }
    return [NSError
        errorWithDomain:@"ADK.OrchestratorThread"
                   code:-1
               userInfo:@{
                   NSLocalizedDescriptionKey : [NSString
                       stringWithFormat:@"OrchestratorThread %@ has been disposed",
                                        self.threadId]
               }];
}

#pragma mark - Push

- (void)push:(NSString *)event
        data:(NSDictionary<NSString *, id> *)data
  completion:(void (^)(NSError *_Nullable))completion {
    [self push:event data:data options:nil completion:completion];
}

- (void)push:(NSString *)event
        data:(NSDictionary<NSString *, id> *)data
     options:(PushConfig *)options
  completion:(void (^)(NSError *_Nullable))completion {
    NSError *error = [self disposedError];
    if (error) {
        if (completion) {
            completion(error);
        }
        return;
    }
    PushConfig *merged = options ? [options copy] : [[PushConfig alloc] init];
    merged.threadID = self.threadId;
    [self.stateStore transition:ARTThreadStatePhaseSubmitted
                         source:ARTThreadStateSourceClient
                        message:@"Request submitted"
                         reason:nil
                    workspaceId:nil
                        agentId:nil];
    [self.subscription push:event
                       data:data
                    options:merged
                 completion:^(NSError *_Nullable pushError) {
                   if (completion) {
                       completion(pushError);
                   }
                 }];
}

#pragma mark - Storage (thread-scoped)

- (void)uploadFileURL:(NSURL *)fileURL
              options:(ARTUploadOptions *)options
           completion:(void (^)(ARTFileRef *_Nullable,
                                NSError *_Nullable))completion {
    NSError *error = [self disposedError];
    if (error) {
        completion(nil, error);
        return;
    }
    ARTUploadOptions *scoped = options ? [options copy] : [[ARTUploadOptions alloc] init];
    scoped.configId = self.threadId;
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
    NSError *error = [self disposedError];
    if (error) {
        completion(nil, error);
        return;
    }
    ARTUploadOptions *scoped = options ? [options copy] : [[ARTUploadOptions alloc] init];
    scoped.configId = self.threadId;
    [[[ARTStorage alloc] init] uploadData:data
                                 filename:filename
                              contentType:contentType
                                  options:scoped
                               completion:completion];
}

- (void)listFilesWithOptions:(ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable,
                                       NSError *_Nullable))completion {
    NSError *error = [self disposedError];
    if (error) {
        completion(nil, error);
        return;
    }
    ARTListOptions *scoped = options ? [options copy] : [[ARTListOptions alloc] init];
    scoped.configId = self.threadId;
    [[[ARTStorage alloc] init] listFilesWithOptions:scoped completion:completion];
}

#pragma mark - Listeners

- (void)listen:(void (^)(NSDictionary<NSString *, id> *))callback {
    if (![self guardActive:@"listen"]) {
        return;
    }
    [self.subscription attachThreadListener:self.threadId callback:callback];
    @synchronized(self) {
        [self.attachedEvents addObject:@"all"];
    }
}

- (void)bind:(NSString *)event callback:(void (^)(id))callback {
    if (![self guardActive:@"bind"]) {
        return;
    }
    [self.subscription attachThreadBind:self.threadId event:event callback:callback];
    @synchronized(self) {
        [self.attachedEvents addObject:event];
    }
}

- (void)listenTrace:(void (^)(id))callback {
    if (![self guardActive:@"listenTrace"]) {
        return;
    }
    NSUUID *token = [self.subscription bind:@"trace" callback:callback];
    [self.subscription attachThreadBind:self.threadId event:@"trace" callback:callback];
    @synchronized(self) {
        [self.traceTokens addObject:token];
        [self.attachedEvents addObject:@"trace"];
    }
}

- (void (^)(void))listenState:(void (^)(ARTThreadState *))callback {
    return [self listenState:callback emitCurrent:YES];
}

- (void (^)(void))listenState:(void (^)(ARTThreadState *))callback
                  emitCurrent:(BOOL)emitCurrent {
    if (![self guardActive:@"listenState"]) {
        return ^{
        };
    }

    // One thread-scoped `thread_state` binding feeds every state callback
    // (a binding per callback would apply each event several times).
    BOOL needsBinding = NO;
    @synchronized(self) {
        if (!self.stateBindToken && !self.stateBindPending) {
            self.stateBindPending = YES;
            needsBinding = YES;
        }
    }
    if (needsBinding) {
        __weak typeof(self) weakSelf = self;
        NSUUID *token = [self.subscription
            attachThreadBind:self.threadId
                       event:@"thread_state"
                    callback:^(id content) {
                      if ([content isKindOfClass:[NSDictionary class]]) {
                          [weakSelf.stateStore
                              apply:[[ARTThreadState alloc]
                                        initWithMap:(NSDictionary *)content]];
                      }
                    }];
        @synchronized(self) {
            self.stateBindToken = token;
            self.stateBindPending = NO;
            [self.attachedEvents addObject:@"thread_state"];
        }
    }

    NSUUID *identifier = [self.stateStore addListener:callback];
    if (emitCurrent) {
        callback(self.stateStore.state);
    }

    __weak typeof(self) weakSelf = self;
    return ^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          return;
      }
      [strongSelf.stateStore removeListener:identifier];
      if (strongSelf.stateStore.hasListeners) {
          return;
      }
      NSUUID *token;
      @synchronized(strongSelf) {
          token = strongSelf.stateBindToken;
          strongSelf.stateBindToken = nil;
          [strongSelf.attachedEvents removeObject:@"thread_state"];
      }
      if (token && !strongSelf.isDisposed) {
          [strongSelf.subscription detachThreadListener:strongSelf.threadId
                                                  event:@"thread_state"
                                             identifier:token];
      }
    };
}

- (ARTThreadState *)getState {
    return self.stateStore.state;
}

- (void)remove:(NSString *)event {
    if (self.isDisposed) {
        return;
    }
    [self.subscription detachThreadListener:self.threadId event:event];
    @synchronized(self) {
        [self.attachedEvents removeObject:event];
    }
}

- (void)dispose {
    NSSet<NSString *> *events;
    NSArray<NSUUID *> *traceTokens;
    @synchronized(self) {
        if (_disposed) {
            return;
        }
        _disposed = YES;
        events = [self.attachedEvents copy];
        traceTokens = [self.traceTokens copy];
        [self.attachedEvents removeAllObjects];
        [self.traceTokens removeAllObjects];
        self.stateBindToken = nil;
    }

    for (NSString *event in events) {
        [self.subscription detachThreadListener:self.threadId event:event];
    }
    // `listenTrace:` also bound channel-level `trace` listeners; remove only
    // this thread's, leaving other threads' in place.
    for (NSUUID *token in traceTokens) {
        [self.subscription remove:@"trace" identifier:token];
    }
    [self.stateStore removeAllListeners];
    [self.subscription unregisterThread:self.threadId];
}

@end
