#ifndef ARTADK_TYPES_CRYPTOTYPES_H
#define ARTADK_TYPES_CRYPTOTYPES_H

#pragma once

//
//  CryptoTypes.h
//  ADK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KeyPairType : NSObject

@property(nonatomic, copy) NSString *publicKey;
@property(nonatomic, copy) NSString *privateKey;

- (instancetype)initWithPublicKey:(NSString *)publicKey
                       privateKey:(NSString *)privateKey
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_TYPES_CRYPTOTYPES_H */
