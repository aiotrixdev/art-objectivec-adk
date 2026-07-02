//
//  Run.m
//  ADK
//

#import "Run.h"
#import "AgentThread.h"
#import "AgentEvents.h"

@interface Run ()
@property(nonatomic, weak) AgentThread *thread;
@property(nonatomic, copy, readwrite) NSString *refId;
@property(nonatomic, assign, readwrite, getter=isClosed) BOOL closed;
@property(nonatomic, copy, nullable) RunDoneHandler doneHandler;
@property(nonatomic, strong, nullable) AgentOutput *settledOutput;
@property(nonatomic, strong, nullable) AgentError *settledError;
@property(nonatomic, assign) BOOL settled;
@property(nonatomic, copy, nullable) NSString *latestHumanInputRef;
@property(nonatomic, strong, nullable) dispatch_block_t humanInputTimer;
@end

@implementation Run

- (instancetype)initWithThread:(AgentThread *)thread {
    self = [super init];
    if (self) {
        _thread = thread;
        _refId = @"";
    }
    return self;
}

- (void)setRefId:(NSString *)refId {
    _refId = [refId copy];
}

- (void)done:(RunDoneHandler)handler {
    if (self.settled) {
        handler(self.settledOutput, self.settledError);
        return;
    }
    self.doneHandler = handler;
}

- (void)settleOutput:(nullable AgentOutput *)output
               error:(nullable AgentError *)error {
    if (self.settled) {
        return;
    }
    self.settled = YES;
    self.settledOutput = output;
    self.settledError = error;
    RunDoneHandler h = self.doneHandler;
    self.doneHandler = nil;
    if (h) {
        h(output, error);
    }
}

- (void)pushEnvelope:(AgentEventEnvelope *)envelope {
    if (self.closed) {
        return;
    }
    switch (envelope.kind) {
        case AgentEventKindHumanInput: {
            HumanInputRequest *content = envelope.asHumanInput;
            self.latestHumanInputRef =
                content.refId.length
                    ? content.refId
                    : (content.replyTo.length ? content.replyTo : nil);
            [self clearHumanInputTimer];
            double timeoutSec = content.timeout ? content.timeout.doubleValue : 0;
            if (timeoutSec > 0) {
                __weak typeof(self) weakSelf = self;
                HumanInputRequest *captured = content;
                dispatch_block_t block = dispatch_block_create(0, ^{
                  __strong typeof(weakSelf) strongSelf = weakSelf;
                  if (!strongSelf || strongSelf.closed) {
                      return;
                  }
                  AgentError *err = [[AgentError alloc]
                      initWithCode:@"HUMAN_INPUT_TIMEOUT"
                           message:[NSString
                                       stringWithFormat:
                                           @"No response received within %.0fs "
                                           @"for human_input_request.",
                                           timeoutSec]
                           details:nil
                          threadId:captured.threadId
                             refId:@""
                           agentId:captured.agentId
                           replyTo:strongSelf.latestHumanInputRef ?: @""];
                  strongSelf.closed = YES;
                  [strongSelf settleOutput:nil error:err];
                  [strongSelf.thread closeRun:strongSelf];
                });
                self.humanInputTimer = block;
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(timeoutSec * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), block);
            }
            [self.thread fireRequestFeedback:content run:self];
            break;
        }
        case AgentEventKindOutput: {
            [self clearHumanInputTimer];
            self.closed = YES;
            [self settleOutput:envelope.asOutput error:nil];
            [self.thread closeRun:self];
            break;
        }
        case AgentEventKindError: {
            [self clearHumanInputTimer];
            self.closed = YES;
            [self settleOutput:nil error:envelope.asError];
            [self.thread closeRun:self];
            break;
        }
        default:
            // wait / plannerCorrection / unknown — non-terminal.
            break;
    }
}

- (void)sendFeedback:(id)value
          completion:(nullable void (^)(NSError *_Nullable))completion {
    NSString *replyId = self.latestHumanInputRef;
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
    // Consume before sending so a reentrant handler can't double-respond.
    self.latestHumanInputRef = nil;
    [self clearHumanInputTimer];
    [self.thread sendReply:value
                   replyId:replyId
                completion:^(NSString *_Nullable refId, NSError *_Nullable err) {
                  if (completion) {
                      completion(err);
                  }
                }];
}

- (void)close:(NSString *)reason {
    if (self.closed) {
        return;
    }
    [self clearHumanInputTimer];
    self.closed = YES;
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
    if (self.humanInputTimer) {
        dispatch_block_cancel(self.humanInputTimer);
        self.humanInputTimer = nil;
    }
}

@end
