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
@class ARTFileMeta;

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
/// Uploaded files attached to the message, sent as the frame's top-level
/// `file_meta`. Empty by default.
@property(nonatomic, copy) NSArray<ARTFileMeta *> *fileMeta;

- (instancetype)init;
- (instancetype)initWithTo:(NSArray<NSString *> *)to NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithTo:(NSArray<NSString *> *)to
                  threadID:(nullable NSString *)threadID;
- (instancetype)initWithTo:(NSArray<NSString *> *)to
                  threadID:(nullable NSString *)threadID
                  fileMeta:(nullable NSArray<ARTFileMeta *> *)fileMeta;

@end

/// Options for REST calls (`-[Adk callEndpoint:options:completion:]`).
@interface CallApiProps : NSObject

@property(nonatomic, copy) NSString *method;
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
@property(nonatomic, copy, nullable) void (^onError)(NSError *error);
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

- (void)wait:(void (^)(void))completion;

- (BOOL)sendMessage:(NSString *)message;

- (nullable ConnectionDetail *)getConnection;

- (void)encryptData:(NSString *)data
    recipientPublicKey:(NSString *)key
            completion:(void (^)(NSString *_Nullable encrypted,
                                 NSError *_Nullable error))completion;

- (void)decryptData:(NSString *)data
    senderPublicKey:(NSString *)key
         completion:(void (^)(NSString *_Nullable decrypted,
                              NSError *_Nullable error))completion;

- (void)pushForSecureLine:(NSString *)event
                     data:(id)data
                   listen:(BOOL)listen
               completion:(void (^)(id _Nullable result,
                                    NSError *_Nullable error))completion;

- (void)removeSubscription:(NSString *)channel;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_TYPES_SOCKETTYPES_H */
