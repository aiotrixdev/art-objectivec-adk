//
//  AgentEvents.m
//  ADK
//

#import "AgentEvents.h"

#pragma mark - Coercion helpers

static NSString *ARTStr(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : @"";
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
            @"planner_correction_request"
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
    self = [super init];
    if (self) {
        _code = [code copy];
        _message = [message copy];
        _details = details;
        _threadId = [threadId copy];
        _refId = [refId copy];
        _agentId = [agentId copy];
        _replyTo = [replyTo copy];
    }
    return self;
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
        _reason = [m[@"reason"] isKindOfClass:[NSString class]]
                      ? [(NSString *)m[@"reason"] copy]
                      : nil;
        _timeout = ARTNum(m[@"timeout"]);
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
        _proposedGoal = [m[@"new_goal"] isKindOfClass:[NSString class]]
                            ? [(NSString *)m[@"new_goal"] copy]
                            : nil;
        _threadId = [ARTStr(m[@"thread_id"]) copy];
        _refId = [ARTStr(m[@"ref_id"]) copy];
        _agentId = [ARTStr(m[@"agent_id"]) copy];
        _replyTo = [ARTStr(m[@"reply_to"]) copy];
    }
    return self;
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
                      payload:(id)payload {
    self = [super init];
    if (self) {
        _event = [event copy];
        _kind = kind;
        _payload = payload;
    }
    return self;
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
- (nullable UnknownAgentEvent *)asUnknown {
    return [_payload isKindOfClass:[UnknownAgentEvent class]] ? _payload : nil;
}

/// The variant map may sit at the top level (`raw["type"]`) or be nested one
/// level deeper (`raw["content"]["type"]`). Mirrors Swift `resolveAgentContent`.
+ (NSDictionary *)resolveContent:(NSDictionary *)raw {
    if ([raw[@"type"] isKindOfClass:[NSString class]]) {
        return raw;
    }
    NSDictionary *nested = ARTDict(raw[@"content"]);
    if (nested && [nested[@"type"] isKindOfClass:[NSString class]]) {
        return nested;
    }
    return raw;
}

+ (instancetype)parse:(NSDictionary *)raw {
    NSString *wireEvent = ARTStr(raw[@"event"]);
    NSDictionary *outerContent = ARTDict(raw[@"content"]) ?: raw;
    NSDictionary *contentMap = [self resolveContent:outerContent];

    NSString *rawType = ARTStr(contentMap[@"type"]);
    NSString *type = rawType.length ? rawType : wireEvent;

    if ([type isEqualToString:@"agent_general_response"] ||
        [type isEqualToString:@"agent_output"]) {
        return [[self alloc] initWithEvent:@"agent_general_response"
                                      kind:AgentEventKindOutput
                                   payload:[[AgentOutput alloc]
                                               initWithMap:contentMap]];
    }
    if ([type isEqualToString:@"agent_error_response"] ||
        [type isEqualToString:@"agent_error"]) {
        return [[self alloc] initWithEvent:@"agent_error_response"
                                      kind:AgentEventKindError
                                   payload:[[AgentError alloc]
                                               initWithMap:contentMap]];
    }
    if ([type isEqualToString:@"human_input_request"]) {
        return [[self alloc] initWithEvent:@"human_input_request"
                                      kind:AgentEventKindHumanInput
                                   payload:[[HumanInputRequest alloc]
                                               initWithMap:contentMap]];
    }
    if ([type isEqualToString:@"agent_wait_response"] ||
        [type isEqualToString:@"agent_wait"]) {
        return [[self alloc] initWithEvent:@"agent_wait_response"
                                      kind:AgentEventKindWait
                                   payload:[[AgentWait alloc]
                                               initWithMap:contentMap]];
    }
    if ([type isEqualToString:@"planner_correction_request"] ||
        [type isEqualToString:@"planner_correction"]) {
        return [[self alloc] initWithEvent:@"planner_correction_request"
                                      kind:AgentEventKindPlannerCorrection
                                   payload:[[PlannerCorrection alloc]
                                               initWithMap:contentMap]];
    }
    return [[self alloc]
        initWithEvent:wireEvent
                 kind:AgentEventKindUnknown
              payload:[[UnknownAgentEvent alloc] initWithEvent:wireEvent
                                                       content:contentMap]];
}

@end
