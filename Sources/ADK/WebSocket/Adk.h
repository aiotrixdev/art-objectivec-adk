#ifndef ARTADK_WEBSOCKET_ADK_H
#define ARTADK_WEBSOCKET_ADK_H

#pragma once

//
//  Adk.h
//  ADK
//

#import <Foundation/Foundation.h>

@class Socket;
@class AdkConfig;
@class ConnectConfig;
@class ConnectionDetail;
@class KeyPairType;
@class BaseSubscription;
@class Interception;
@class CallApiProps;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AdkState) {
    AdkStatePaused,
    AdkStateConnected,
    AdkStateConnecting,
    AdkStateStopped
};

@interface Adk : NSObject

@property(nonatomic, strong, readonly) Socket *socket;

@property(nonatomic, strong, nullable) KeyPairType *myKeyPair;

@property(nonatomic, assign, readonly) AdkState state;

- (instancetype)initWithConfig:(nullable AdkConfig *)config;

- (void)connect:(nullable ConnectConfig *)config
     completion:(nullable void (^)(void))completion;

- (void)pause;

- (void)resume:(nullable void (^)(void))completion;

- (void)disconnect:(nullable void (^)(void))completion;

- (NSString *)getState;

- (NSUUID *)on:(NSString *)event handler:(void (^)(id data))handler;

- (void)off:(NSString *)event identifier:(NSUUID *)identifier;

- (void)subscribe:(NSString *)channel
       completion:(void (^)(BaseSubscription *_Nullable subscription,
                            NSError *_Nullable error))completion;

- (void)intercept:(NSString *)interceptor
               fn:(void (^)(NSDictionary *request, void (^resolve)(id data),
                            void (^reject)(NSString *error)))fn
       completion:(void (^)(Interception *_Nullable interception,
                            NSError *_Nullable error))completion;

- (void)closeWebSocket:(nullable void (^)(void))completion;

- (void)pushForSecureLine:(NSString *)event
                     data:(id)data
                   listen:(BOOL)listen
               completion:(void (^)(id _Nullable result,
                                    NSError *_Nullable error))completion;

- (void)generateKeyPair:(void (^)(KeyPairType *_Nullable keyPair,
                                  NSError *_Nullable error))completion;

- (void)setKeyPair:(KeyPairType *)keyPair
        completion:(void (^)(NSError *_Nullable error))completion;

- (void)encrypt:(NSString *)data
    recipientPublicKey:(NSString *)key
            completion:(void (^)(NSString *_Nullable encrypted,
                                 NSError *_Nullable error))completion;

- (void)decrypt:(NSString *)data
    senderPublicKey:(NSString *)key
         completion:(void (^)(NSString *_Nullable decrypted,
                              NSError *_Nullable error))completion;

- (void)callEndpoint:(NSString *)endpoint
             options:(CallApiProps *)options
          completion:(void (^)(id _Nullable result,
                               NSError *_Nullable error))completion;

- (void)onConnectedHook:(ConnectionDetail *)connection;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_ADK_H */
