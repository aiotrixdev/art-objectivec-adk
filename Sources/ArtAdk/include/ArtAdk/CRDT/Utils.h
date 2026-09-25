#ifndef ARTADK_CRDT_UTILS_H
#define ARTADK_CRDT_UTILS_H

#pragma once

//
//  CRDTUtils.h
//  ADK
//

#import "CRDTTypes.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const ErrorDomain;

typedef NS_ENUM(NSInteger, ErrorCode) {
    ErrorCodeForbidden = 1000,
    ErrorCodeAuthenticationFailed,
    ErrorCodeInvalidPath,
    ErrorCodeNotConnected,
    ErrorCodeEncryptionError,
    ErrorCodeDecryptionError,
    ErrorCodeTimeout,
    ErrorCodeServerError,
    ErrorCodeChannelNotFound,
    ErrorCodeAckTimeout,
};

NSError *MakeError(ErrorCode code, NSString *message);

typedef NS_ENUM(NSInteger, LDContainerKind) {
    LDContainerKindMap,
    LDContainerKindArray,
};

@interface LDContainer : NSObject
@property(nonatomic, assign) LDContainerKind kind;
@property(nonatomic, strong, nullable) LDMap *map;
@property(nonatomic, strong, nullable) LDArray *array;
+ (LDContainer *)containerWithMap:(LDMap *)map;
+ (LDContainer *)containerWithArray:(LDArray *)array;
@end

@interface Utils : NSObject

/// Generates a timestamp-random base-36 identifier.
+ (NSString *)generateId;

+ (double)nowMs;

+ (LDMeta *)defaultMetaWithReplicaId:(NSString *)replicaId;

+ (LDEntryType)determineType:(LDValue *)value;

+ (LDValue *)toLDValue:(nullable id)value replicaId:(NSString *)replicaId;

+ (LDValue *)toLDValue:(nullable id)value;

+ (LDMap *)fromAnyToLDMap:(nullable id)value;

+ (id)toAny:(LDValue *)value;

+ (NSArray<NSString *> *)linearizeRGA:(LDArray *)arr;

+ (nullable LDContainer *)toContainer:(LDValue *)value error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_CRDT_UTILS_H */
