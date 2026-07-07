//
//  AgentThread.m
//  ADK
//

#import "AgentThread.h"
#import "Agent.h"
#import "Run.h"
#import "AgentEvents.h"
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
@end

@implementation AgentThread

- (instancetype)initWithAgent:(Agent *)agent {
    self = [super init];
    if (self) {
        _agent = agent;
        _threadId = [[self class] generateThreadId];
        _userListeners = [NSMutableArray array];
        _feedbackHandlers = [NSMutableArray array];
        _pendingAfterAttach = [NSMutableArray array];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

+ (NSString *)generateThreadId {
    long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    uint32_t value = arc4random();
    static const char *digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    char buf[8];
    int i = 8;
    if (value == 0) {
        buf[--i] = '0';
    }
    while (value > 0 && i > 0) {
        buf[--i] = digits[value % 36];
        value /= 36;
    }
    NSString *rand = [[NSString alloc] initWithBytes:buf + i
                                              length:(NSUInteger)(8 - i)
                                            encoding:NSASCIIStringEncoding];
    return [NSString stringWithFormat:@"thread_%lld_%@", ts, rand];
}

#pragma mark - Master listener

- (void)ensureMasterListener:(nullable void (^)(void))done {
    [self.lock lock];
    if (self.masterAttached) {
        [self.lock unlock];
        if (done) done();
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
            __strong typeof(weakSelf) s2 = weakSelf;
            [s2 dispatchRaw:raw];
          }];
      }
      NSArray<void (^)(void)> *pending;
      [strongSelf.lock lock];
      if (sub) {
          strongSelf.masterAttached = YES;
      }
      strongSelf.attaching = NO;
      pending = [strongSelf.pendingAfterAttach copy];
      [strongSelf.pendingAfterAttach removeAllObjects];
      [strongSelf.lock unlock];
      for (void (^cb)(void) in pending) {
          cb();
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
        UnknownAgentEvent *unknown = envelope.asUnknown;
        if (unknown) {
            id m = unknown.content[@"message"] ?: unknown.content[@"error"];
            if ([m isKindOfClass:[NSString class]]) {
                message = (NSString *)m;
            }
        }
        AgentError *err = [[AgentError alloc] initWithCode:@"TRANSPORT_ERROR"
                                                   message:message
                                                   details:nil
                                                  threadId:self.threadId
                                                     refId:@""
                                                   agentId:self.agent.agentId
                                                   replyTo:@""];
        envelope = [[AgentEventEnvelope alloc] initWithEvent:@"agent_error_response"
                                                        kind:AgentEventKindError
                                                     payload:err];
    }

    Run *run = self.activeRun;
    if (run) {
        [run pushEnvelope:envelope];
    }

    NSArray<AgentUserListener> *listeners;
    [self.lock lock];
    listeners = [self.userListeners copy];
    [self.lock unlock];
    for (AgentUserListener cb in listeners) {
        cb(envelope);
    }
}

#pragma mark - Public

- (void)listen:(AgentUserListener)callback {
    [self.lock lock];
    [self.userListeners addObject:[callback copy]];
    [self.lock unlock];
    [self ensureMasterListener:nil];
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

- (void)run:(id)userInput
     replyId:(nullable NSString *)replyId
  completion:(void (^)(Run *_Nullable, NSError *_Nullable))completion {
    __weak typeof(self) weakSelf = self;
    [self ensureMasterListener:^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          completion(nil, [NSError errorWithDomain:@"ADK.AgentThread"
                                              code:-1
                                          userInfo:nil]);
          return;
      }

      if (strongSelf.activeRun && !strongSelf.activeRun.isClosed) {
          [strongSelf.activeRun
              close:@"Superseded by new run on the same thread"];
      }
      Run *run = [[Run alloc] initWithThread:strongSelf];
      strongSelf.activeRun = run;

      [strongSelf.agent getSubscription:^(Subscription *_Nullable sub,
                                          NSError *_Nullable error) {
        if (error || !sub) {
            completion(nil, error);
            return;
        }
        NSString *event = replyId ? @"user_reply" : @"user_input";
        NSMutableDictionary *content = [@{
            @"user_input" : userInput ?: @"",
            @"thread_id" : strongSelf.threadId
        } mutableCopy];
        if (replyId) {
            content[@"reply_id"] = replyId;
        }
        [sub push:event
                data:content
             options:nil
          completion:^(NSError *_Nullable pushErr) {
            if (pushErr) {
                completion(nil, pushErr);
            } else {
                completion(run, nil);
            }
          }];
      }];
    }];
}

#pragma mark - Internal (Run)

- (void)fireRequestFeedback:(HumanInputRequest *)req run:(Run *)run {
    NSArray<AgentHumanInputHandler> *handlers;
    [self.lock lock];
    handlers = [self.feedbackHandlers copy];
    [self.lock unlock];
    for (AgentHumanInputHandler h in handlers) {
        h(req, run);
    }
}

- (void)closeRun:(Run *)run {
    if (self.activeRun == run) {
        self.activeRun = nil;
    }
}

- (void)sendReply:(id)value
          replyId:(NSString *)replyId
       completion:(nullable void (^)(NSString *_Nullable,
                                     NSError *_Nullable))completion {
    __weak typeof(self) weakSelf = self;
    [self.agent getSubscription:^(Subscription *_Nullable sub,
                                  NSError *_Nullable error) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (error || !sub || !strongSelf) {
          if (completion) completion(nil, error);
          return;
      }
      NSMutableDictionary *content = [@{
          @"user_input" : value ?: @"",
          @"thread_id" : strongSelf.threadId,
          @"reply_id" : replyId
      } mutableCopy];
      [sub push:@"user_reply"
              data:content
           options:nil
        completion:^(NSError *_Nullable pushErr) {
          if (completion) completion(@"", pushErr);
        }];
    }];
}

@end
