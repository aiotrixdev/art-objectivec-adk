#ifndef ARTADK_AGENTIC_ARTTHREADSTATESTORE_H
#define ARTADK_AGENTIC_ARTTHREADSTATESTORE_H

#pragma once

//
//  ARTThreadStateStore.h
//  ADK
//
//  Holds one thread's current ARTThreadState and its `listenState`
//  callbacks. Used by AgentThread (sequence-checked) and OrchestratorThread
//  (no sequence check). Not part of the public API.
//

#import "AgentEvents.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ARTThreadStateListener)(ARTThreadState *state);

@interface ARTThreadStateStore : NSObject

@property(nonatomic, copy, readonly) NSString *threadId;
/// Snapshot of the current state.
@property(nonatomic, strong, readonly) ARTThreadState *state;
@property(nonatomic, assign, readonly) BOOL hasListeners;

- (instancetype)initWithThreadId:(NSString *)threadId
                enforcesSequence:(BOOL)enforcesSequence NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSUUID *)addListener:(ARTThreadStateListener)listener;
- (void)removeListener:(NSUUID *)identifier;
- (void)removeAllListeners;

/// Applies a state, ignoring states for other threads and (when sequence
/// checking is on) states older than the current `sequence`. Listeners are
/// called outside the lock.
- (void)apply:(ARTThreadState *)incoming;

/// Records a client-side transition.
- (void)transition:(ARTThreadStatePhase)phase
            source:(ARTThreadStateSource)source
           message:(NSString *)message
            reason:(nullable NSString *)reason
       workspaceId:(nullable NSString *)workspaceId
           agentId:(nullable NSString *)agentId;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_ARTTHREADSTATESTORE_H */
