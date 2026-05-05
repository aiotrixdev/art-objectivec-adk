#ifndef ARTADK_CRDT_CRDTTYPES_H
#define ARTADK_CRDT_CRDTTYPES_H

#pragma once

//
//  CRDTTypes.h
//  ADK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class LDMap;
@class LDArray;
@class LDEntry;
@class LDMeta;

typedef NS_ENUM(NSInteger, LDValueType) {
    LDValueTypeString,
    LDValueTypeNumber,
    LDValueTypeBoolean,
    LDValueTypeMap,
    LDValueTypeArray,
    LDValueTypeNull
};

@interface LDValue : NSObject

@property(nonatomic, assign) LDValueType type;
@property(nonatomic, copy, nullable) NSString *stringValue;
@property(nonatomic, assign) double numberValue;
@property(nonatomic, assign) BOOL booleanValue;
@property(nonatomic, strong, nullable) LDMap *mapValue;
@property(nonatomic, strong, nullable) LDArray *arrayValue;

+ (LDValue *)stringValue:(NSString *)s;
+ (LDValue *)numberValue:(double)n;
+ (LDValue *)booleanValue:(BOOL)b;
+ (LDValue *)mapValue:(LDMap *)m;
+ (LDValue *)arrayValue:(LDArray *)a;
+ (LDValue *)nullValue;

@end

@interface LDMeta : NSObject

@property(nonatomic, assign) NSInteger updatedAt;
@property(nonatomic, assign) NSInteger version;
@property(nonatomic, copy) NSString *replicaId;
@property(nonatomic, strong, nullable) NSNumber *order;
@property(nonatomic, strong, nullable) NSNumber *tombstone;
@property(nonatomic, strong, nullable) id after;
@property(nonatomic, assign) BOOL afterIsSet;
@property(nonatomic, copy, nullable) NSString *next;

+ (LDMeta *)defaultMetaWithReplicaId:(NSString *)replicaId;

- (instancetype)init;
- (instancetype)initWithUpdatedAt:(NSInteger)updatedAt
                          version:(NSInteger)version
                        replicaId:(NSString *)replicaId
                            order:(nullable NSNumber *)order
                        tombstone:(nullable NSNumber *)tombstone
                            after:(nullable id)after
                       afterIsSet:(BOOL)afterIsSet
                             next:(nullable NSString *)next
    NS_DESIGNATED_INITIALIZER;

@end

typedef NS_ENUM(NSInteger, LDEntryType) {
    LDEntryTypeString,
    LDEntryTypeNumber,
    LDEntryTypeBoolean,
    LDEntryTypeObject,
    LDEntryTypeArray
};

@interface LDEntry : NSObject
@property(nonatomic, copy) NSString *entryId;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, assign) LDEntryType type;
@property(nonatomic, strong) LDValue *value;
@property(nonatomic, strong) LDMeta *meta;

- (instancetype)initWithId:(NSString *)entryId
                       key:(NSString *)key
                      type:(LDEntryType)type
                     value:(LDValue *)value
                      meta:(LDMeta *)meta NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface LDMap : NSObject

@property(nonatomic, strong) NSMutableDictionary<NSString *, LDEntry *> *index;
@property(nonatomic, strong) LDMeta *meta;

- (instancetype)init;
- (instancetype)initWithIndex:
                    (NSMutableDictionary<NSString *, LDEntry *> *)index
                         meta:(LDMeta *)meta NS_DESIGNATED_INITIALIZER;

@end

@interface LDArray : NSObject

@property(nonatomic, strong)
    NSMutableDictionary<NSString *, LDEntry *> *entries;
@property(nonatomic, copy, nullable) NSString *head;
@property(nonatomic, strong) LDMeta *meta;

- (instancetype)init;
- (instancetype)initWithEntries:
                    (NSMutableDictionary<NSString *, LDEntry *> *)entries
                           head:(nullable NSString *)head
                           meta:(LDMeta *)meta NS_DESIGNATED_INITIALIZER;

@end

typedef NS_ENUM(NSInteger, CRDTOperationType) {
    CRDTOperationTypeAdd,
    CRDTOperationTypeReplace,
    CRDTOperationTypeRemove,
    CRDTOperationTypeArrayPush,
    CRDTOperationTypeArrayUnshift,
    CRDTOperationTypeArrayRemove
};

@interface CRDTOperation : NSObject

@property(nonatomic, assign) CRDTOperationType operationType;
@property(nonatomic, strong) NSArray<NSString *> *path;
@property(nonatomic, strong, nullable) LDEntry *entry;
@property(nonatomic, assign) NSInteger timestamp;
@property(nonatomic, copy) NSString *replicaId;
@property(nonatomic, copy, nullable)
    NSString *ref; // for arrayPush / arrayRemove

+ (CRDTOperation *)addWithPath:(NSArray<NSString *> *)path
                         entry:(nullable LDEntry *)entry
                     timestamp:(NSInteger)ts
                     replicaId:(NSString *)rid;

+ (CRDTOperation *)replaceWithPath:(NSArray<NSString *> *)path
                             entry:(LDEntry *)entry
                         timestamp:(NSInteger)ts
                         replicaId:(NSString *)rid;

+ (CRDTOperation *)removeWithPath:(NSArray<NSString *> *)path
                        timestamp:(NSInteger)ts
                        replicaId:(NSString *)rid;

+ (CRDTOperation *)arrayPushWithPath:(NSArray<NSString *> *)path
                                 ref:(nullable NSString *)ref
                               entry:(LDEntry *)entry
                           timestamp:(NSInteger)ts
                           replicaId:(NSString *)rid;

+ (CRDTOperation *)arrayUnshiftWithPath:(NSArray<NSString *> *)path
                                  entry:(LDEntry *)entry
                              timestamp:(NSInteger)ts
                              replicaId:(NSString *)rid;

+ (CRDTOperation *)arrayRemoveWithPath:(NSArray<NSString *> *)path
                                   ref:(NSString *)ref
                             timestamp:(NSInteger)ts
                             replicaId:(NSString *)rid;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_CRDT_CRDTTYPES_H */
