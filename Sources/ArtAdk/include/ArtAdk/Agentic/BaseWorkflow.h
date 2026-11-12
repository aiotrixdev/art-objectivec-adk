#ifndef ARTADK_AGENTIC_BASEWORKFLOW_H
#define ARTADK_AGENTIC_BASEWORKFLOW_H

#pragma once

//
//  BaseWorkflow.h
//  ADK
//
//  Abstract base for client-side workflow handles (Agent, Orchestrator) that
//  own a single lazy Subscription to a dedicated server-side channel.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class Socket;
@class Subscription;

@interface BaseWorkflow : NSObject

@property(nonatomic, strong, readonly) Socket *socket;

/// Live subscription, populated once the lazy subscribe completes; nil until
/// `getSubscription:` has succeeded once.
@property(nonatomic, strong, readonly, nullable) Subscription *subscription;

- (instancetype)initWithSocket:(Socket *)socket NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// The dedicated server-side channel this workflow subscribes to.
/// Subclasses MUST override.
- (NSString *)channelName;

/// Returns the active Subscription, kicking off the subscribe on first need.
/// Concurrent callers are coalesced onto a single network round-trip, and a
/// failed subscribe is tried again on the next call.
///
/// Waits for the connection first, so it completes with the
/// `ARTConnectionError` once the connection has failed.
- (void)getSubscription:
    (void (^)(Subscription *_Nullable subscription,
              NSError *_Nullable error))completion;

/// Id of the server-side configuration behind this workflow's channel.
/// Storage uses it as the owner of uploaded files.
- (void)configurationId:(void (^)(NSString *_Nullable configurationId,
                                  NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_BASEWORKFLOW_H */
