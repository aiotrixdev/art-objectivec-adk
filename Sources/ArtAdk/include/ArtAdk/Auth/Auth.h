#ifndef ARTADK_AUTH_AUTH_H
#define ARTADK_AUTH_AUTH_H

#pragma once

//
//  Auth.h
//  ADK
//
//  Token management for the ART gateway.
//
//  - `authenticate:completion:` is shared: concurrent callers (socket,
//    long poll, REST, storage) wait on one token request, so a refresh
//    token is never used twice in parallel.
//  - Access tokens are renewed 30 seconds before they expire.
//

#import <Foundation/Foundation.h>

@class AuthenticationConfig;
@class AuthData;
@class CredentialStore;

NS_ASSUME_NONNULL_BEGIN

@interface Auth : NSObject

/// Returns the shared instance, creating it from `credentials` on the first
/// call. Fails when called for the first time without credentials.
+ (nullable Auth *)getInstance:(nullable AuthenticationConfig *)credentials
                         error:(NSError **)error;

/// Releases the shared instance.
+ (void)reset;

/// Completes with a valid token pair, generating or refreshing it when
/// needed. Concurrent calls share a single request.
- (void)authenticate:(BOOL)forceAuth
          completion:(void (^)(AuthData *_Nullable data,
                               NSError *_Nullable error))completion;

/// A copy of the current token pair.
- (AuthData *)getAuthData;

/// A copy of the current credentials.
- (AuthenticationConfig *)getCredentials;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AUTH_AUTH_H */
