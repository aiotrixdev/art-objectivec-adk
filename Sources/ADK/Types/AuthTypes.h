#ifndef ARTADK_TYPES_AUTHTYPES_H
#define ARTADK_TYPES_AUTHTYPES_H

#pragma once

//
//  AuthTypes.h
//  ADK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class CredentialStore;
@class AdkConfig;

@interface AdkConfig : NSObject

@property(nonatomic, copy) NSString *uri;
@property(nonatomic, copy, nullable) NSString *authToken;
@property(nonatomic, copy, nullable) CredentialStore *_Nonnull (^getCredentials)
    (void);
@property(nonatomic, copy, nullable) NSString *root;

- (instancetype)initWithUri:(NSString *)uri;
- (instancetype)initWithUri:(NSString *)uri
                  authToken:(nullable NSString *)authToken
             getCredentials:
                 (nullable CredentialStore *_Nonnull (^)(void))getCredentials
                       root:(nullable NSString *)root NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface CredentialStore : NSObject

@property(nonatomic, copy) NSString *environment;
@property(nonatomic, copy) NSString *projectKey;
@property(nonatomic, copy) NSString *orgTitle;
@property(nonatomic, copy) NSString *clientID;
@property(nonatomic, copy) NSString *clientSecret;
@property(nonatomic, strong, nullable) AdkConfig *config;
@property(nonatomic, copy, nullable) NSString *accessToken;

- (instancetype)init;
- (instancetype)initWithEnvironment:(NSString *)environment
                         projectKey:(NSString *)projectKey
                           orgTitle:(NSString *)orgTitle
                           clientID:(NSString *)clientID
                       clientSecret:(NSString *)clientSecret
                             config:(nullable AdkConfig *)config
                        accessToken:(nullable NSString *)accessToken
    NS_DESIGNATED_INITIALIZER;

@end

@interface AuthenticationConfig : NSObject

@property(nonatomic, copy) NSString *environment;
@property(nonatomic, copy) NSString *projectKey;
@property(nonatomic, copy) NSString *orgTitle;
@property(nonatomic, copy) NSString *clientID;
@property(nonatomic, copy) NSString *clientSecret;
@property(nonatomic, strong, nullable) AdkConfig *config;
@property(nonatomic, copy, nullable) NSString *accessToken;
@property(nonatomic, copy, nullable) CredentialStore *_Nonnull (^getCredentials)
    (void);

- (instancetype)init;
- (instancetype)initWithEnvironment:(NSString *)environment
                         projectKey:(NSString *)projectKey
                           orgTitle:(NSString *)orgTitle
                           clientID:(NSString *)clientID
                       clientSecret:(NSString *)clientSecret
                             config:(nullable AdkConfig *)config
                        accessToken:(nullable NSString *)accessToken
                     getCredentials:
                         (nullable CredentialStore *_Nonnull (^)(void))
                             getCredentials NS_DESIGNATED_INITIALIZER;

@end

@interface AuthData : NSObject

@property(nonatomic, copy) NSString *accessToken;
@property(nonatomic, copy) NSString *refreshToken;

- (instancetype)init;
- (instancetype)initWithAccessToken:(NSString *)accessToken
                       refreshToken:(NSString *)refreshToken
    NS_DESIGNATED_INITIALIZER;

@end

@interface ConnectConfig : NSObject

@property(nonatomic, assign) BOOL restoreConnection;

- (instancetype)init;
- (instancetype)initWithRestoreConnection:(BOOL)restoreConnection
    NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_TYPES_AUTHTYPES_H */
