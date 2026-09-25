#ifndef ARTADK_AGENTIC_AGENT_H
#define ARTADK_AGENTIC_AGENT_H

#pragma once

//
//  Agent.h
//  ADK
//
//  Handle for a single named agent over its `agent_com_<agentId>` channel.
//  The subscription is lazy and shared by all of the agent's threads.
//

#import "BaseWorkflow.h"

NS_ASSUME_NONNULL_BEGIN

@class Socket;
@class AgentThread;
@class ARTFileRef;
@class ARTStorageFileList;
@class ARTUploadOptions;
@class ARTListOptions;

@interface Agent : BaseWorkflow

/// The server-side agent identifier (channel is `agent_com_<agentId>`).
@property(nonatomic, copy, readonly) NSString *agentId;

- (instancetype)initWithAgentId:(NSString *)agentId socket:(Socket *)socket;

/// Returns a new AgentThread backed by this agent. Each call returns a fresh
/// thread with its own id; one agent may host many concurrent threads.
- (AgentThread *)thread;

/// Returns a new AgentThread backed by this agent. If `threadId` is nil, a
/// fresh id is generated locally (equivalent to `-thread`); otherwise the
/// given id is used, so callers can resume an existing thread.
- (AgentThread *)threadWithId:(nullable NSString *)threadId;

#pragma mark - Storage (agent-scoped)

/// Uploads a local file scoped to this agent: `configId` is always the
/// agent id, whatever `options` contains.
- (void)uploadFileURL:(NSURL *)fileURL
              options:(nullable ARTUploadOptions *)options
           completion:(void (^)(ARTFileRef *_Nullable fileRef,
                                NSError *_Nullable error))completion;

/// In-memory variant of `uploadFileURL:options:completion:`.
- (void)uploadData:(NSData *)data
          filename:(nullable NSString *)filename
       contentType:(nullable NSString *)contentType
           options:(nullable ARTUploadOptions *)options
        completion:(void (^)(ARTFileRef *_Nullable fileRef,
                             NSError *_Nullable error))completion;

/// Lists files scoped to this agent.
- (void)listFilesWithOptions:(nullable ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable list,
                                       NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_AGENT_H */
