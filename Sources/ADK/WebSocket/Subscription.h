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

@interface Subscription : BaseSubscription

- (void)listen:(void (^)(NSDictionary<NSString *, id> *message))callback;

- (void)bind:(NSString *)event callback:(void (^)(id content))callback;

- (void)remove:(NSString *)event;

- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload;

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

/// Drains buffered events for `threadId` and subscribes `callback` to every
/// future event tagged with it. Each call receives `{event, content}`.
- (void)attachThreadListener:(NSString *)threadId
                    callback:
                        (void (^)(NSDictionary<NSString *, id> *message))callback;

/// Subscribes `callback` to a single named `event` within `threadId`.
- (void)attachThreadBind:(NSString *)threadId
                   event:(NSString *)event
                callback:(void (^)(id content))callback;

/// Removes the listener(s) attached for (`threadId`, `event`).
- (void)detachThreadListener:(NSString *)threadId event:(NSString *)event;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_SUBSCRIPTION_H */
