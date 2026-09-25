#ifndef ARTADK_AGENTIC_AGENTTHREAD_H
#define ARTADK_AGENTIC_AGENTTHREAD_H

#pragma once

//
//  AgentThread.h
//  ADK
//
//  A single conversation thread within an Agent. Outbound messages carry a
//  top-level `thread_id`, and replies tagged with this thread's id are
//  routed back to it (as well as untagged channel events).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class Agent;
@class Run;
@class AgentEventEnvelope;
@class HumanInputRequest;
@class ARTThreadState;
@class ARTFileMeta;
@class ARTFileRef;
@class ARTStorageFileList;
@class ARTUploadOptions;
@class ARTListOptions;

/// Fired for every typed event delivered to the thread.
typedef void (^AgentUserListener)(AgentEventEnvelope *envelope);
/// Fired when the agent emits a HumanInputRequest for the active Run.
typedef void (^AgentHumanInputHandler)(HumanInputRequest *req, Run *run);
/// Removes a callback added with `listenState:`.
typedef void (^ARTStateUnsubscribe)(void);

@interface AgentThread : NSObject

@property(nonatomic, strong, readonly) Agent *agent;
/// Stable identifier sent as `thread_id` on every outbound message, so the
/// server can route replies back to this thread.
@property(nonatomic, copy, readonly) NSString *threadId;

/// Convenience initializer — equivalent to `initWithAgent:agent threadId:nil`,
/// which generates a fresh thread id.
- (instancetype)initWithAgent:(Agent *)agent;

/// Designated initializer. If `threadId` is nil, a fresh id is generated
/// locally; otherwise the given id is used (e.g. to resume an existing
/// thread).
- (instancetype)initWithAgent:(Agent *)agent
                      threadId:(nullable NSString *)threadId
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// A new random thread id (a lowercase UUID).
+ (NSString *)generateThreadId;

/// Subscribes `callback` to every typed event on this thread. The first call
/// installs the underlying subscription listeners.
- (void)listen:(AgentUserListener)callback;

/// Subscribes `callback` to this thread's operational state: submitted,
/// waiting for your input, another agent or a workspace, completed, failed,
/// and the server's `thread_state` updates. With `emitCurrent`, the current
/// state is delivered immediately. Returns a block that removes the
/// callback.
- (ARTStateUnsubscribe)listenState:(void (^)(ARTThreadState *state))callback
                       emitCurrent:(BOOL)emitCurrent;

/// Same as `listenState:emitCurrent:` with `emitCurrent` YES.
- (ARTStateUnsubscribe)listenState:(void (^)(ARTThreadState *state))callback;

/// The thread's current operational state.
- (ARTThreadState *)getState;

/// Subscribes `callback` to inbound `trace` diagnostic frames (heartbeats,
/// checkpoints, deadlock signals) on this thread, each delivered as its raw
/// value.
- (void)listenTrace:(void (^)(id data))callback
    __attribute__((deprecated("Use listenState: for operational UI. Trace is "
                              "reserved for diagnostics.")));

/// Registers a handler invoked on each HumanInputRequest for the active Run.
- (void)feedbackRequest:(AgentHumanInputHandler)handler;

/// Starts a new Run. When `replyId` is set the outbound event is `user_reply`
/// (carrying `reply_id`); otherwise `user_input`. Any previous active run on
/// this thread is force-closed.
- (void)run:(id)userInput
     replyId:(nullable NSString *)replyId
  completion:(void (^)(Run *_Nullable run, NSError *_Nullable error))completion;

/// Same as `run:replyId:completion:`, attaching uploaded files the agent may
/// use. They are sent as the frame's `file_meta`; upload them first, for
/// example with `-[Agent uploadFileURL:options:completion:]`.
- (void)run:(id)userInput
     replyId:(nullable NSString *)replyId
    fileMeta:(nullable NSArray<ARTFileMeta *> *)fileMeta
  completion:(void (^)(Run *_Nullable run, NSError *_Nullable error))completion;

#pragma mark - Storage (thread-scoped)

/// Uploads a local file scoped to this thread: `configId` is always the
/// thread id, whatever `options` contains.
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

/// Lists files scoped to this thread.
- (void)listFilesWithOptions:(nullable ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable list,
                                       NSError *_Nullable error))completion;

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
