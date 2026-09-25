#ifndef ARTADK_WEBSOCKET_HTTPCALL_H
#define ARTADK_WEBSOCKET_HTTPCALL_H

#pragma once

//
//  HTTPCall.h
//  ADK
//
//  Shared authenticated REST client, used by `-[Adk callEndpoint:...]`,
//  storage, profile updates and plugins, so every request gets a fresh
//  token and the same ART headers.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class CallApiProps;

@interface ARTHTTPClient : NSObject

/// Session for auth and REST calls. Defaults to `NSURLSession.sharedSession`.
@property(class, nonatomic, strong) NSURLSession *session;

/// Configuration for the per-upload sessions used by storage uploads (each
/// upload needs its own delegate to report progress). Defaults to an
/// ephemeral configuration.
@property(class, nonatomic, strong)
    NSURLSessionConfiguration *uploadConfiguration;

/// Calls an ART REST endpoint with a fresh access token.
///
/// 1. Authenticates, renewing the token when needed.
/// 2. Calls `options.baseUrl` (default: the ART gateway) + `endpoint`, with
///    `options.queryParams` form-encoded.
/// 3. Sends `Authorization`, `Accept`, `X-Org`, `Environment`, `ProjectKey`,
///    the caller's headers, and `Content-Type: application/json` when there
///    is a payload.
///
/// Completes with the decoded JSON, nil for a 204 or empty body, or an
/// error. A non-2xx response gives an error whose description is
/// `API <endpoint> failed: <message>`; its `userInfo` holds
/// `ARTHTTPStatusCodeKey`, `ARTHTTPMessageKey`, `ARTHTTPEndpointKey` and,
/// when the body was JSON, `ARTHTTPResponseBodyKey`.
+ (void)call:(NSString *)endpoint
       options:(nullable CallApiProps *)options
    completion:(void (^)(id _Nullable result, NSError *_Nullable error))completion;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface ARTGateway : NSObject

/// The gateway URL without a trailing `/ws`, where the REST APIs
/// (`/api/<tenant>/...`) live.
@property(class, nonatomic, readonly) NSString *restBase;

/// The gateway origin (scheme, host and port).
@property(class, nonatomic, readonly) NSString *origin;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_HTTPCALL_H */
