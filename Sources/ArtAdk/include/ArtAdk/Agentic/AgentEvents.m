//
//  AgentEvents.m
//  ADK
//

#import "AgentEvents.h"
#import "ARTSupport.h"

#pragma mark - Coercion helpers

static NSString *ARTStr(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : @"";
}

static NSString *_Nullable ARTOptStr(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

static NSDictionary *_Nullable ARTDict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

static NSNumber *_Nullable ARTNum(id value) {
    return [value isKindOfClass:[NSNumber class]] ? (NSNumber *)value : nil;
}

NSArray<NSString *> *ARTAgentEventTypes(void) {
    static NSArray<NSString *> *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      types = @[
          @"agent_general_response", @"agent_error_response",
          @"human_input_request", @"agent_wait_response",
          @"planner_correction_request", @"thread_state"
      ];
    });
    return types;
}

BOOL ARTIsKnownAgentEvent(NSString *name) {
    return [ARTAgentEventTypes() containsObject:name ?: @""];
}

#pragma mark - AgentOutput

@implementation AgentOutput
- (instancetype)initWithMap:(NSDictionary *)m {
    self = [super init];
    if (self) {
        _message = [ARTStr(m[@"message"]) copy];
        _data = ARTDict(m[@"data"]);
        _metadata = ARTDict(m[@"metadata"]);
        _threadId = [ARTStr(m[@"thread_id"]) copy];
        _refId = [ARTStr(m[@"ref_id"]) copy];
        _agentId = [ARTStr(m[@"agent_id"]) copy];
        _replyTo = [ARTStr(m[@"reply_to"]) copy];
    }
    return self;
}
@end

#pragma mark - AgentError

@implementation AgentError
- (instancetype)initWithMap:(NSDictionary *)m {
    self = [super init];
    if (self) {
        _code = [ARTStr(m[@"code"]) copy];
        _message = [ARTStr(m[@"message"]) copy];
        _details = ARTDict(m[@"details"]);
        _threadId = [ARTStr(m[@"thread_id"]) copy];
        _refId = [ARTStr(m[@"ref_id"]) copy];
        _agentId = [ARTStr(m[@"agent_id"]) copy];
        _replyTo = [ARTStr(m[@"reply_to"]) copy];
    }
    return self;
}

- (instancetype)initWithCode:(NSString *)code
                     message:(NSString *)message
                     details:(NSDictionary *)details
                    threadId:(NSString *)threadId
                       refId:(NSString *)refId
                     agentId:(NSString *)agentId
                     replyTo:(NSString *)replyTo {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    map[@"code"] = code ?: @"";
    map[@"message"] = message ?: @"";
    map[@"thread_id"] = threadId ?: @"";
    map[@"ref_id"] = refId ?: @"";
    map[@"agent_id"] = agentId ?: @"";
    map[@"reply_to"] = replyTo ?: @"";
    if (details) {
        map[@"details"] = details;
    }
    return [self initWithMap:map];
}
@end

#pragma mark - HumanInputRequest

@implementation HumanInputRequest
- (instancetype)initWithMap:(NSDictionary *)m {
    self = [super init];
    if (self) {
        NSString *raw = ARTStr(m[@"expected_response_type"]);
        _prompt = [ARTStr(m[@"prompt"]) copy];
        _context = ARTDict(m[@"context"]);
        _expectedResponseType = [(raw.length ? raw : @"text") copy];
        _timeout = ARTNum(m[@"timeout"]);
        _schema = m[@"schema"];
        _threadId = [ARTStr(m[@"thread_id"]) copy];
        _refId = [ARTStr(m[@"ref_id"]) copy];
        _agentId = [ARTStr(m[@"agent_id"]) copy];
        _replyTo = [ARTStr(m[@"reply_to"]) copy];
    }
    return self;
}
@end

#pragma mark - AgentWait

@implementation AgentWait
- (instancetype)initWithMap:(NSDictionary *)m {
    self = [super init];
    if (self) {
        _waitingForAgentId = [ARTStr(m[@"waiting_for_agent_id"]) copy];
        _invocationId = [ARTOptStr(m[@"invocation_id"]) copy];
        _reason = [ARTOptStr(m[@"reason"]) copy];
        _timeout = ARTNum(m[@"timeout"]);
        _progress = ARTDict(m[@"progress"]);
        _threadId = [ARTStr(m[@"thread_id"]) copy];
        _refId = [ARTStr(m[@"ref_id"]) copy];
        _agentId = [ARTStr(m[@"agent_id"]) copy];
        _replyTo = [ARTStr(m[@"reply_to"]) copy];
    }
    return self;
}
@end

#pragma mark - PlannerCorrection

@implementation PlannerCorrection
- (instancetype)initWithMap:(NSDictionary *)m {
    self = [super init];
    if (self) {
        _correctionRequired = [ARTNum(m[@"correction_required"]) boolValue];
        _reason = [ARTStr(m[@"reason"]) copy];
        _proposedGoal = [ARTOptStr(m[@"new_goal"]) copy];
        id agents = m[@"suggested_agents"];
        if ([agents isKindOfClass:[NSArray class]]) {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (id agent in (NSArray *)agents) {
                [names addObject:[agent description]];
            }
            _suggestedAgents = [names copy];
        }
        _threadId = [ARTStr(m[@"thread_id"]) copy];
        _refId = [ARTStr(m[@"ref_id"]) copy];
        _agentId = [ARTStr(m[@"agent_id"]) copy];
        _replyTo = [ARTStr(m[@"reply_to"]) copy];
    }
    return self;
}
@end

#pragma mark - ARTThreadState

ARTThreadStatePhase const ARTThreadStatePhaseIdle = @"idle";
ARTThreadStatePhase const ARTThreadStatePhaseSubmitted = @"submitted";
ARTThreadStatePhase const ARTThreadStatePhaseQueued = @"queued";
ARTThreadStatePhase const ARTThreadStatePhaseRunning = @"running";
ARTThreadStatePhase const ARTThreadStatePhaseWaitingForAgent = @"waiting_for_agent";
ARTThreadStatePhase const ARTThreadStatePhaseWaitingForApproval =
    @"waiting_for_approval";
ARTThreadStatePhase const ARTThreadStatePhaseWaitingForWorkspace =
    @"waiting_for_workspace";
ARTThreadStatePhase const ARTThreadStatePhaseCompleted = @"completed";
ARTThreadStatePhase const ARTThreadStatePhaseFailed = @"failed";
ARTThreadStatePhase const ARTThreadStatePhaseCancelled = @"cancelled";

ARTThreadStateSource const ARTThreadStateSourceClient = @"client";
ARTThreadStateSource const ARTThreadStateSourcePoolManager = @"pool_manager";
ARTThreadStateSource const ARTThreadStateSourceAgent = @"agent";
ARTThreadStateSource const ARTThreadStateSourceOrchestrator = @"orchestrator";
ARTThreadStateSource const ARTThreadStateSourceWorkspace = @"workspace";

@implementation ARTThreadState

- (instancetype)initWithMap:(NSDictionary *)m {
    NSString *phase = ARTOptStr(m[@"phase"]);
    NSString *source = ARTOptStr(m[@"source"]);
    return [self initWithThreadId:ARTStr(m[@"thread_id"])
                            phase:phase ?: ARTThreadStatePhaseIdle
                           source:source ?: ARTThreadStateSourceClient
                          message:ARTStr(m[@"message"])
                           reason:ARTOptStr(m[@"reason"])
                           nodeId:ARTOptStr(m[@"node_id"])
                         nodeName:ARTOptStr(m[@"node_name"])
                           taskId:ARTOptStr(m[@"task_id"])
                      workspaceId:ARTOptStr(m[@"workspace_id"])
                          agentId:ARTOptStr(m[@"agent_id"])
                    queuePosition:[ARTJSON integerValue:m[@"queue_position"]]
                       occurredAt:ARTStr(m[@"occurred_at"])
                         sequence:[ARTJSON integerValue:m[@"sequence"]]
                          details:ARTDict(m[@"details"])];
}

- (instancetype)initWithThreadId:(NSString *)threadId
                           phase:(ARTThreadStatePhase)phase
                          source:(ARTThreadStateSource)source
                         message:(NSString *)message
                          reason:(NSString *)reason
                          nodeId:(NSString *)nodeId
                        nodeName:(NSString *)nodeName
                          taskId:(NSString *)taskId
                     workspaceId:(NSString *)workspaceId
                         agentId:(NSString *)agentId
                   queuePosition:(NSNumber *)queuePosition
                      occurredAt:(NSString *)occurredAt
                        sequence:(NSNumber *)sequence
                         details:(NSDictionary *)details {
    self = [super init];
    if (self) {
        _threadId = [threadId copy] ?: @"";
        _phase = [phase copy] ?: ARTThreadStatePhaseIdle;
        _source = [source copy] ?: ARTThreadStateSourceClient;
        _message = [message copy] ?: @"";
        _reason = [reason copy];
        _nodeId = [nodeId copy];
        _nodeName = [nodeName copy];
        _taskId = [taskId copy];
        _workspaceId = [workspaceId copy];
        _agentId = [agentId copy];
        _queuePosition = queuePosition;
        _occurredAt = [occurredAt copy] ?: @"";
        _sequence = sequence;
        _details = [details copy];
    }
    return self;
}

- (instancetype)stateWithThreadId:(NSString *)threadId sequence:(NSNumber *)sequence {
    return [[ARTThreadState alloc] initWithThreadId:threadId
                                              phase:self.phase
                                             source:self.source
                                            message:self.message
                                             reason:self.reason
                                             nodeId:self.nodeId
                                           nodeName:self.nodeName
                                             taskId:self.taskId
                                        workspaceId:self.workspaceId
                                            agentId:self.agentId
                                      queuePosition:self.queuePosition
                                         occurredAt:self.occurredAt
                                           sequence:sequence
                                            details:self.details];
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<ARTThreadState %@ %@ (%@) \"%@\"%@>",
                                      self.threadId, self.phase, self.source,
                                      self.message,
                                      self.sequence
                                          ? [NSString stringWithFormat:@" #%@",
                                                                       self.sequence]
                                          : @""];
}

@end

#pragma mark - UnknownAgentEvent

@implementation UnknownAgentEvent
- (instancetype)initWithEvent:(NSString *)event content:(NSDictionary *)content {
    self = [super init];
    if (self) {
        _event = [event copy];
        _content = content ?: @{};
    }
    return self;
}
@end

#pragma mark - AgentEventEnvelope

@implementation AgentEventEnvelope

- (instancetype)initWithEvent:(NSString *)event
                         kind:(AgentEventKind)kind
                      payload:(id)payload
                      content:(NSDictionary<NSString *, id> *)content {
    self = [super init];
    if (self) {
        _event = [event copy];
        _kind = kind;
        _payload = payload;
        _content = [content copy] ?: @{};
    }
    return self;
}

- (instancetype)initWithEvent:(NSString *)event
                         kind:(AgentEventKind)kind
                      payload:(id)payload {
    return [self initWithEvent:event kind:kind payload:payload content:nil];
}

- (BOOL)isKnown {
    return ARTIsKnownAgentEvent(self.event);
}

- (nullable AgentOutput *)asOutput {
    return [_payload isKindOfClass:[AgentOutput class]] ? _payload : nil;
}
- (nullable AgentError *)asError {
    return [_payload isKindOfClass:[AgentError class]] ? _payload : nil;
}
- (nullable HumanInputRequest *)asHumanInput {
    return [_payload isKindOfClass:[HumanInputRequest class]] ? _payload : nil;
}
- (nullable AgentWait *)asWait {
    return [_payload isKindOfClass:[AgentWait class]] ? _payload : nil;
}
- (nullable PlannerCorrection *)asPlannerCorrection {
    return [_payload isKindOfClass:[PlannerCorrection class]] ? _payload : nil;
}
- (nullable ARTThreadState *)asThreadState {
    return [_payload isKindOfClass:[ARTThreadState class]] ? _payload : nil;
}
- (nullable UnknownAgentEvent *)asUnknown {
    return [_payload isKindOfClass:[UnknownAgentEvent class]] ? _payload : nil;
}

/// `value` as a field map: an object as it is, or an object encoded as JSON
/// text. The agent backend double-encodes some event bodies (for example
/// `agent_output` and `agent_error`), so the text form is decoded before
/// any field is read.
+ (nullable NSDictionary *)contentMap:(id)value {
    if ([value isKindOfClass:[NSDictionary class]]) {
        return (NSDictionary *)value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        id parsed = [ARTJSON parse:(NSString *)value];
        return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
    }
    return nil;
}

/// The variant map may sit at the top level (`raw["type"]`) or be nested
/// one level deeper (`raw["content"]["type"]`).
+ (NSDictionary *)resolveContent:(NSDictionary *)raw {
    if ([raw[@"type"] isKindOfClass:[NSString class]]) {
        return raw;
    }
    NSDictionary *nested = [self contentMap:raw[@"content"]];
    if (nested && [nested[@"type"] isKindOfClass:[NSString class]]) {
        return nested;
    }
    return raw;
}

+ (instancetype)parse:(NSDictionary *)raw {
    NSString *wireEvent = ARTStr(raw[@"event"]);
    NSDictionary *outerContent = [self contentMap:raw[@"content"]] ?: raw;
    NSDictionary *contentMap = [self resolveContent:outerContent];

    NSString *rawType = ARTStr(contentMap[@"type"]);
    NSString *type = rawType.length ? rawType : wireEvent;

    if ([type isEqualToString:@"agent_general_response"] ||
        [type isEqualToString:@"agent_output"]) {
        return [[self alloc]
            initWithEvent:@"agent_general_response"
                     kind:AgentEventKindOutput
                  payload:[[AgentOutput alloc] initWithMap:contentMap]
                  content:contentMap];
    }
    if ([type isEqualToString:@"agent_error_response"] ||
        [type isEqualToString:@"agent_error"]) {
        return [[self alloc]
            initWithEvent:@"agent_error_response"
                     kind:AgentEventKindError
                  payload:[[AgentError alloc] initWithMap:contentMap]
                  content:contentMap];
    }
    if ([type isEqualToString:@"human_input_request"]) {
        return [[self alloc]
            initWithEvent:@"human_input_request"
                     kind:AgentEventKindHumanInput
                  payload:[[HumanInputRequest alloc] initWithMap:contentMap]
                  content:contentMap];
    }
    if ([type isEqualToString:@"agent_wait_response"] ||
        [type isEqualToString:@"agent_wait"]) {
        return [[self alloc]
            initWithEvent:@"agent_wait_response"
                     kind:AgentEventKindWait
                  payload:[[AgentWait alloc] initWithMap:contentMap]
                  content:contentMap];
    }
    if ([type isEqualToString:@"planner_correction_request"] ||
        [type isEqualToString:@"planner_correction"]) {
        return [[self alloc]
            initWithEvent:@"planner_correction_request"
                     kind:AgentEventKindPlannerCorrection
                  payload:[[PlannerCorrection alloc] initWithMap:contentMap]
                  content:contentMap];
    }
    if ([type isEqualToString:@"thread_state"]) {
        return [[self alloc]
            initWithEvent:@"thread_state"
                     kind:AgentEventKindThreadState
                  payload:[[ARTThreadState alloc] initWithMap:contentMap]
                  content:contentMap];
    }
    return [[self alloc]
        initWithEvent:wireEvent
                 kind:AgentEventKindUnknown
              payload:[[UnknownAgentEvent alloc] initWithEvent:wireEvent
                                                       content:contentMap]
              content:contentMap];
}

@end
