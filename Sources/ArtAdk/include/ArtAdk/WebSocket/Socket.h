#ifndef ARTADK_WEBSOCKET_SOCKET_H
#define ARTADK_WEBSOCKET_SOCKET_H

#pragma once

//
//  Socket.h
//  ADK
//

#import <ArtAdk/Types/SocketTypes.h>
#import <Foundation/Foundation.h>

@class AuthenticationConfig;
@class BaseSubscription;
@class Interception;
@class EventEmitter;
@class LongPollClient;

NS_ASSUME_NONNULL_BEGIN

typedef void (^EncryptBlock)(NSString *data, NSString *key,
                             void (^completion)(NSString *_Nullable encrypted,
                                                NSError *_Nullable error));

typedef void (^DecryptBlock)(NSString *data, NSString *key,
                             void (^completion)(NSString *_Nullable decrypted,
                                                NSError *_Nullable error));

@interface Socket : NSObject <WebsocketHandler, NSURLSessionWebSocketDelegate,
                              NSURLSessionDataDelegate>

@property(nonatomic, copy) EncryptBlock encryptBlock;
@property(nonatomic, copy) DecryptBlock decryptBlock;

/// Whether the socket currently has an active (server-confirmed or local
/// fallback) connection.
@property(nonatomic, assign) BOOL isConnectionActive;

/// YES during a reconnect attempt (forces a token renewal).
@property(nonatomic, assign) BOOL isReConnecting;

+ (Socket *)getInstance:(EncryptBlock)encrypt
                           decrypt:(DecryptBlock)decrypt;

/// Release the shared Socket instance so the next call to
/// +getInstance:decrypt: creates a fresh one. Typically used by tests
/// or when an app wants to fully tear down and re-init the SDK.
+ (void)reset;

/// Starts a new connection attempt: clears an earlier failure and sets the
/// readiness timeout to `timeoutMs` milliseconds. `-[Adk connect:completion:]`
/// calls this before connecting.
///
/// Returns NO and sets `error` (`ErrorCodeInvalidArgument`) when `timeoutMs`
/// is not positive.
- (BOOL)beginConnectionWithTimeoutMs:(NSInteger)timeoutMs error:(NSError **)error;

/// Ends the connection with `error` and stops automatic reconnection.
///
/// Closes the transport, fails pending connection waits and control requests
/// with `error`, and emits `connectionFailed`. Waits and sends keep failing
/// with `error` until `beginConnectionWithTimeoutMs:error:` starts a new
/// attempt. Only the first failure counts; later calls do nothing.
- (void)failConnection:(ARTConnectionError *)error;

/// Opens the connection, falling back from WebSocket to SSE to long-poll.
/// Safe to call repeatedly.
///
/// Completes with the `ARTConnectionError` once the connection has failed,
/// including when the server rejected the credentials.
- (void)initiateSocket:(AuthenticationConfig *)credentials
            completion:(nullable void (^)(NSError *_Nullable error))completion;

/// Opens the WebSocket and emits `open`. The connection becomes active once
/// the server confirms it (`art_ready`).
///
/// Completes with an error when authentication fails. When the server
/// rejects the credentials (HTTP 401 or 403), or the forced token renewal of
/// a reconnect fails, the connection fails with
/// `ARTConnectionErrorCodeAuthenticationFailed` (emitting
/// `authenticationFailed` and `connectionFailed`) and the completion gets
/// that error, so no reconnect or fallback follows.
- (void)connectWebSocket:(void (^)(NSError *_Nullable error))completion;

/// Tears down the current transport. The connection state is reset before
/// the socket itself is closed. With `clearConnection` the subscription and
/// interceptor registries, and any buffered frames, are discarded too.
- (void)closeWebSocket:(BOOL)clearConnection
            completion:(nullable void (^)(void))completion;

/// Subscribes to `channel`, reusing an existing subscription.
///
/// Completes with the `ARTConnectionError` when the connection fails or a
/// reply does not arrive in time.
- (void)subscribe:(NSString *)channel
       completion:(void (^)(BaseSubscription *_Nullable subscription,
                            NSError *_Nullable error))completion;

- (void)intercept:(NSString *)interceptor
               fn:(void (^)(NSDictionary *request, void (^resolve)(id data),
                            void (^reject)(NSString *error)))fn
       completion:(void (^)(Interception *_Nullable interception,
                            NSError *_Nullable error))completion;

- (void)setAutoReconnect:(BOOL)flag;

/// Registers `handler` for `event`: `connection` (`ConnectionDetail`),
/// `open`, `close`, `error`, `limitExceeded`, `authenticationFailed`
/// (`ARTAuthenticationFailedDetail`) or `connectionFailed`
/// (`ARTConnectionError`).
- (NSUUID *)on:(NSString *)event handler:(void (^)(id data))handler;

- (void)off:(NSString *)event identifier:(NSUUID *)identifier;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_SOCKET_H */
