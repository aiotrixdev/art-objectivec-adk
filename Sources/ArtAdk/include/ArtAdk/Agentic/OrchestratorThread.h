#ifndef ARTADK_AGENTIC_ORCHESTRATORTHREAD_H
#define ARTADK_AGENTIC_ORCHESTRATORTHREAD_H

#pragma once

//
//  OrchestratorThread.h
//  ADK
//
//  Per-thread handle for orchestrator-enabled channels. Wraps a Subscription
//  and scopes every push/listen to a single logical thread.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class Subscription;
@class PushConfig;
@class ARTThreadState;
@class ARTFileRef;
@class ARTStorageFileList;
@class ARTUploadOptions;
@class ARTListOptions;

@interface OrchestratorThread : NSObject

/// Stable identifier carried as `thread_id` on every outbound message and
/// used to namespace inbound events.
@property(nonatomic, copy, readonly) NSString *threadId;

/// Whether `dispose` has been called.
@property(nonatomic, assign, readonly, getter=isDisposed) BOOL disposed;

/// Created via `-[Subscription threadUnchecked:]`. When `threadId` is nil a
/// fresh id is generated locally.
- (instancetype)initWithSubscription:(Subscription *)subscription
                            threadId:(nullable NSString *)threadId
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Sends a message tagged with this thread's `threadId`.
- (void)push:(NSString *)event
        data:(NSDictionary<NSString *, id> *)data
  completion:(nullable void (^)(NSError *_Nullable error))completion;

/// Sends a message tagged with this thread's `threadId`. The caller's
/// options (`to`, `fileMeta`) are kept; `threadID` is always this thread's
/// id. Records a `submitted` state.
- (void)push:(NSString *)event
        data:(NSDictionary<NSString *, id> *)data
     options:(nullable PushConfig *)options
  completion:(nullable void (^)(NSError *_Nullable error))completion;

/// Drains buffered events and subscribes `callback` to every future event
/// tagged with `threadId`. Each call receives `{ event, content }`.
- (void)listen:(void (^)(NSDictionary<NSString *, id> *message))callback;

/// Subscribes `callback` to a single named `event` within this thread.
- (void)bind:(NSString *)event callback:(void (^)(id content))callback;

/// Subscribes `callback` to inbound `trace` diagnostic frames on this thread.
/// Binds both the channel-level and thread-scoped `trace` event so a frame
/// is delivered whether or not it carries a `thread_id`.
- (void)listenTrace:(void (^)(id content))callback
    __attribute__((deprecated("Use listenState: for operational UI. Trace is "
                              "reserved for diagnostics.")));

/// Subscribes `callback` to this thread's operational state: `submitted` on
/// `push`, then the server's `thread_state` events for this thread. With
/// `emitCurrent`, the current state is delivered immediately. Returns a
/// block that removes the callback.
- (void (^)(void))listenState:(void (^)(ARTThreadState *state))callback
                  emitCurrent:(BOOL)emitCurrent;

/// Same as `listenState:emitCurrent:` with `emitCurrent` YES.
- (void (^)(void))listenState:(void (^)(ARTThreadState *state))callback;

/// The thread's current operational state.
- (ARTThreadState *)getState;

#pragma mark - Storage (thread-scoped)

/// Uploads a local file scoped to this thread (`config_id` is the thread
/// id). Fails after `dispose`.
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

/// Lists files scoped to this thread. Fails after `dispose`.
- (void)listFilesWithOptions:(nullable ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable list,
                                       NSError *_Nullable error))completion;

/// Removes every listener bound to `event` on this thread.
- (void)remove:(NSString *)event;

/// Detaches every listener attached through this thread and unregisters it
/// from its subscription. Other threads' listeners are left in place.
- (void)dispose;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_ORCHESTRATORTHREAD_H */
