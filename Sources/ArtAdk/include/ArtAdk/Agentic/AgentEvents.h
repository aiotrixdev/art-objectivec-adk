#ifndef ARTADK_AGENTIC_AGENTEVENTS_H
#define ARTADK_AGENTIC_AGENTEVENTS_H

#pragma once

//
//  AgentEvents.h
//  ADK
//
//  Typed event envelopes emitted on the `agent_com_<agentId>` channel.
//  The wire shape is `{ event, content }`; the canonical discriminator is
//  `content.type` (the top-level `event` is `user_input` for every agent
//  reply).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The known event types emitted on agent communication channels.
FOUNDATION_EXPORT NSArray<NSString *> *_Nonnull ARTAgentEventTypes(void);
/// Returns YES if `name` is a recognised agent event type.
FOUNDATION_EXPORT BOOL ARTIsKnownAgentEvent(NSString *name);

#pragma mark - Typed payloads

/// Successful terminal response from an agent run.
@interface AgentOutput : NSObject
@property(nonatomic, copy, readonly) NSString *message;
@property(nonatomic, strong, readonly, nullable) NSDictionary *data;
@property(nonatomic, strong, readonly, nullable) NSDictionary *metadata;
@property(nonatomic, copy, readonly) NSString *threadId;
@property(nonatomic, copy, readonly) NSString *refId;
@property(nonatomic, copy, readonly) NSString *agentId;
@property(nonatomic, copy, readonly) NSString *replyTo;
- (instancetype)initWithMap:(NSDictionary *)m NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Error response from an agent run; terminal for the originating Run.
@interface AgentError : NSObject
@property(nonatomic, copy, readonly) NSString *code;
@property(nonatomic, copy, readonly) NSString *message;
@property(nonatomic, strong, readonly, nullable) NSDictionary *details;
@property(nonatomic, copy, readonly) NSString *threadId;
@property(nonatomic, copy, readonly) NSString *refId;
@property(nonatomic, copy, readonly) NSString *agentId;
@property(nonatomic, copy, readonly) NSString *replyTo;
- (instancetype)initWithMap:(NSDictionary *)m NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithCode:(NSString *)code
                     message:(NSString *)message
                     details:(nullable NSDictionary *)details
                    threadId:(NSString *)threadId
                       refId:(NSString *)refId
                     agentId:(NSString *)agentId
                     replyTo:(NSString *)replyTo;
- (instancetype)init NS_UNAVAILABLE;
@end

/// An interactive prompt the agent is awaiting a human reply on.
@interface HumanInputRequest : NSObject
@property(nonatomic, copy, readonly) NSString *prompt;
@property(nonatomic, strong, readonly, nullable) NSDictionary *context;
/// Raw `expected_response_type` string (falls back to `text`).
@property(nonatomic, copy, readonly) NSString *expectedResponseType;
/// Optional client-side timeout in seconds.
@property(nonatomic, strong, readonly, nullable) NSNumber *timeout;
@property(nonatomic, strong, readonly, nullable) id schema;
@property(nonatomic, copy, readonly) NSString *threadId;
@property(nonatomic, copy, readonly) NSString *refId;
@property(nonatomic, copy, readonly) NSString *agentId;
@property(nonatomic, copy, readonly) NSString *replyTo;
- (instancetype)initWithMap:(NSDictionary *)m NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Notification that the agent is awaiting another agent's response.
@interface AgentWait : NSObject
@property(nonatomic, copy, readonly) NSString *waitingForAgentId;
/// Optional invocation id of the downstream agent call.
@property(nonatomic, copy, readonly, nullable) NSString *invocationId;
@property(nonatomic, copy, readonly, nullable) NSString *reason;
@property(nonatomic, strong, readonly, nullable) NSNumber *timeout;
/// Optional progress details (`workspace_id` when waiting for a workspace).
@property(nonatomic, strong, readonly, nullable) NSDictionary *progress;
@property(nonatomic, copy, readonly) NSString *threadId;
@property(nonatomic, copy, readonly) NSString *refId;
@property(nonatomic, copy, readonly) NSString *agentId;
@property(nonatomic, copy, readonly) NSString *replyTo;
- (instancetype)initWithMap:(NSDictionary *)m NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Server-initiated request that the planner correct its course of action.
@interface PlannerCorrection : NSObject
@property(nonatomic, assign, readonly) BOOL correctionRequired;
@property(nonatomic, copy, readonly) NSString *reason;
/// The server's proposed new goal (wire `new_goal`). Not named `newGoal` to
/// avoid the ARC `new`-family owned-return convention.
@property(nonatomic, copy, readonly, nullable) NSString *proposedGoal;
/// Optional agent ids suggested for the corrected plan.
@property(nonatomic, copy, readonly, nullable) NSArray<NSString *> *suggestedAgents;
@property(nonatomic, copy, readonly) NSString *threadId;
@property(nonatomic, copy, readonly) NSString *refId;
@property(nonatomic, copy, readonly) NSString *agentId;
@property(nonatomic, copy, readonly) NSString *replyTo;
- (instancetype)initWithMap:(NSDictionary *)m NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

#pragma mark - Thread state

/// Operational phase of a thread. Phases the SDK doesn't know yet are kept
/// as their raw server value.
typedef NSString *ARTThreadStatePhase NS_TYPED_EXTENSIBLE_ENUM;
FOUNDATION_EXPORT ARTThreadStatePhase const ARTThreadStatePhaseIdle;
FOUNDATION_EXPORT ARTThreadStatePhase const ARTThreadStatePhaseSubmitted;
FOUNDATION_EXPORT ARTThreadStatePhase const ARTThreadStatePhaseQueued;
FOUNDATION_EXPORT ARTThreadStatePhase const ARTThreadStatePhaseRunning;
FOUNDATION_EXPORT ARTThreadStatePhase const ARTThreadStatePhaseWaitingForAgent;
FOUNDATION_EXPORT ARTThreadStatePhase const ARTThreadStatePhaseWaitingForApproval;
FOUNDATION_EXPORT ARTThreadStatePhase const ARTThreadStatePhaseWaitingForWorkspace;
FOUNDATION_EXPORT ARTThreadStatePhase const ARTThreadStatePhaseCompleted;
FOUNDATION_EXPORT ARTThreadStatePhase const ARTThreadStatePhaseFailed;
FOUNDATION_EXPORT ARTThreadStatePhase const ARTThreadStatePhaseCancelled;

/// Which component reported a thread state.
typedef NSString *ARTThreadStateSource NS_TYPED_EXTENSIBLE_ENUM;
FOUNDATION_EXPORT ARTThreadStateSource const ARTThreadStateSourceClient;
FOUNDATION_EXPORT ARTThreadStateSource const ARTThreadStateSourcePoolManager;
FOUNDATION_EXPORT ARTThreadStateSource const ARTThreadStateSourceAgent;
FOUNDATION_EXPORT ARTThreadStateSource const ARTThreadStateSourceOrchestrator;
FOUNDATION_EXPORT ARTThreadStateSource const ARTThreadStateSourceWorkspace;

/// Current operational state of one thread, for showing progress in a UI.
/// Delivered by `-[AgentThread listenState:emitCurrent:]`,
/// `-[OrchestratorThread listenState:emitCurrent:]` and `thread_state`
/// events.
@interface ARTThreadState : NSObject <NSCopying>
@property(nonatomic, copy, readonly) NSString *threadId;
@property(nonatomic, copy, readonly) ARTThreadStatePhase phase;
@property(nonatomic, copy, readonly) ARTThreadStateSource source;
@property(nonatomic, copy, readonly) NSString *message;
@property(nonatomic, copy, readonly, nullable) NSString *reason;
@property(nonatomic, copy, readonly, nullable) NSString *nodeId;
@property(nonatomic, copy, readonly, nullable) NSString *nodeName;
@property(nonatomic, copy, readonly, nullable) NSString *taskId;
@property(nonatomic, copy, readonly, nullable) NSString *workspaceId;
@property(nonatomic, copy, readonly, nullable) NSString *agentId;
@property(nonatomic, strong, readonly, nullable) NSNumber *queuePosition;
/// ISO 8601 timestamp.
@property(nonatomic, copy, readonly) NSString *occurredAt;
/// Server ordering. On agent threads, a state with a lower sequence than
/// the current one is ignored.
@property(nonatomic, strong, readonly, nullable) NSNumber *sequence;
@property(nonatomic, copy, readonly, nullable) NSDictionary *details;

/// Parses a `thread_state` content map.
- (instancetype)initWithMap:(NSDictionary *)m;

- (instancetype)initWithThreadId:(NSString *)threadId
                           phase:(ARTThreadStatePhase)phase
                          source:(ARTThreadStateSource)source
                         message:(NSString *)message
                          reason:(nullable NSString *)reason
                          nodeId:(nullable NSString *)nodeId
                        nodeName:(nullable NSString *)nodeName
                          taskId:(nullable NSString *)taskId
                     workspaceId:(nullable NSString *)workspaceId
                         agentId:(nullable NSString *)agentId
                   queuePosition:(nullable NSNumber *)queuePosition
                      occurredAt:(NSString *)occurredAt
                        sequence:(nullable NSNumber *)sequence
                         details:(nullable NSDictionary *)details
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// A copy with `threadId` and `sequence` replaced.
- (instancetype)stateWithThreadId:(NSString *)threadId
                         sequence:(nullable NSNumber *)sequence;

@end

/// Catch-all payload for events the SDK does not yet model.
@interface UnknownAgentEvent : NSObject
@property(nonatomic, copy, readonly) NSString *event;
@property(nonatomic, strong, readonly) NSDictionary *content;
- (instancetype)initWithEvent:(NSString *)event
                      content:(NSDictionary *)content NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

#pragma mark - Envelope

typedef NS_ENUM(NSInteger, AgentEventKind) {
    AgentEventKindOutput,
    AgentEventKindError,
    AgentEventKindHumanInput,
    AgentEventKindWait,
    AgentEventKindPlannerCorrection,
    AgentEventKindUnknown,
    AgentEventKindThreadState,
};

/// Discriminated envelope wrapping any inbound agent event. `kind` selects
/// which typed accessor is non-nil.
@interface AgentEventEnvelope : NSObject
@property(nonatomic, copy, readonly) NSString *event;
@property(nonatomic, assign, readonly) AgentEventKind kind;
@property(nonatomic, strong, readonly) id payload;
/// The event's fields exactly as the server sent them, including any the
/// typed payload doesn't model. Use it to render a response generically. On
/// `human_input_request` it also holds the SDK's `reply` block, which is not
/// JSON.
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *content;

/// YES when `event` is one of the typed (known) event types.
@property(nonatomic, assign, readonly) BOOL isKnown;

- (nullable AgentOutput *)asOutput;
- (nullable AgentError *)asError;
- (nullable HumanInputRequest *)asHumanInput;
- (nullable AgentWait *)asWait;
- (nullable PlannerCorrection *)asPlannerCorrection;
- (nullable ARTThreadState *)asThreadState;
- (nullable UnknownAgentEvent *)asUnknown;

/// Parses a raw `{ event, content }` envelope into a typed envelope.
+ (instancetype)parse:(NSDictionary *)raw;

- (instancetype)initWithEvent:(NSString *)event
                         kind:(AgentEventKind)kind
                      payload:(id)payload
                      content:(nullable NSDictionary<NSString *, id> *)content
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithEvent:(NSString *)event
                         kind:(AgentEventKind)kind
                      payload:(id)payload;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_AGENTEVENTS_H */
