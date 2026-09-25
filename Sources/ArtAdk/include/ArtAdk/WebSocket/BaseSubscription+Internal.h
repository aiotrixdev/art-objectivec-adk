#ifndef ARTADK_WEBSOCKET_BASESUBSCRIPTION_INTERNAL_H
#define ARTADK_WEBSOCKET_BASESUBSCRIPTION_INTERNAL_H

#pragma once

//
//  BaseSubscription+Internal.h
//  ADK
//
//  State shared between BaseSubscription and its subclasses. Not part of
//  the public API.
//

#import "ARTEventBuffer.h"
#import "BaseSubscription.h"

NS_ASSUME_NONNULL_BEGIN

@interface BaseSubscription ()

/// Guards the buffers and pending acknowledgements. Never call app
/// callbacks while holding it.
@property(nonatomic, strong, readonly) NSObject *stateLock;

/// Buffered events without a thread id. Guarded by `stateLock`.
@property(nonatomic, strong, readonly) ARTEventBuffer *bufferStorage;

/// Channels handled locally, without a `channel-subscribe` round trip.
+ (NSSet<NSString *> *)reservedChannels;

/// Channels that never take part in acknowledgements or ref tracking.
+ (NSSet<NSString *> *)controlChannels;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_BASESUBSCRIPTION_INTERNAL_H */
