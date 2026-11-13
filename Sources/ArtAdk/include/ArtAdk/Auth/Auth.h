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
//  - A complete client ID and secret pair uses the client-credentials grant:
//    tokens are renewed by authenticating again, never with a refresh token.
//    Without a client secret, `accessToken` is exchanged and renewed with
//    the refresh token.
//

#import <Foundation/Foundation.h>

@class AuthenticationConfig;
@class AuthData;
@class CredentialStore;

NS_ASSUME_NONNULL_BEGIN

/// Domain of `ARTAuthHttpError`.
FOUNDATION_EXPORT NSErrorDomain const ARTAuthHttpErrorDomain;

/// An authentication request that the ART server rejected with an HTTP
/// error.
///
/// Returned when getting or renewing a token fails, and when the server
/// refuses to renew a live connection's authorisation.
@interface ARTAuthHttpError : NSError

/// Server `message`, else the HTTP status text.
@property(nonatomic, copy, readonly) NSString *message;
/// HTTP status code returned by the server.
@property(nonatomic, assign, readonly) NSInteger status;
/// Decoded response body, when the server sent JSON.
@property(nonatomic, strong, readonly, nullable) id body;
/// Whether the credentials themselves were rejected (HTTP 401 or 403).
/// Retrying with the same credentials cannot succeed, so the SDK stops
/// reconnecting when it sees one of these.
@property(nonatomic, assign, readonly) BOOL isTerminal;

+ (instancetype)errorWithMessage:(NSString *)message
                          status:(NSInteger)status
                            body:(nullable id)body;

@end

/// Whether `error` is an `ARTAuthHttpError` for rejected credentials (HTTP
/// 401 or 403).
FOUNDATION_EXPORT BOOL ARTIsTerminalAuthError(NSError *_Nullable error);

@interface Auth : NSObject

/// Returns the shared instance.
///
/// `credentials` is required on the very first call. On later calls it
/// replaces the stored credentials when it names the same identity
/// (organisation, environment, project and client ID), and replaces the
/// whole instance, dropping its tokens, when it names another one. Fails
/// when called for the first time without credentials.
+ (nullable Auth *)getInstance:(nullable AuthenticationConfig *)credentials
                         error:(NSError **)error;

/// Releases the shared instance.
+ (void)reset;

/// Completes with a valid token pair, generating or refreshing it when
/// needed. Concurrent calls share a single request; `forceAuth` renews a
/// token that is still valid (used when reconnecting).
///
/// Completes with an `ARTAuthHttpError` when the server rejects the request,
/// and with an `ErrorCodeAuthenticationFailed` error when the credentials
/// are incomplete, the server cannot be reached or does not answer within
/// `AdkConfig.connectionTimeoutMs`, or the response holds no access token.
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
