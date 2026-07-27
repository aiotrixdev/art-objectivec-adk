#ifndef ARTADK_AGENTIC_BASEWORKFLOW_H
#define ARTADK_AGENTIC_BASEWORKFLOW_H

#pragma once

//
//  BaseWorkflow.h
//  ADK
//
//  Abstract base for client-side workflow handles (Agent, Orchestrator) that
//  own a single lazy Subscription to a dedicated server-side channel. Mirrors
//  the Swift `Agentic/BaseWorkflow.swift` / js-adk-common BaseWorkflow.ts.
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
/// Concurrent callers are coalesced onto a single network round-trip.
- (void)getSubscription:
    (void (^)(Subscription *_Nullable subscription,
              NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AGENTIC_BASEWORKFLOW_H */
