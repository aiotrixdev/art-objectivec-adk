#ifndef ARTADK_WEBSOCKET_SUBSCRIPTION_H
#define ARTADK_WEBSOCKET_SUBSCRIPTION_H

#pragma once

//
//  Subscription.h
//  ADK
//

#import "BaseSubscription.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class OrchestratorThread;
@class ARTFileRef;
@class ARTStorageFileList;
@class ARTUploadOptions;
@class ARTListOptions;

@interface Subscription : BaseSubscription

/// Delivers buffered events, then every future event without a thread id,
/// as `@{ @"event": name, @"content": payload }`. Returns a token for
/// `remove:identifier:` with event `all`.
- (NSUUID *)listen:(void (^)(NSDictionary<NSString *, id> *message))callback;

/// Delivers buffered payloads for `event`, then future ones. Returns a
/// token for `remove:identifier:`.
- (NSUUID *)bind:(NSString *)event callback:(void (^)(id content))callback;

/// Removes every listener for `event` and drops its buffered payloads.
- (void)remove:(NSString *)event;

/// Removes the single listener registered with `identifier` for `event`
/// and drops the event's buffered payloads.
- (void)remove:(NSString *)event identifier:(NSUUID *)identifier;

- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload;

#pragma mark - Storage (orchestrator-enabled channels)

/// Uploads a local file scoped to this channel (`config_id` is the channel
/// name). Fails unless the channel is orchestrator-enabled.
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

/// Lists files scoped to this channel. Fails unless the channel is
/// orchestrator-enabled.
- (void)listFilesWithOptions:(nullable ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable list,
                                       NSError *_Nullable error))completion;

#pragma mark - Thread-scoped routing (orchestrator)

/// Returns an OrchestratorThread for this channel, or nil when the channel is
/// not orchestrator-enabled. A matching live thread is reused.
- (nullable OrchestratorThread *)thread:(nullable NSString *)threadId;

/// Same as `thread:` but skips the orchestratorEnabled gate — used by
/// `Orchestrator`, which commits to orchestrator semantics on a dedicated
/// channel.
- (OrchestratorThread *)threadUnchecked:(nullable NSString *)threadId;

/// Returns the live OrchestratorThread for `threadId`, or nil.
- (nullable OrchestratorThread *)getThread:(NSString *)threadId;

/// Removes `threadId` from the registry and drops any buffered messages.
- (void)unregisterThread:(NSString *)threadId;

/// Snapshot of buffered thread events: thread id → event → entries.
- (NSDictionary<NSString *, NSDictionary<NSString *, NSArray<NSDictionary *> *> *> *)
    threadBuffers;

/// Delivers buffered events for `threadId`, then every future event tagged
/// with it, as `@{ @"event": name, @"content": payload }`. Returns a token
/// for `detachThreadListener:event:identifier:` with event `all`.
- (NSUUID *)attachThreadListener:(NSString *)threadId
                        callback:(void (^)(NSDictionary<NSString *, id> *message))
                                     callback;

/// Subscribes `callback` to a single named `event` within `threadId`,
/// replaying buffered payloads first. Returns a token for
/// `detachThreadListener:event:identifier:`.
- (NSUUID *)attachThreadBind:(NSString *)threadId
                       event:(NSString *)event
                    callback:(void (^)(id content))callback;

/// Removes every listener attached for (`threadId`, `event`) and drops the
/// pair's buffered payloads.
- (void)detachThreadListener:(NSString *)threadId event:(NSString *)event;

/// Removes the single listener registered with `identifier` for
/// (`threadId`, `event`) and drops the pair's buffered payloads.
- (void)detachThreadListener:(NSString *)threadId
                       event:(NSString *)event
                  identifier:(NSUUID *)identifier;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_SUBSCRIPTION_H */
