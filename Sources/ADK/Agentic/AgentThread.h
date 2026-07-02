#ifndef ARTADK_AGENTIC_AGENTTHREAD_H
#define ARTADK_AGENTIC_AGENTTHREAD_H

#pragma once

//
//  AgentThread.h
//  ADK
//
//  A single conversation thread within an Agent. Mirrors the Swift
//  `Agentic/AgentThread.swift` / js-adk-common agentThread.ts.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class Agent;
@class Run;
@class AgentEventEnvelope;
@class HumanInputRequest;

/// Fired for every typed event delivered to the thread.
typedef void (^AgentUserListener)(AgentEventEnvelope *envelope);
/// Fired when the agent emits a HumanInputRequest for the active Run.
typedef void (^AgentHumanInputHandler)(HumanInputRequest *req, Run *run);

@interface AgentThread : NSObject

@property(nonatomic, strong, readonly) Agent *agent;
@property(nonatomic, copy, readonly) NSString *threadId;

- (instancetype)initWithAgent:(Agent *)agent NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Subscribes `callback` to every typed event on this thread. The first call
/// installs the underlying subscription listener.
- (void)listen:(AgentUserListener)callback;

/// Registers a handler invoked on each HumanInputRequest for the active Run.
- (void)feedbackRequest:(AgentHumanInputHandler)handler;

/// Starts a new Run. When `replyId` is set the outbound event is `user_reply`
/// (carrying `reply_id`); otherwise `user_input`. Any previous active run on
/// this thread is force-closed.
- (void)run:(id)userInput
     replyId:(nullable NSString *)replyId
  completion:(void (^)(Run *_Nullable run, NSError *_Nullable error))completion;

#pragma mark - Internal (called by Run)
- (void)fireRequestFeedback:(HumanInputRequest *)req run:(Run *)run;
- (void)closeRun:(Run *)run;
- (void)sendReply:(id)value
          replyId:(NSString *)replyId
       completion:(nullable void (^)(NSString *_Nullable refId,
                                     NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_AGENTTHREAD_H */
