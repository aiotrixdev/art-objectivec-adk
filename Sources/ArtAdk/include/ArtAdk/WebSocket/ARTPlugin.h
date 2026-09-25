#ifndef ARTADK_WEBSOCKET_ARTPLUGIN_H
#define ARTADK_WEBSOCKET_ARTPLUGIN_H

#pragma once

//
//  ARTPlugin.h
//  ADK
//
//  Plugin contract for optional add-ons such as notifications.
//  `-[Adk use:]` installs a plugin and returns its API, which stays
//  available through `-[Adk pluginNamed:]`.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class Adk;
@class BaseSubscription;
@class CallApiProps;
@class AuthenticationConfig;

typedef void (^ARTPluginSubscribeBlock)(
    NSString *channel,
    void (^completion)(BaseSubscription *_Nullable subscription,
                       NSError *_Nullable error));
typedef void (^ARTPluginCallBlock)(
    NSString *endpoint, CallApiProps *_Nullable options,
    void (^completion)(id _Nullable result, NSError *_Nullable error));

/// What a plugin can use from its host `Adk`: the shared connection, the
/// authenticated REST client, the credentials and the gateway origin.
@interface ARTAdkPluginContext : NSObject

/// A context backed by the given blocks (useful for testing plugins).
- (instancetype)
    initWithSubscribe:(ARTPluginSubscribeBlock)subscribe
                 call:(ARTPluginCallBlock)call
       getCredentials:(AuthenticationConfig *_Nullable (^)(void))getCredentials
              baseUrl:(NSString * (^)(void))baseUrl NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Subscribes to a channel on the shared connection.
- (void)subscribe:(NSString *)channel
       completion:(void (^)(BaseSubscription *_Nullable subscription,
                            NSError *_Nullable error))completion;

/// Authenticated REST call. Completes with the decoded JSON (nil for a 204)
/// or an error carrying `ARTHTTPStatusCodeKey` for non-2xx responses.
- (void)call:(NSString *)endpoint
       options:(nullable CallApiProps *)options
    completion:(void (^)(id _Nullable result, NSError *_Nullable error))completion;

/// The current credentials. Fails before `connect`.
- (nullable AuthenticationConfig *)getCredentials:(NSError **)error;

/// The gateway origin (the ART URL without a path such as `/ws`), where
/// plugins send REST calls by default.
- (NSString *)baseUrl;

@end

/// An installable ADK add-on. `installWithContext:` is called once by
/// `-[Adk use:]`, which returns the plugin's API.
@protocol ARTAdkPlugin <NSObject>

/// Registry key used by `-[Adk pluginNamed:]`.
@property(nonatomic, copy, readonly) NSString *name;

/// Returns the plugin's API object.
- (id)installWithContext:(ARTAdkPluginContext *)context;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_ARTPLUGIN_H */
