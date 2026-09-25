#ifndef ARTADK_AGENTIC_ORCHESTRATOR_H
#define ARTADK_AGENTIC_ORCHESTRATOR_H

#pragma once

//
//  Orchestrator.h
//  ADK
//
//  Top-level handle for an orchestrator-managed workflow. Subscribes to its
//  dedicated `orch_com_<id>` channel and spawns OrchestratorThreads without
//  requiring the channel-level orchestratorEnabled flag.
//

#import "BaseWorkflow.h"

NS_ASSUME_NONNULL_BEGIN

@class Socket;
@class OrchestratorThread;
@class ARTFileRef;
@class ARTStorageFileList;
@class ARTUploadOptions;
@class ARTListOptions;

@interface Orchestrator : BaseWorkflow

/// The server-side identifier (channel is `orch_com_<orchestratorId>`).
@property(nonatomic, copy, readonly) NSString *orchestratorId;

- (instancetype)initWithOrchestratorId:(NSString *)orchestratorId
                                socket:(Socket *)socket;

/// Opens (or reuses) an OrchestratorThread, awaiting the lazy subscription on
/// first call. Bypasses the orchestratorEnabled gate.
- (void)thread:(void (^)(OrchestratorThread *_Nullable thread,
                         NSError *_Nullable error))completion;

/// Same as `thread:` but reuses/creates the thread for the supplied id.
- (void)threadWithId:(nullable NSString *)threadId
          completion:(void (^)(OrchestratorThread *_Nullable thread,
                               NSError *_Nullable error))completion;

#pragma mark - Storage (orchestrator-scoped)

/// Uploads a local file scoped to this orchestrator: `configId` is always the
/// orchestrator id, whatever `options` contains.
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

/// Lists files scoped to this orchestrator.
- (void)listFilesWithOptions:(nullable ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable list,
                                       NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_ORCHESTRATOR_H */
