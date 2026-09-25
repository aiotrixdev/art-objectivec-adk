#ifndef ARTADK_AGENTIC_RUN_H
#define ARTADK_AGENTIC_RUN_H

#pragma once

//
//  Run.h
//  ADK
//
//  Handle for a single logical conversation with an agent. `done:` resolves
//  with the terminal AgentOutput or the terminal AgentError. Human-in-the-
//  loop turns stay inside one Run until the agent sends a terminal event.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AgentThread;
@class AgentOutput;
@class AgentError;
@class AgentEventEnvelope;

/// Resolution of a Run — exactly one of `output` / `error` is non-nil. A
/// superseded/closed run resolves with an AgentError whose code is
/// `RUN_SUPERSEDED`.
typedef void (^RunDoneHandler)(AgentOutput *_Nullable output,
                               AgentError *_Nullable error);

@interface Run : NSObject

/// `ref_id` the SDK generated for the `user_input` that started this run.
/// Empty until the push completes.
@property(nonatomic, copy, readonly) NSString *refId;
@property(nonatomic, assign, readonly, getter=isClosed) BOOL closed;

- (instancetype)initWithThread:(AgentThread *)thread NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Resolves on the agent's terminal general_response (output) or
/// error_response (error). If already settled, the handler fires
/// immediately. Several handlers can be registered.
- (void)done:(RunDoneHandler)handler;

/// Answers the most recent human_input_request by sending a user_reply with
/// the matching reply_id.
- (void)sendFeedback:(id)value
          completion:(nullable void (^)(NSError *_Nullable error))completion;

#pragma mark - Internal (called by AgentThread)
- (void)setRefId:(NSString *)refId;
- (void)pushEnvelope:(AgentEventEnvelope *)envelope;
- (void)close:(NSString *)reason;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_RUN_H */
