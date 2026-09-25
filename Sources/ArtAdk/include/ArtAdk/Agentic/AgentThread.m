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
#import "SocketTypes.h"
#import "Subscription.h"

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
        _lock = [[NSLock alloc] init];
        _stateStore = [[ARTThreadStateStore alloc] initWithThreadId:_threadId
                                                   enforcesSequence:YES];
    }
    return self;
}

+ (NSString *)generateThreadId {
    return [NSUUID UUID].UUIDString.lowercaseString;
}

#pragma mark - Master listener

/// Installs, once, the subscription listeners that fan out to user
/// callbacks and the active run: the channel-wide `listen` plus the
/// thread-scoped route for frames tagged with this `thread_id`. A failed
/// subscribe is retried on the next call.
- (void)ensureMasterListener:(nullable void (^)(void))done {
    [self.lock lock];
    if (self.masterAttached) {
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
      if (sub) {
          [sub listen:^(NSDictionary<NSString *, id> *raw) {
            [weakSelf dispatchRaw:raw];
          }];
          [sub attachThreadListener:strongSelf.threadId
                           callback:^(NSDictionary<NSString *, id> *raw) {
                             [weakSelf dispatchRaw:raw];
                           }];
      } else {
          ARTLogError(@"[adk] agent subscription failed: %@",
                      error.localizedDescription ?: @"no subscription");
      }
      NSArray<void (^)(void)> *pending;
      [strongSelf.lock lock];
      strongSelf.masterAttached = (sub != nil);
      strongSelf.attaching = NO;
      pending = [strongSelf.pendingAfterAttach copy];
      [strongSelf.pendingAfterAttach removeAllObjects];
      [strongSelf.lock unlock];
      for (void (^callback)(void) in pending) {
          callback();
      }
    }];
}

- (void)dispatchRaw:(NSDictionary *)raw {
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
        [self.stateStore transition:ARTThreadStatePhaseFailed
                             source:ARTThreadStateSourceAgent
                            message:@"Execution failed"
                             reason:envelope.asError.message
                        workspaceId:nil
                            agentId:nil];
        break;
    case AgentEventKindPlannerCorrection:
    case AgentEventKindUnknown:
        break;
    }
}

#pragma mark - Listeners

- (void)listen:(AgentUserListener)callback {
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
    void (^cb)(id) = [callback copy];
    __weak typeof(self) weakSelf = self;
    [self.agent getSubscription:^(Subscription *_Nullable sub,
                                  NSError *_Nullable error) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!sub || !strongSelf) {
          return;
      }
      [sub bind:@"trace" callback:cb];
      [sub attachThreadBind:strongSelf.threadId event:@"trace" callback:cb];
    }];
}

- (void)feedbackRequest:(AgentHumanInputHandler)handler {
    [self.lock lock];
    [self.feedbackHandlers addObject:[handler copy]];
    [self.lock unlock];
}

#pragma mark - Run

- (void)run:(id)userInput
     replyId:(nullable NSString *)replyId
  completion:(void (^)(Run *_Nullable, NSError *_Nullable))completion {
    [self run:userInput replyId:replyId fileMeta:nil completion:completion];
}

- (void)run:(id)userInput
     replyId:(nullable NSString *)replyId
    fileMeta:(nullable NSArray<ARTFileMeta *> *)fileMeta
  completion:(void (^)(Run *_Nullable, NSError *_Nullable))completion {
    __weak typeof(self) weakSelf = self;
    [self ensureMasterListener:^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          completion(nil, [NSError errorWithDomain:@"ADK.AgentThread"
                                              code:-1
                                          userInfo:@{
                                              NSLocalizedDescriptionKey :
                                                  @"AgentThread deallocated"
                                          }]);
          return;
      }

      Run *run = [[Run alloc] initWithThread:strongSelf];
      Run *previous;
      [strongSelf.lock lock];
      previous = strongSelf.activeRun;
      strongSelf.activeRun = run;
      [strongSelf.lock unlock];
      if (previous && !previous.isClosed) {
          ARTLogWarn(@"[adk] starting new run while previous run is still "
                     @"active — closing previous");
          [previous close:@"Superseded by new run on the same thread"];
      }

      [strongSelf.stateStore transition:ARTThreadStatePhaseSubmitted
                                 source:ARTThreadStateSourceClient
                                message:@"Request submitted"
                                 reason:nil
                            workspaceId:nil
                                agentId:nil];

      NSString *threadId = strongSelf.threadId;
      [strongSelf.agent getSubscription:^(Subscription *_Nullable sub,
                                          NSError *_Nullable error) {
        if (error || !sub) {
            completion(nil, error);
            return;
        }
        NSString *event = replyId ? @"user_reply" : @"user_input";
        NSMutableDictionary *content = [@{
            @"user_input" : userInput ?: @"",
            @"thread_id" : threadId
        } mutableCopy];
        if (replyId) {
            content[@"reply_id"] = replyId;
        }
        PushConfig *options = [[PushConfig alloc] initWithTo:@[]
                                                    threadID:threadId
                                                    fileMeta:fileMeta];
        [sub pushEvent:event
                  data:content
               options:options
            completion:^(NSString *_Nullable refId, NSError *_Nullable pushErr) {
              if (pushErr) {
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
    ARTListOptions *scoped = options ? [options copy] : [[ARTListOptions alloc] init];
    scoped.configId = self.threadId;
    [[[ARTStorage alloc] init] listFilesWithOptions:scoped completion:completion];
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
    NSString *threadId = self.threadId;
    [self.agent getSubscription:^(Subscription *_Nullable sub,
                                  NSError *_Nullable error) {
      if (error || !sub) {
          if (completion) {
              completion(nil, error);
          }
          return;
      }
      NSDictionary *content = @{
          @"user_input" : value ?: @"",
          @"thread_id" : threadId,
          @"reply_id" : replyId ?: @""
      };
      [sub pushEvent:@"user_reply"
                data:content
             options:[[PushConfig alloc] initWithTo:@[] threadID:threadId]
          completion:^(NSString *_Nullable refId, NSError *_Nullable pushErr) {
            if (completion) {
                completion(refId ?: @"", pushErr);
            }
          }];
    }];
}

@end
