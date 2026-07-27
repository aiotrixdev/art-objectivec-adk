#ifndef ARTADK_AGENTIC_ORCHESTRATORTHREAD_H
#define ARTADK_AGENTIC_ORCHESTRATORTHREAD_H

#pragma once

//
//  OrchestratorThread.h
//  ADK
//
//  Per-thread handle for orchestrator-enabled channels. Wraps a Subscription
//  and scopes every push/listen to a single logical thread. Mirrors the Swift
//  `Agentic/OrchestratorThread.swift` / js-adk-common orcThread.ts.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class Subscription;

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

/// Drains buffered events and subscribes `callback` to every future event
/// tagged with `threadId`. Each call receives `{ event, content }`.
- (void)listen:(void (^)(NSDictionary<NSString *, id> *message))callback;

/// Subscribes `callback` to a single named `event` within this thread.
- (void)bind:(NSString *)event callback:(void (^)(id content))callback;

/// Subscribes `callback` to inbound `trace` diagnostic / telemetry frames on
/// this thread. Binds both the channel-level and thread-scoped `trace` event so
/// a frame is delivered whether or not it carries a `thread_id`. Mirrors
/// js-adk-common `OrchestratorThread.listenTrace`.
- (void)listenTrace:(void (^)(id content))callback;

/// Removes every listener bound to `event` on this thread.
- (void)remove:(NSString *)event;

/// Detaches all listeners and unregisters the thread from its subscription.
- (void)dispose;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_ORCHESTRATORTHREAD_H */
