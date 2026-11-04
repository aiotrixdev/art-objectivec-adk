//
//  AgentThread.m
//  ADK
//

#import "AgentThread.h"
#import "ARTStorage.h"
#import "ARTSupport.h"
#import "ARTThreadStateStore.h"
#import "Agent.h"
#import "AgentEvents.h"
#import "Run.h"
#import "Socket.h"
#import "SocketTypes.h"
#import "Subscription.h"
#import "Utils.h"

@interface AgentThread ()
@property(nonatomic, strong, readwrite) Agent *agent;
@property(nonatomic, copy, readwrite) NSString *threadId;
@property(nonatomic, strong) NSMutableArray<AgentUserListener> *userListeners;
@property(nonatomic, strong)
    NSMutableArray<AgentHumanInputHandler> *feedbackHandlers;
@property(nonatomic, strong, nullable) Run *activeRun;
@property(nonatomic, assign) BOOL masterAttached;
@property(nonatomic, assign) BOOL attaching;
@property(nonatomic, strong) NSMutableArray<void (^)(void)> *pendingAfterAttach;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) ARTThreadStateStore *stateStore;
@property(nonatomic, assign, readwrite, getter=isDisposed) BOOL disposed;
/// Origin of the latest run; replies keep it.
@property(nonatomic, copy, nullable) ARTExecutionOrigin executionOrigin;
@property(nonatomic, strong, nullable) Subscription *subscription;
@property(nonatomic, strong, nullable) NSUUID *channelListenerId;
@property(nonatomic, strong, nullable) NSUUID *threadListenerId;
@property(nonatomic, strong, nullable) NSUUID *connectionListenerId;
/// `@[channel token, thread token]` pairs added by `listenTrace:`.
@property(nonatomic, strong) NSMutableArray<NSArray<NSUUID *> *> *traceListeners;
@end

@implementation AgentThread

- (instancetype)initWithAgent:(Agent *)agent {
    return [self initWithAgent:agent threadId:nil];
}

- (instancetype)initWithAgent:(Agent *)agent threadId:(nullable NSString *)threadId {
    self = [super init];
    if (self) {
        _agent = agent;
        _threadId = threadId.length > 0 ? [threadId copy]
                                         : [[self class] generateThreadId];
        _userListeners = [NSMutableArray array];
        _feedbackHandlers = [NSMutableArray array];
        _pendingAfterAttach = [NSMutableArray array];
        _traceListeners = [NSMutableArray array];
        _lock = [[NSLock alloc] init];
        _stateStore = [[ARTThreadStateStore alloc] initWithThreadId:_threadId
                                                   enforcesSequence:YES];
    }
    return self;
}

+ (NSString *)generateThreadId {
    return [NSUUID UUID].UUIDString.lowercaseString;
}

#pragma mark - Lifecycle

- (BOOL)isDisposed {
    [self.lock lock];
    BOOL disposed = _disposed;
    [self.lock unlock];
    return disposed;
}

- (void)dispose {
    Run *run;
    Subscription *sub;
    NSUUID *channel;
    NSUUID *thread;
    NSUUID *connection;
    NSArray<NSArray<NSUUID *> *> *traces;
    [self.lock lock];
    if (_disposed) {
        [self.lock unlock];
        return;
    }
    _disposed = YES;
    run = self.activeRun;
    sub = self.subscription;
    channel = self.channelListenerId;
    thread = self.threadListenerId;
    connection = self.connectionListenerId;
    traces = [self.traceListeners copy];
    self.activeRun = nil;
    [self.userListeners removeAllObjects];
    [self.feedbackHandlers removeAllObjects];
    self.channelListenerId = nil;
    self.threadListenerId = nil;
    self.connectionListenerId = nil;
    [self.traceListeners removeAllObjects];
    [self.lock unlock];

    [run abort:@"Thread disposed"];
    [self.stateStore removeAllListeners];
    if (connection) {
        [self.agent.socket offConnectionFailure:connection];
    }
    if (channel) {
        [sub remove:@"all" identifier:channel];
    }
    if (thread) {
        [sub detachThreadListener:self.threadId event:@"all" identifier:thread];
    }
    for (NSArray<NSUUID *> *trace in traces) {
        [sub remove:@"trace" identifier:trace[0]];
        [sub detachThreadListener:self.threadId event:@"trace" identifier:trace[1]];
    }
}

- (nullable NSError *)disposedError {
    if (!self.isDisposed) {
        return nil;
    }
    return MakeError(ErrorCodeServerError,
                     [NSString stringWithFormat:@"AgentThread %@ has been disposed",
                                                self.threadId]);
}

- (BOOL)guardActive:(NSString *)operation {
    if (self.isDisposed) {
        ARTLogWarn(@"AgentThread %@ has been disposed; ignoring %@", self.threadId,
                   operation);
        return NO;
    }
    return YES;
}

#pragma mark - Master listener

/// Installs, once, the subscription listeners that fan out to user callbacks
/// and the active run: the channel-wide `listen`, the thread-scoped route for
/// frames tagged with this `thread_id`, and the connection-failure listener.
/// A failed subscribe is retried on the next call.
- (void)ensureMasterListener:(nullable void (^)(void))done {
    [self.lock lock];
    if (self.masterAttached || _disposed) {
        [self.lock unlock];
        if (done) {
            done();
        }
        return;
    }
    if (done) {
        [self.pendingAfterAttach addObject:[done copy]];
    }
    if (self.attaching) {
        [self.lock unlock];
        return;
    }
    self.attaching = YES;
    [self.lock unlock];

    __weak typeof(self) weakSelf = self;
    [self.agent getSubscription:^(Subscription *_Nullable sub,
                                  NSError *_Nullable error) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          return;
      }
      BOOL attached = NO;
      if (sub) {
          attached = [strongSelf attachListenersTo:sub];
      } else {
          ARTLogError(@"[adk] agent subscription failed: %@",
                      error.localizedDescription ?: @"no subscription");
      }
      NSArray<void (^)(void)> *pending;
      [strongSelf.lock lock];
      strongSelf.masterAttached = attached;
      strongSelf.attaching = NO;
      pending = [strongSelf.pendingAfterAttach copy];
      [strongSelf.pendingAfterAttach removeAllObjects];
      [strongSelf.lock unlock];
      for (void (^callback)(void) in pending) {
          callback();
      }
    }];
}

/// Returns NO, leaving nothing attached, when the thread was disposed
/// meanwhile.
- (BOOL)attachListenersTo:(Subscription *)sub {
    if (self.isDisposed) {
        return NO;
    }
    __weak typeof(self) weakSelf = self;
    NSUUID *channel = [sub listen:^(NSDictionary<NSString *, id> *raw) {
      [weakSelf dispatchRaw:raw];
    }];
    NSUUID *thread = [sub attachThreadListener:self.threadId
                                      callback:^(NSDictionary<NSString *, id> *raw) {
                                        [weakSelf dispatchRaw:raw];
                                      }];
    NSUUID *connection =
        [self.agent.socket onConnectionFailure:^(ARTConnectionError *error) {
          [weakSelf handleConnectionFailure:error];
        }];

    BOOL kept = NO;
    [self.lock lock];
    if (!_disposed) {
        kept = YES;
        self.subscription = sub;
        self.channelListenerId = channel;
        self.threadListenerId = thread;
        self.connectionListenerId = connection;
    }
    [self.lock unlock];
    if (!kept) {
        [sub remove:@"all" identifier:channel];
        [sub detachThreadListener:self.threadId event:@"all" identifier:thread];
        [self.agent.socket offConnectionFailure:connection];
    }
    return kept;
}

/// Ends the active run with an `agent_error` when the connection fails, since
/// no channel event can arrive after that. Its details carry
/// `source: connection` and `execution_status: unknown`: the client can no
/// longer tell whether the server finished the execution.
- (void)handleConnectionFailure:(ARTConnectionError *)error {
    [self.lock lock];
    BOOL hasRun = self.activeRun != nil;
    [self.lock unlock];
    if (!hasRun) {
        return;
    }
    NSMutableDictionary *details = [@{
        @"reason" : error.message,
        @"source" : @"connection",
        @"execution_status" : @"unknown",
    } mutableCopy];
    if (error.status) {
        details[@"status"] = error.status;
    }
    [self dispatchRaw:@{
        @"event" : @"agent_error",
        @"content" : @{
            @"type" : @"agent_error_response",
            @"status" : @"error",
            @"code" : error.connectionCode,
            @"message" : error.message,
            @"details" : details,
            @"thread_id" : self.threadId,
            @"ref_id" : @"",
            @"agent_id" : self.agent.agentId,
            @"reply_to" : @"",
        },
    }];
}

- (void)dispatchRaw:(NSDictionary *)raw {
    if (self.isDisposed) {
        return;
    }
    AgentEventEnvelope *envelope = [AgentEventEnvelope parse:raw];

    // Surface wire-level transport errors as a typed error_response so the
    // active Run rejects and listeners get a normalised envelope.
    if ([envelope.event isEqualToString:@"error"] ||
        [envelope.event isEqualToString:@"transport_error"]) {
        NSString *message = @"WebSocket error";
        NSDictionary *details = nil;
        UnknownAgentEvent *unknown = envelope.asUnknown;
        if (unknown) {
            id m = unknown.content[@"message"] ?: unknown.content[@"error"];
            if ([m isKindOfClass:[NSString class]]) {
                message = (NSString *)m;
            }
            details = unknown.content;
        }
        AgentError *err = [[AgentError alloc] initWithCode:@"TRANSPORT_ERROR"
                                                   message:message
                                                   details:details
                                                  threadId:self.threadId
                                                     refId:@""
                                                   agentId:self.agent.agentId
                                                   replyTo:@""];
        // Same fields as a server-sent `agent_error_response`.
        NSMutableDictionary *content = [@{
            @"type" : @"agent_error_response",
            @"status" : @"error",
            @"code" : err.code,
            @"message" : err.message,
            @"thread_id" : err.threadId,
            @"ref_id" : err.refId,
            @"agent_id" : err.agentId ?: @"",
            @"reply_to" : err.replyTo,
        } mutableCopy];
        if (details) {
            content[@"details"] = details;
        }
        envelope = [[AgentEventEnvelope alloc] initWithEvent:@"agent_error_response"
                                                        kind:AgentEventKindError
                                                     payload:err
                                                     content:content];
    }

    if (!envelope.isKnown) {
        ARTLogWarn(@"[adk] unknown agent event \"%@\" — passing through "
                   @"untyped.",
                   envelope.event);
    }

    [self updateStateForEnvelope:envelope];

    Run *run;
    NSArray<AgentUserListener> *listeners;
    [self.lock lock];
    run = self.activeRun;
    listeners = [self.userListeners copy];
    [self.lock unlock];

    [run pushEnvelope:envelope];
    for (AgentUserListener callback in listeners) {
        callback(envelope);
    }
}

/// Operational state transitions driven by inbound events.
- (void)updateStateForEnvelope:(AgentEventEnvelope *)envelope {
    switch (envelope.kind) {
    case AgentEventKindThreadState:
        [self.stateStore apply:envelope.asThreadState];
        break;
    case AgentEventKindHumanInput:
        [self.stateStore transition:ARTThreadStatePhaseWaitingForApproval
                             source:ARTThreadStateSourceAgent
                            message:@"Waiting for your input"
                             reason:envelope.asHumanInput.prompt
                        workspaceId:nil
                            agentId:nil];
        break;
    case AgentEventKindWait: {
        AgentWait *wait = envelope.asWait;
        NSString *workspaceId =
            [ARTJSON stringValue:wait.progress[@"workspace_id"]];
        NSString *waitingFor =
            wait.waitingForAgentId.length > 0 ? wait.waitingForAgentId : nil;
        if (workspaceId) {
            [self.stateStore transition:ARTThreadStatePhaseWaitingForWorkspace
                                 source:ARTThreadStateSourceWorkspace
                                message:@"Waiting for workspace"
                                 reason:wait.reason
                            workspaceId:workspaceId
                                agentId:waitingFor];
        } else {
            [self.stateStore transition:ARTThreadStatePhaseWaitingForAgent
                                 source:ARTThreadStateSourceAgent
                                message:@"Waiting for another agent"
                                 reason:wait.reason
                            workspaceId:nil
                                agentId:waitingFor];
        }
        break;
    }
    case AgentEventKindOutput:
        [self.stateStore transition:ARTThreadStatePhaseCompleted
                             source:ARTThreadStateSourceAgent
                            message:@"Completed"
                             reason:nil
                        workspaceId:nil
                            agentId:nil];
        break;
    case AgentEventKindError:
        if ([envelope.asError.details[@"source"] isEqual:@"connection"]) {
            [self.stateStore transition:ARTThreadStatePhaseFailed
                                 source:ARTThreadStateSourceClient
                                message:@"Connection unavailable"
                                 reason:envelope.asError.message
                            workspaceId:nil
                                agentId:nil];
        } else {
            [self.stateStore transition:ARTThreadStatePhaseFailed
                                 source:ARTThreadStateSourceAgent
                                message:@"Execution failed"
                                 reason:envelope.asError.message
                            workspaceId:nil
                                agentId:nil];
        }
        break;
    case AgentEventKindPlannerCorrection:
    case AgentEventKindUnknown:
        break;
    }
}

#pragma mark - Listeners

- (void)listen:(AgentUserListener)callback {
    if (![self guardActive:@"listen"]) {
        return;
    }
    [self.lock lock];
    [self.userListeners addObject:[callback copy]];
    [self.lock unlock];
    [self ensureMasterListener:nil];
}

- (ARTStateUnsubscribe)listenState:(void (^)(ARTThreadState *))callback {
    return [self listenState:callback emitCurrent:YES];
}

- (ARTStateUnsubscribe)listenState:(void (^)(ARTThreadState *))callback
                       emitCurrent:(BOOL)emitCurrent {
    if (![self guardActive:@"listenState"]) {
        return ^{
        };
    }
    NSUUID *identifier = [self.stateStore addListener:callback];
    if (emitCurrent) {
        callback(self.stateStore.state);
    }
    [self ensureMasterListener:nil];
    __weak typeof(self) weakSelf = self;
    return ^{
      [weakSelf.stateStore removeListener:identifier];
    };
}

- (ARTThreadState *)getState {
    return self.stateStore.state;
}

- (void)listenTrace:(void (^)(id data))callback {
    if (![self guardActive:@"listenTrace"]) {
        return;
    }
    void (^cb)(id) = [callback copy];
    __weak typeof(self) weakSelf = self;
    [self.agent getSubscription:^(Subscription *_Nullable sub,
                                  NSError *_Nullable error) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!sub || !strongSelf) {
          return;
      }
      NSUUID *channel = [sub bind:@"trace" callback:cb];
      NSUUID *thread = [sub attachThreadBind:strongSelf.threadId
                                       event:@"trace"
                                    callback:cb];
      BOOL kept = NO;
      [strongSelf.lock lock];
      if (!strongSelf->_disposed) {
          kept = YES;
          strongSelf.subscription = sub;
          [strongSelf.traceListeners addObject:@[ channel, thread ]];
      }
      [strongSelf.lock unlock];
      if (!kept) {
          [sub remove:@"trace" identifier:channel];
          [sub detachThreadListener:strongSelf.threadId
                              event:@"trace"
                         identifier:thread];
      }
    }];
}

- (void)feedbackRequest:(AgentHumanInputHandler)handler {
    if (![self guardActive:@"feedbackRequest"]) {
        return;
    }
    [self.lock lock];
    [self.feedbackHandlers addObject:[handler copy]];
    [self.lock unlock];
}

#pragma mark - Run

- (void)run:(id)userInput
     replyId:(nullable NSString *)replyId
  completion:(void (^)(Run *_Nullable, NSError *_Nullable))completion {
    [self run:userInput
                replyId:replyId
               fileMeta:nil
        executionOrigin:nil
             completion:completion];
}

- (void)run:(id)userInput
     replyId:(nullable NSString *)replyId
    fileMeta:(nullable NSArray<ARTMediaRef *> *)fileMeta
  completion:(void (^)(Run *_Nullable, NSError *_Nullable))completion {
    [self run:userInput
                replyId:replyId
               fileMeta:fileMeta
        executionOrigin:nil
             completion:completion];
}

- (void)run:(id)userInput
            replyId:(nullable NSString *)replyId
           fileMeta:(nullable NSArray<ARTMediaRef *> *)fileMeta
    executionOrigin:(nullable ARTExecutionOrigin)executionOrigin
         completion:(void (^)(Run *_Nullable, NSError *_Nullable))completion {
    [self.lock lock];
    self.executionOrigin = executionOrigin;
    [self.lock unlock];

    NSError *disposed = [self disposedError];
    if (disposed) {
        completion(nil, disposed);
        return;
    }

    [self ensureMasterListener:^{
      [self.agent getSubscription:^(Subscription *_Nullable sub,
                                    NSError *_Nullable error) {
        if (error || !sub) {
            completion(nil, error);
            return;
        }
        NSError *disposedMeanwhile = [self disposedError];
        if (disposedMeanwhile) {
            completion(nil, disposedMeanwhile);
            return;
        }

        Run *run = [[Run alloc] initWithThread:self];
        Run *previous;
        [self.lock lock];
        previous = self.activeRun;
        self.activeRun = run;
        [self.lock unlock];
        if (previous && !previous.isClosed) {
            ARTLogWarn(@"[adk] starting new run while previous run is still "
                       @"active — closing previous");
            [previous close:@"Superseded by new run on the same thread"];
        }

        [self.stateStore transition:ARTThreadStatePhaseSubmitted
                             source:ARTThreadStateSourceClient
                            message:@"Request submitted"
                             reason:nil
                        workspaceId:nil
                            agentId:nil];

        NSString *event = replyId ? @"user_reply" : @"user_input";
        NSMutableDictionary *content = [@{
            @"user_input" : userInput ?: @"",
            @"thread_id" : self.threadId
        } mutableCopy];
        if (replyId) {
            content[@"reply_id"] = replyId;
        }
        PushConfig *options = [[PushConfig alloc] initWithTo:@[]
                                                    threadID:self.threadId
                                                    fileMeta:fileMeta
                                             executionOrigin:executionOrigin];
        [sub pushEvent:event
                  data:content
               options:options
            completion:^(NSString *_Nullable refId, NSError *_Nullable pushErr) {
              if (pushErr) {
                  if ([pushErr isKindOfClass:[ARTConnectionError class]]) {
                      [self handleConnectionFailure:(ARTConnectionError *)pushErr];
                  }
                  [run abort:pushErr.localizedDescription
                                 ?: @"The request could not be sent."];
                  [self closeRun:run];
                  completion(nil, pushErr);
                  return;
              }
              [run setRefId:refId ?: @""];
              completion(run, nil);
            }];
      }];
    }];
}

#pragma mark - Storage (thread-scoped)

- (void)uploadFileURL:(NSURL *)fileURL
              options:(ARTUploadOptions *)options
           completion:(void (^)(ARTFileRef *_Nullable,
                                NSError *_Nullable))completion {
    [self.agent configurationId:^(NSString *configId, NSError *error) {
      if (!configId) {
          completion(nil, error);
          return;
      }
      ARTUploadOptions *scoped = options ? [options copy] : [[ARTUploadOptions alloc] init];
      scoped.configId = configId;
      scoped.threadId = self.threadId;
      [[[ARTStorage alloc] init] uploadFileURL:fileURL
                                       options:scoped
                                    completion:completion];
    }];
}

- (void)uploadData:(NSData *)data
          filename:(NSString *)filename
       contentType:(NSString *)contentType
           options:(ARTUploadOptions *)options
        completion:(void (^)(ARTFileRef *_Nullable,
                             NSError *_Nullable))completion {
    [self.agent configurationId:^(NSString *configId, NSError *error) {
      if (!configId) {
          completion(nil, error);
          return;
      }
      ARTUploadOptions *scoped = options ? [options copy] : [[ARTUploadOptions alloc] init];
      scoped.configId = configId;
      scoped.threadId = self.threadId;
      [[[ARTStorage alloc] init] uploadData:data
                                   filename:filename
                                contentType:contentType
                                    options:scoped
                                 completion:completion];
    }];
}

- (void)listFilesWithOptions:(ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable,
                                       NSError *_Nullable))completion {
    [self.agent configurationId:^(NSString *configId, NSError *error) {
      if (!configId) {
          completion(nil, error);
          return;
      }
      ARTListOptions *scoped = options ? [options copy] : [[ARTListOptions alloc] init];
      scoped.configId = configId;
      scoped.threadId = self.threadId;
      [[[ARTStorage alloc] init] listFilesWithOptions:scoped completion:completion];
    }];
}

#pragma mark - Internal (Run)

- (void)fireRequestFeedback:(HumanInputRequest *)req run:(Run *)run {
    NSArray<AgentHumanInputHandler> *handlers;
    [self.lock lock];
    handlers = [self.feedbackHandlers copy];
    [self.lock unlock];
    for (AgentHumanInputHandler handler in handlers) {
        handler(req, run);
    }
}

- (void)closeRun:(Run *)run {
    [self.lock lock];
    if (self.activeRun == run) {
        self.activeRun = nil;
    }
    [self.lock unlock];
}

- (void)sendReply:(id)value
          replyId:(NSString *)replyId
       completion:(nullable void (^)(NSString *_Nullable,
                                     NSError *_Nullable))completion {
    NSError *disposed = [self disposedError];
    if (disposed) {
        if (completion) {
            completion(nil, disposed);
        }
        return;
    }
    NSString *threadId = self.threadId;
    [self.agent getSubscription:^(Subscription *_Nullable sub,
                                  NSError *_Nullable error) {
      if (error || !sub) {
          if (completion) {
              completion(nil, error);
          }
          return;
      }
      NSError *disposedMeanwhile = [self disposedError];
      if (disposedMeanwhile) {
          if (completion) {
              completion(nil, disposedMeanwhile);
          }
          return;
      }
      NSDictionary *content = @{
          @"user_input" : value ?: @"",
          @"thread_id" : threadId,
          @"reply_id" : replyId ?: @""
      };
      [self.lock lock];
      ARTExecutionOrigin origin = self.executionOrigin;
      [self.lock unlock];
      [sub pushEvent:@"user_reply"
                data:content
             options:[[PushConfig alloc] initWithTo:@[]
                                           threadID:threadId
                                           fileMeta:nil
                                    executionOrigin:origin]
          completion:^(NSString *_Nullable refId, NSError *_Nullable pushErr) {
            if (completion) {
                completion(refId ?: @"", pushErr);
            }
          }];
    }];
}

@end
