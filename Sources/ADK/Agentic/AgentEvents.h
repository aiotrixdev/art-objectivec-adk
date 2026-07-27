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
//  reply). Mirrors the Swift `Agentic/Events.swift` / js-adk-common.
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
@property(nonatomic, copy, readonly, nullable) NSString *reason;
@property(nonatomic, strong, readonly, nullable) NSNumber *timeout;
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
@property(nonatomic, copy, readonly) NSString *threadId;
@property(nonatomic, copy, readonly) NSString *refId;
@property(nonatomic, copy, readonly) NSString *agentId;
@property(nonatomic, copy, readonly) NSString *replyTo;
- (instancetype)initWithMap:(NSDictionary *)m NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
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
};

/// Discriminated envelope wrapping any inbound agent event. `kind` selects
/// which typed accessor is non-nil.
@interface AgentEventEnvelope : NSObject
@property(nonatomic, copy, readonly) NSString *event;
@property(nonatomic, assign, readonly) AgentEventKind kind;
@property(nonatomic, strong, readonly) id payload;

- (nullable AgentOutput *)asOutput;
- (nullable AgentError *)asError;
- (nullable HumanInputRequest *)asHumanInput;
- (nullable AgentWait *)asWait;
- (nullable PlannerCorrection *)asPlannerCorrection;
- (nullable UnknownAgentEvent *)asUnknown;

/// Parses a raw `{ event, content }` envelope into a typed envelope.
+ (instancetype)parse:(NSDictionary *)raw;

- (instancetype)initWithEvent:(NSString *)event
                         kind:(AgentEventKind)kind
                      payload:(id)payload NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_AGENTEVENTS_H */
