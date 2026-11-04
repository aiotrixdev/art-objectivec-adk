#ifndef ARTADK_TYPES_SOCKETTYPES_H
#define ARTADK_TYPES_SOCKETTYPES_H

#pragma once

//
//  SocketTypes.h
//  ADK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ConnectionDetail;
@class ARTConnectionError;
@class ARTMediaRef;

#pragma mark - Connection errors

/// Domain of `ARTConnectionError`.
FOUNDATION_EXPORT NSErrorDomain const ARTConnectionErrorDomain;
/// `userInfo` key with an `ARTConnectionError`'s code string.
FOUNDATION_EXPORT NSErrorUserInfoKey const ARTConnectionErrorCodeKey;

/// Why a connection failed. Values the SDK doesn't know yet are kept as
/// their raw server value.
typedef NSString *ARTConnectionErrorCode NS_TYPED_EXTENSIBLE_ENUM;
/// `CONNECTION_TIMEOUT`: the connection or a control request did not become
/// ready in time.
FOUNDATION_EXPORT ARTConnectionErrorCode const ARTConnectionErrorCodeTimeout;
/// `CONNECTION_LOST`: the connection dropped before a message could be sent,
/// or could not be restored.
FOUNDATION_EXPORT ARTConnectionErrorCode const ARTConnectionErrorCodeLost;
/// `CONNECTION_PAUSED`: the app paused the connection.
FOUNDATION_EXPORT ARTConnectionErrorCode const ARTConnectionErrorCodePaused;
/// `CONNECTION_CLOSED`: the app closed the connection.
FOUNDATION_EXPORT ARTConnectionErrorCode const ARTConnectionErrorCodeClosed;
/// `CONNECTION_CANCELLED`: a newer connection attempt replaced this one.
FOUNDATION_EXPORT ARTConnectionErrorCode const ARTConnectionErrorCodeCancelled;
/// `CONNECTION_AUTHORIZATION_FAILED`: the connection's authorisation could
/// not be renewed.
FOUNDATION_EXPORT ARTConnectionErrorCode const ARTConnectionErrorCodeAuthorizationFailed;
/// `AUTHENTICATION_FAILED`: the credentials are missing or were rejected
/// (`status` holds the HTTP status when the server rejected them).
FOUNDATION_EXPORT ARTConnectionErrorCode const ARTConnectionErrorCodeAuthenticationFailed;
/// `ACK_TIMEOUT`: the server did not acknowledge a message.
FOUNDATION_EXPORT ARTConnectionErrorCode const ARTConnectionErrorCodeAckTimeout;
/// `CONNECTION_MINUTES_LIMIT_EXCEEDED`: a server billing limit was reached.
FOUNDATION_EXPORT ARTConnectionErrorCode const ARTConnectionErrorCodeMinutesLimitExceeded;
/// `CONCURRENT_LIMIT_EXCEEDED`: a server concurrency limit was reached.
FOUNDATION_EXPORT ARTConnectionErrorCode const ARTConnectionErrorCodeConcurrentLimitExceeded;

/// A failure of the client's connection to the ART server.
///
/// It does not mean that a server-side execution failed: once the client is
/// disconnected it cannot tell whether a submitted request completed.
///
/// Delivered by the `connectionFailed` event, and returned by connection
/// waits, sends and control requests once the connection has failed. After
/// a failure the SDK stops reconnecting on its own; fix the cause and call
/// `-[Adk connect:completion:]` again.
@interface ARTConnectionError : NSError

/// Machine-readable reason, e.g. `CONNECTION_LOST`.
@property(nonatomic, copy, readonly) ARTConnectionErrorCode connectionCode;
/// Readable description of the failure; same as `localizedDescription`.
@property(nonatomic, copy, readonly) NSString *message;
/// HTTP status behind the failure, when there was one.
@property(nonatomic, strong, readonly, nullable) NSNumber *status;

+ (instancetype)errorWithMessage:(NSString *)message
                            code:(ARTConnectionErrorCode)code
                          status:(nullable NSNumber *)status;

+ (instancetype)errorWithMessage:(NSString *)message
                            code:(ARTConnectionErrorCode)code;

@end

/// Payload of the `authenticationFailed` event.
///
/// Emitted when the server rejects the credentials, or when a token renewal
/// fails while reconnecting or while renewing the connection's
/// authorisation. Automatic reconnection stops; update the credentials and
/// call `-[Adk connect:completion:]` again.
@interface ARTAuthenticationFailedDetail : NSObject

/// HTTP status of the rejection (401 or 403), or 0 when the failure was not
/// a credential rejection (for example a network error).
@property(nonatomic, assign, readonly) NSInteger status;
/// Readable description of the failure.
@property(nonatomic, copy, readonly) NSString *error;

- (instancetype)initWithStatus:(NSInteger)status
                         error:(NSString *)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/// Where an agent or orchestrator request was started, sent as
/// `execution_origin`.
typedef NSString *ARTExecutionOrigin NS_TYPED_EXTENSIBLE_ENUM;
/// The request comes from the ART playground.
FOUNDATION_EXPORT ARTExecutionOrigin const ARTExecutionOriginPlayground;

@interface ConnectionDetail : NSObject

@property(nonatomic, copy) NSString *connectionId;
@property(nonatomic, copy) NSString *instanceId;
@property(nonatomic, copy) NSString *tenantName;
@property(nonatomic, copy) NSString *environment;
@property(nonatomic, copy) NSString *projectKey;

- (instancetype)initWithConnectionId:(NSString *)connectionId
                          instanceId:(NSString *)instanceId
                          tenantName:(NSString *)tenantName
                         environment:(NSString *)environment
                          projectKey:(NSString *)projectKey
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/// Per-message options for `push`.
@interface PushConfig : NSObject <NSCopying>

@property(nonatomic, strong) NSArray<NSString *> *to;
/// Thread id sent as the frame's top-level `thread_id`, so the server can
/// route the message to a logical thread. Set by `AgentThread` and
/// `OrchestratorThread`.
@property(nonatomic, copy, nullable) NSString *threadID;
/// Files the request refers to, sent as the frame's top-level `file_meta`.
/// Empty by default.
@property(nonatomic, copy) NSArray<ARTMediaRef *> *fileMeta;
/// Where the request was started, sent as `execution_origin`. Leave it nil
/// for ordinary requests.
@property(nonatomic, copy, nullable) ARTExecutionOrigin executionOrigin;

- (instancetype)init;
- (instancetype)initWithTo:(NSArray<NSString *> *)to NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithTo:(NSArray<NSString *> *)to
                  threadID:(nullable NSString *)threadID;
- (instancetype)initWithTo:(NSArray<NSString *> *)to
                  threadID:(nullable NSString *)threadID
                  fileMeta:(nullable NSArray<ARTMediaRef *> *)fileMeta;
- (instancetype)initWithTo:(NSArray<NSString *> *)to
                  threadID:(nullable NSString *)threadID
                  fileMeta:(nullable NSArray<ARTMediaRef *> *)fileMeta
           executionOrigin:(nullable ARTExecutionOrigin)executionOrigin;

@end

/// Options for REST calls (`-[Adk callEndpoint:options:completion:]`).
@interface CallApiProps : NSObject

@property(nonatomic, copy) NSString *method;
/// Request body. An `ARTFormDataPayload` is sent as `multipart/form-data`;
/// anything else is encoded as JSON.
@property(nonatomic, strong, nullable) id payload;
@property(nonatomic, strong, nullable)
    NSDictionary<NSString *, NSString *> *queryParams;
@property(nonatomic, strong, nullable)
    NSDictionary<NSString *, NSString *> *headers;
/// Host to call instead of the default ART gateway, e.g.
/// `https://example.com`. The endpoint path is appended to it.
@property(nonatomic, copy, nullable) NSString *baseUrl;
/// Request timeout in milliseconds.
@property(nonatomic, strong, nullable) NSNumber *timeoutMs;

- (instancetype)init;
- (instancetype)
    initWithMethod:(NSString *)method
           payload:(nullable id)payload
       queryParams:(nullable NSDictionary<NSString *, NSString *> *)queryParams
           headers:(nullable NSDictionary<NSString *, NSString *> *)headers
    NS_DESIGNATED_INITIALIZER;
- (instancetype)
    initWithMethod:(NSString *)method
           payload:(nullable id)payload
       queryParams:(nullable NSDictionary<NSString *, NSString *> *)queryParams
           headers:(nullable NSDictionary<NSString *, NSString *> *)headers
           baseUrl:(nullable NSString *)baseUrl
         timeoutMs:(nullable NSNumber *)timeoutMs;

@end

/// A file part of an `ARTFormDataPayload`.
@interface ARTFormDataFile : NSObject

/// Form field name.
@property(nonatomic, copy, readonly) NSString *field;
/// File contents.
@property(nonatomic, copy, readonly) NSData *data;
/// File name sent with the part.
@property(nonatomic, copy, readonly) NSString *filename;
/// MIME type of the part; `application/octet-stream` when nil.
@property(nonatomic, copy, readonly, nullable) NSString *contentType;

- (instancetype)initWithField:(NSString *)field
                         data:(NSData *)data
                     filename:(NSString *)filename
                  contentType:(nullable NSString *)contentType
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/// A `multipart/form-data` request body for `CallApiProps.payload`.
@interface ARTFormDataPayload : NSObject

/// Text fields of the form.
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *fields;
/// File parts of the form.
@property(nonatomic, copy) NSArray<ARTFormDataFile *> *files;

- (instancetype)init;
- (instancetype)initWithFields:(nullable NSDictionary<NSString *, NSString *> *)fields
                         files:(nullable NSArray<ARTFormDataFile *> *)files
    NS_DESIGNATED_INITIALIZER;

@end

/// Fields for `-[Adk updateProfile:completion:]`. Only the fields you set
/// are sent.
@interface ARTUpdateProfileData : NSObject

@property(nonatomic, copy, nullable) NSString *firstName;
@property(nonatomic, copy, nullable) NSString *lastName;
@property(nonatomic, copy, nullable) NSString *email;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *attributes;

/// The request body: `first_name`, `last_name`, `email` and `attributes`,
/// each only when set.
- (NSDictionary<NSString *, id> *)payload;

@end

@interface LongPollOptions : NSObject

@property(nonatomic, copy) NSString *endpoint;
@property(nonatomic, copy, nullable) NSString *initialConnectionId;
@property(nonatomic, copy) void (^getAuthHeaders)
    (void (^completion)(NSDictionary<NSString *, NSString *> *_Nullable headers,
                        NSError *_Nullable error));
@property(nonatomic, copy) void (^onMessages)(NSArray *messages);
/// Called with a failed poll's error. An `ARTAuthHttpError` for rejected
/// credentials (HTTP 401 or 403) stops the poll loop.
@property(nonatomic, copy, nullable) void (^onError)(NSError *error);
/// Called after every poll the server answered, with or without messages.
@property(nonatomic, copy, nullable) void (^onResponse)(void);
@property(nonatomic, assign) NSInteger retryDelayMs;
@property(nonatomic, assign) NSInteger emptyPollDelayMs;
@property(nonatomic, assign) NSInteger maxEmptyPollDelayMs;

- (instancetype)initWithEndpoint:(NSString *)endpoint
             initialConnectionId:(nullable NSString *)initialConnectionId
                  getAuthHeaders:
                      (void (^)(void (^completion)(
                          NSDictionary<NSString *, NSString *> *_Nullable,
                          NSError *_Nullable)))getAuthHeaders
                      onMessages:(void (^)(NSArray *messages))onMessages
                         onError:(nullable void (^)(NSError *error))onError
                    retryDelayMs:(NSInteger)retryDelayMs
                emptyPollDelayMs:(NSInteger)emptyPollDelayMs
             maxEmptyPollDelayMs:(NSInteger)maxEmptyPollDelayMs
    NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithEndpoint:(NSString *)endpoint
                  getAuthHeaders:
                      (void (^)(void (^completion)(
                          NSDictionary<NSString *, NSString *> *_Nullable,
                          NSError *_Nullable)))getAuthHeaders
                      onMessages:(void (^)(NSArray *messages))onMessages;

- (instancetype)init NS_UNAVAILABLE;

@end

@protocol WebsocketHandler <NSObject>

/// Completes once the connection is ready, or with the `ARTConnectionError`
/// once the connection has failed. A wait that outlasts
/// `AdkConfig.connectionTimeoutMs` fails the connection with
/// `ARTConnectionErrorCodeTimeout`.
- (void)wait:(void (^)(NSError *_Nullable error))completion;

/// Makes sure the server authorises the connection with the current access
/// token before a channel operation: renews the token when it is about to
/// expire and, when it changed, renews the connection's authorisation.
/// Completes with an error when the token cannot be renewed or the server
/// rejects it; a rejection also stops automatic reconnection.
- (void)ensureAuthorization:(void (^)(NSError *_Nullable error))completion;

/// Sends a raw JSON frame. Messages are never queued for replay: returns NO
/// and sets `error` to an `ARTConnectionError`
/// (`ARTConnectionErrorCodeLost`, or the failure that ended the connection)
/// when there is no connection to send on.
- (BOOL)sendMessage:(NSString *)message error:(NSError **)error;

- (nullable ConnectionDetail *)getConnection;

- (void)encryptData:(NSString *)data
    recipientPublicKey:(NSString *)key
            completion:(void (^)(NSString *_Nullable encrypted,
                                 NSError *_Nullable error))completion;

- (void)decryptData:(NSString *)data
    senderPublicKey:(NSString *)key
         completion:(void (^)(NSString *_Nullable decrypted,
                              NSError *_Nullable error))completion;

/// Sends a request on the internal `art_secure` line once the connection is
/// ready. With `listen`, completes with the server's reply, or with an
/// `ARTConnectionError` (`ARTConnectionErrorCodeTimeout` when no reply
/// arrives within `AdkConfig.connectionTimeoutMs`, or the failure that ends
/// the connection meanwhile).
- (void)pushForSecureLine:(NSString *)event
                     data:(id)data
                   listen:(BOOL)listen
               completion:(void (^)(id _Nullable result,
                                    NSError *_Nullable error))completion;

- (void)removeSubscription:(NSString *)channel;

/// Calls `listener` when the connection fails (the `connectionFailed`
/// event). Returns an id for `offConnectionFailure:`.
- (NSUUID *)onConnectionFailure:(void (^)(ARTConnectionError *error))listener;

/// Removes a listener added with `onConnectionFailure:`.
- (void)offConnectionFailure:(NSUUID *)identifier;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_TYPES_SOCKETTYPES_H */
