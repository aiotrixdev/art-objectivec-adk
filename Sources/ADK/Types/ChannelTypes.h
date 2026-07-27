#ifndef ARTADK_TYPES_CHANNELTYPES_H
#define ARTADK_TYPES_CHANNELTYPES_H

#pragma once

//
//  ChannelTypes.h
//  ADK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ChannelConfig : NSObject

@property(nonatomic, copy) NSString *channelName;
@property(nonatomic, copy) NSString *channelNamespace;
@property(nonatomic, copy) NSString *channelType;
@property(nonatomic, strong) NSArray<NSString *> *presenceUsers;
@property(nonatomic, strong, nullable) id snapshot;
@property(nonatomic, copy, nullable) NSString *subscriptionID;
/// Whether this channel is orchestrator-enabled. Gates the generic
/// `-[Subscription thread]` accessor; `Orchestrator` bypasses it via
/// `threadUnchecked`. Defaults to NO. Mirrors the Swift/Flutter
/// `ChannelConfig.orchestratorEnabled`.
@property(nonatomic, assign) BOOL orchestratorEnabled;

- (instancetype)initWithChannelName:(NSString *)channelName;
- (instancetype)initWithChannelName:(NSString *)channelName
                   channelNamespace:(NSString *)channelNamespace
                        channelType:(NSString *)channelType
                      presenceUsers:(NSArray<NSString *> *)presenceUsers
                           snapshot:(nullable id)snapshot
                     subscriptionID:(nullable NSString *)subscriptionID
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_TYPES_CHANNELTYPES_H */
