#ifndef ARTADK_AUTH_AUTH_H
#define ARTADK_AUTH_AUTH_H

#pragma once

//
//  Auth.h
//  ADK
//

#import <Foundation/Foundation.h>

@class AuthenticationConfig;
@class AuthData;
@class CredentialStore;

NS_ASSUME_NONNULL_BEGIN

@interface Auth : NSObject

+ (nullable Auth *)getInstance:(nullable AuthenticationConfig *)credentials
                         error:(NSError **)error;

+ (void)reset;

- (void)authenticate:(BOOL)forceAuth
          completion:(void (^)(AuthData *_Nullable data,
                               NSError *_Nullable error))completion;

- (AuthData *)getAuthData;

- (AuthenticationConfig *)getCredentials;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_AUTH_AUTH_H */
