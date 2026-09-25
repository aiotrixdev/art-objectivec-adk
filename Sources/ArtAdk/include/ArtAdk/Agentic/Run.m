//
//  Run.m
//  ADK
//

#import "Run.h"
#import "AgentEvents.h"
#import "AgentThread.h"

@interface Run ()
@property(nonatomic, weak) AgentThread *thread;
@property(nonatomic, copy, readwrite) NSString *refId;
@property(nonatomic, assign, readwrite, getter=isClosed) BOOL closed;
@property(nonatomic, strong) NSMutableArray<RunDoneHandler> *doneHandlers;
@property(nonatomic, strong, nullable) AgentOutput *settledOutput;
@property(nonatomic, strong, nullable) AgentError *settledError;
@property(nonatomic, assign) BOOL settled;
@property(nonatomic, copy, nullable) NSString *latestHumanInputRef;
@property(nonatomic, strong, nullable) dispatch_block_t humanInputTimer;
@end

@implementation Run

@synthesize refId = _refId;

- (instancetype)initWithThread:(AgentThread *)thread {
    self = [super init];
    if (self) {
        _thread = thread;
        _refId = @"";
        _doneHandlers = [NSMutableArray array];
    }
    return self;
}

- (NSString *)refId {
    @synchronized(self) {
        return _refId;
    }
}

- (void)setRefId:(NSString *)refId {
    @synchronized(self) {
        _refId = [refId copy] ?: @"";
    }
}

- (BOOL)isClosed {
    @synchronized(self) {
        return _closed;
    }
}

- (void)done:(RunDoneHandler)handler {
    AgentOutput *output = nil;
    AgentError *error = nil;
    @synchronized(self) {
        if (!self.settled) {
            [self.doneHandlers addObject:[handler copy]];
            return;
        }
        output = self.settledOutput;
        error = self.settledError;
    }
    handler(output, error);
}

- (void)settleOutput:(nullable AgentOutput *)output
               error:(nullable AgentError *)error {
    NSArray<RunDoneHandler> *handlers;
    @synchronized(self) {
        if (self.settled) {
            return;
        }
        self.settled = YES;
        self.settledOutput = output;
        self.settledError = error;
        handlers = [self.doneHandlers copy];
        [self.doneHandlers removeAllObjects];
    }
    for (RunDoneHandler handler in handlers) {
        handler(output, error);
    }
}

/// Marks the run closed and cancels the HITL timer. Returns NO when it was
/// already closed.
- (BOOL)markClosed {
    dispatch_block_t timer;
    @synchronized(self) {
        if (_closed) {
            return NO;
        }
        _closed = YES;
        timer = self.humanInputTimer;
        self.humanInputTimer = nil;
    }
    if (timer) {
        dispatch_block_cancel(timer);
    }
    return YES;
}

- (void)pushEnvelope:(AgentEventEnvelope *)envelope {
    if (self.isClosed) {
        return;
    }
    switch (envelope.kind) {
    case AgentEventKindHumanInput: {
        HumanInputRequest *content = envelope.asHumanInput;
        // Prefer the message's own ref_id; fall back to its reply_to.
        NSString *pendingRef =
            content.refId.length
                ? content.refId
                : (content.replyTo.length ? content.replyTo : nil);
        [self clearHumanInputTimer];
        @synchronized(self) {
            self.latestHumanInputRef = pendingRef;
        }
        double timeoutSec = content.timeout ? content.timeout.doubleValue : 0;
        if (timeoutSec > 0) {
            __weak typeof(self) weakSelf = self;
            HumanInputRequest *captured = content;
            dispatch_block_t block = dispatch_block_create(0, ^{
              __strong typeof(weakSelf) strongSelf = weakSelf;
              if (!strongSelf) {
                  return;
              }
              NSString *replyTo;
              @synchronized(strongSelf) {
                  if (strongSelf->_closed) {
                      return;
                  }
                  strongSelf->_closed = YES;
                  strongSelf.humanInputTimer = nil;
                  replyTo = strongSelf.latestHumanInputRef ?: @"";
              }
              AgentError *err = [[AgentError alloc]
                  initWithCode:@"HUMAN_INPUT_TIMEOUT"
                       message:[NSString
                                   stringWithFormat:
                                       @"No response received within %gs for "
                                       @"human_input_request.",
                                       timeoutSec]
                       details:@{
                           @"prompt" : captured.prompt ?: @"",
                           @"timeout" : @(timeoutSec)
                       }
                      threadId:captured.threadId
                         refId:@""
                       agentId:captured.agentId
                       replyTo:replyTo];
              [strongSelf settleOutput:nil error:err];
              [strongSelf.thread closeRun:strongSelf];
            });
            @synchronized(self) {
                self.humanInputTimer = block;
            }
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(timeoutSec * NSEC_PER_SEC)),
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                block);
        }
        [self.thread fireRequestFeedback:content run:self];
        break;
    }
    case AgentEventKindOutput: {
        if (![self markClosed]) {
            return;
        }
        [self settleOutput:envelope.asOutput error:nil];
        [self.thread closeRun:self];
        break;
    }
    case AgentEventKindError: {
        if (![self markClosed]) {
            return;
        }
        [self settleOutput:nil error:envelope.asError];
        [self.thread closeRun:self];
        break;
    }
    default:
        // wait / plannerCorrection / threadState / unknown — non-terminal.
        break;
    }
}

- (void)sendFeedback:(id)value
          completion:(nullable void (^)(NSError *_Nullable))completion {
    // Consume the pending input before sending, so a reentrant handler
    // can't respond twice.
    NSString *replyId;
    @synchronized(self) {
        replyId = self.latestHumanInputRef;
        self.latestHumanInputRef = nil;
    }
    if (!replyId) {
        if (completion) {
            completion([NSError
                errorWithDomain:@"ADK.Run"
                           code:-1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"No pending human_input_request to respond to."
                       }]);
        }
        return;
    }
    [self clearHumanInputTimer];
    AgentThread *thread = self.thread;
    if (!thread) {
        if (completion) {
            completion([NSError errorWithDomain:@"ADK.Run"
                                           code:-1
                                       userInfo:@{
                                           NSLocalizedDescriptionKey :
                                               @"The run's thread was released."
                                       }]);
        }
        return;
    }
    [thread sendReply:value
              replyId:replyId
           completion:^(NSString *_Nullable refId, NSError *_Nullable err) {
             if (completion) {
                 completion(err);
             }
           }];
}

- (void)close:(NSString *)reason {
    if (![self markClosed]) {
        return;
    }
    AgentError *err = [[AgentError alloc]
        initWithCode:@"RUN_SUPERSEDED"
             message:reason ?: @"Run closed before terminal event"
             details:nil
            threadId:@""
               refId:@""
             agentId:@""
             replyTo:@""];
    [self settleOutput:nil error:err];
}

- (void)clearHumanInputTimer {
    dispatch_block_t timer;
    @synchronized(self) {
        timer = self.humanInputTimer;
        self.humanInputTimer = nil;
    }
    if (timer) {
        dispatch_block_cancel(timer);
    }
}

@end
