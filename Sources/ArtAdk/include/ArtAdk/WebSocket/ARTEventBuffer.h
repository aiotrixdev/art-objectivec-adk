#ifndef ARTADK_WEBSOCKET_ARTEVENTBUFFER_H
#define ARTADK_WEBSOCKET_ARTEVENTBUFFER_H

#pragma once

//
//  ARTEventBuffer.h
//  ADK
//
//  Per-event buffer that remembers arrival order: a replay walks events in
//  the order they first arrived, then each event's messages in arrival
//  order. Not thread-safe; the owning subscription guards it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ARTEventBuffer : NSObject

@property(nonatomic, assign, readonly) BOOL isEmpty;

/// A buffer holding `dictionary`'s entries, with events in sorted order.
+ (instancetype)bufferWithDictionary:
    (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)dictionary;

/// Snapshot keyed by event name.
- (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)dictionary;

- (void)appendEvent:(NSString *)event entry:(NSDictionary *)entry;

/// Removes and returns the entries buffered for `event`.
- (NSArray<NSDictionary *> *)takeEvent:(NSString *)event;

/// Removes and returns every entry in replay order, as `@[event, entry]`
/// pairs.
- (NSArray<NSArray *> *)drainAll;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_ARTEVENTBUFFER_H */
