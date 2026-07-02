#ifndef ARTADK_AGENTIC_AGENT_H
#define ARTADK_AGENTIC_AGENT_H

#pragma once

//
//  Agent.h
//  ADK
//
//  Handle for a single named agent over its `agent_com_<agentId>` channel.
//  Mirrors the Swift `Agentic/Agent.swift` / js-adk-common agent.ts.
//

#import "BaseWorkflow.h"

NS_ASSUME_NONNULL_BEGIN

@class Socket;
@class AgentThread;

@interface Agent : BaseWorkflow

/// The server-side agent identifier (channel is `agent_com_<agentId>`).
@property(nonatomic, copy, readonly) NSString *agentId;

- (instancetype)initWithAgentId:(NSString *)agentId socket:(Socket *)socket;

/// Returns a new AgentThread backed by this agent. Each call returns a fresh
/// thread with its own id; one agent may host many concurrent threads.
- (AgentThread *)thread;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_AGENT_H */
