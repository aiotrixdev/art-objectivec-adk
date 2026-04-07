//
//  Socket.h
//  ADK
//

#import "../Types/SocketTypes.h"
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

@property(nonatomic, assign) BOOL isConnectionActive;

@property(nonatomic, assign) BOOL isReConnecting;

+ (Socket *)getInstance:(EncryptBlock)encrypt
                           decrypt:(DecryptBlock)decrypt;

/// Release the shared Socket instance so the next call to
/// +getInstance:decrypt: creates a fresh one. Typically used by tests
/// or when an app wants to fully tear down and re-init the SDK.
+ (void)reset;

- (void)initiateSocket:(AuthenticationConfig *)credentials
            completion:(nullable void (^)(NSError *_Nullable error))completion;

- (void)connectWebSocket:(void (^)(NSError *_Nullable error))completion;

- (void)closeWebSocket:(BOOL)clearConnection
            completion:(nullable void (^)(void))completion;

- (void)subscribe:(NSString *)channel
       completion:(void (^)(BaseSubscription *_Nullable subscription,
                            NSError *_Nullable error))completion;

- (void)intercept:(NSString *)interceptor
               fn:(void (^)(NSDictionary *request, void (^resolve)(id data),
                            void (^reject)(NSString *error)))fn
       completion:(void (^)(Interception *_Nullable interception,
                            NSError *_Nullable error))completion;

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

- (NSUUID *)on:(NSString *)event handler:(void (^)(id data))handler;

- (void)off:(NSString *)event identifier:(NSUUID *)identifier;

- (void)setAutoReconnect:(BOOL)flag;

@end

NS_ASSUME_NONNULL_END
