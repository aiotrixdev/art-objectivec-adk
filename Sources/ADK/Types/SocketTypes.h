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

@interface PushConfig : NSObject

@property(nonatomic, strong) NSArray<NSString *> *to;

- (instancetype)init;
- (instancetype)initWithTo:(NSArray<NSString *> *)to NS_DESIGNATED_INITIALIZER;

@end

@interface CallApiProps : NSObject

@property(nonatomic, copy) NSString *method;
@property(nonatomic, strong, nullable) id payload;
@property(nonatomic, strong, nullable)
    NSDictionary<NSString *, NSString *> *queryParams;
@property(nonatomic, strong, nullable)
    NSDictionary<NSString *, NSString *> *headers;

- (instancetype)init;
- (instancetype)
    initWithMethod:(NSString *)method
           payload:(nullable id)payload
       queryParams:(nullable NSDictionary<NSString *, NSString *> *)queryParams
           headers:(nullable NSDictionary<NSString *, NSString *> *)headers
    NS_DESIGNATED_INITIALIZER;

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
