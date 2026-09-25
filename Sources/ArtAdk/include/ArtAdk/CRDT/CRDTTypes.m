//
//  CRDTTypes.m
//  ADK
//

#import "CRDTTypes.h"

#pragma mark - LDValue

@implementation LDValue

+ (LDValue *)stringValue:(NSString *)s {
    LDValue *v = [[LDValue alloc] init];
    v.type = LDValueTypeString;
    v.stringValue = s;
    return v;
}

+ (LDValue *)numberValue:(double)n {
    LDValue *v = [[LDValue alloc] init];
    v.type = LDValueTypeNumber;
    v.numberValue = n;
    return v;
}

+ (LDValue *)booleanValue:(BOOL)b {
    LDValue *v = [[LDValue alloc] init];
    v.type = LDValueTypeBoolean;
    v.booleanValue = b;
    return v;
}

+ (LDValue *)mapValue:(LDMap *)m {
    LDValue *v = [[LDValue alloc] init];
    v.type = LDValueTypeMap;
    v.mapValue = m;
    return v;
}

+ (LDValue *)arrayValue:(LDArray *)a {
    LDValue *v = [[LDValue alloc] init];
    v.type = LDValueTypeArray;
    v.arrayValue = a;
    return v;
}

+ (LDValue *)nullValue {
    LDValue *v = [[LDValue alloc] init];
    v.type = LDValueTypeNull;
    return v;
}

- (NSString *)description {
    switch (self.type) {
    case LDValueTypeString:
        return
            [NSString stringWithFormat:@"LDValue.string(%@)", self.stringValue];
    case LDValueTypeNumber:
        return
            [NSString stringWithFormat:@"LDValue.number(%g)", self.numberValue];
    case LDValueTypeBoolean:
        return
            [NSString stringWithFormat:@"LDValue.boolean(%@)",
                                       self.booleanValue ? @"true" : @"false"];
    case LDValueTypeMap:
        return @"LDValue.map(...)";
    case LDValueTypeArray:
        return @"LDValue.array(...)";
    case LDValueTypeNull:
        return @"LDValue.null";
    }
}

@end

@implementation LDMeta

- (instancetype)init {
    return [self
        initWithUpdatedAt:(NSInteger)([[NSDate date] timeIntervalSince1970] *
                                      1000)
                  version:1
                replicaId:@"client"
                    order:nil
                tombstone:nil
                    after:nil
               afterIsSet:NO
                     next:nil];
}

- (instancetype)initWithUpdatedAt:(NSInteger)updatedAt
                          version:(NSInteger)version
                        replicaId:(NSString *)replicaId
                            order:(nullable NSNumber *)order
                        tombstone:(nullable NSNumber *)tombstone
                            after:(nullable id)after
                       afterIsSet:(BOOL)afterIsSet
                             next:(nullable NSString *)next {
    self = [super init];
    if (self) {
        _updatedAt = updatedAt;
        _version = version;
        _replicaId = [replicaId copy];
        _order = order;
        _tombstone = tombstone;
        _after = after;
        _afterIsSet = afterIsSet;
        _next = [next copy];
    }
    return self;
}

+ (LDMeta *)defaultMetaWithReplicaId:(NSString *)replicaId {
    return [[LDMeta alloc]
        initWithUpdatedAt:(NSInteger)([[NSDate date] timeIntervalSince1970] *
                                      1000)
                  version:1
                replicaId:replicaId
                    order:nil
                tombstone:nil
                    after:nil
               afterIsSet:NO
                     next:nil];
}

- (NSString *)description {
    return [NSString
        stringWithFormat:
            @"<LDMeta: updatedAt=%ld, v=%ld, replica=%@, tombstone=%@>",
            (long)_updatedAt, (long)_version, _replicaId, _tombstone];
}

@end

@implementation LDEntry

- (instancetype)initWithId:(NSString *)entryId
                       key:(NSString *)key
                      type:(LDEntryType)type
                     value:(LDValue *)value
                      meta:(LDMeta *)meta {
    self = [super init];
    if (self) {
        _entryId = [entryId copy];
        _key = [key copy];
        _type = type;
        _value = value;
        _meta = meta;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<LDEntry: id=%@, key=%@, type=%ld>",
                                      _entryId, _key, (long)_type];
}

@end

@implementation LDMap

- (instancetype)init {
    return [self initWithIndex:[NSMutableDictionary dictionary]
                          meta:[[LDMeta alloc] init]];
}

- (instancetype)initWithIndex:
                    (NSMutableDictionary<NSString *, LDEntry *> *)index
                         meta:(LDMeta *)meta {
    self = [super init];
    if (self) {
        _index = index;
        _meta = meta;
    }
    return self;
}

@end

@implementation LDArray

- (instancetype)init {
    return [self initWithEntries:[NSMutableDictionary dictionary]
                            head:nil
                            meta:[[LDMeta alloc] init]];
}

- (instancetype)initWithEntries:
                    (NSMutableDictionary<NSString *, LDEntry *> *)entries
                           head:(nullable NSString *)head
                           meta:(LDMeta *)meta {
    self = [super init];
    if (self) {
        _entries = entries;
        _head = [head copy];
        _meta = meta;
    }
    return self;
}

@end

@implementation CRDTOperation

+ (CRDTOperation *)addWithPath:(NSArray<NSString *> *)path
                         entry:(nullable LDEntry *)entry
                     timestamp:(NSInteger)ts
                     replicaId:(NSString *)rid {
    CRDTOperation *op = [[CRDTOperation alloc] init];
    op.operationType = CRDTOperationTypeAdd;
    op.path = path;
    op.entry = entry;
    op.timestamp = ts;
    op.replicaId = rid;
    return op;
}

+ (CRDTOperation *)replaceWithPath:(NSArray<NSString *> *)path
                             entry:(LDEntry *)entry
                         timestamp:(NSInteger)ts
                         replicaId:(NSString *)rid {
    CRDTOperation *op = [[CRDTOperation alloc] init];
    op.operationType = CRDTOperationTypeReplace;
    op.path = path;
    op.entry = entry;
    op.timestamp = ts;
    op.replicaId = rid;
    return op;
}

+ (CRDTOperation *)removeWithPath:(NSArray<NSString *> *)path
                        timestamp:(NSInteger)ts
                        replicaId:(NSString *)rid {
    CRDTOperation *op = [[CRDTOperation alloc] init];
    op.operationType = CRDTOperationTypeRemove;
    op.path = path;
    op.timestamp = ts;
    op.replicaId = rid;
    return op;
}

+ (CRDTOperation *)arrayPushWithPath:(NSArray<NSString *> *)path
                                 ref:(nullable NSString *)ref
                               entry:(LDEntry *)entry
                           timestamp:(NSInteger)ts
                           replicaId:(NSString *)rid {
    CRDTOperation *op = [[CRDTOperation alloc] init];
    op.operationType = CRDTOperationTypeArrayPush;
    op.path = path;
    op.ref = ref;
    op.entry = entry;
    op.timestamp = ts;
    op.replicaId = rid;
    return op;
}

+ (CRDTOperation *)arrayUnshiftWithPath:(NSArray<NSString *> *)path
                                  entry:(LDEntry *)entry
                              timestamp:(NSInteger)ts
                              replicaId:(NSString *)rid {
    CRDTOperation *op = [[CRDTOperation alloc] init];
    op.operationType = CRDTOperationTypeArrayUnshift;
    op.path = path;
    op.entry = entry;
    op.timestamp = ts;
    op.replicaId = rid;
    return op;
}

+ (CRDTOperation *)arrayRemoveWithPath:(NSArray<NSString *> *)path
                                   ref:(NSString *)ref
                             timestamp:(NSInteger)ts
                             replicaId:(NSString *)rid {
    CRDTOperation *op = [[CRDTOperation alloc] init];
    op.operationType = CRDTOperationTypeArrayRemove;
    op.path = path;
    op.ref = ref;
    op.timestamp = ts;
    op.replicaId = rid;
    return op;
}

- (NSString *)description {
    NSString *typeName;
    switch (self.operationType) {
    case CRDTOperationTypeAdd:
        typeName = @"add";
        break;
    case CRDTOperationTypeReplace:
        typeName = @"replace";
        break;
    case CRDTOperationTypeRemove:
        typeName = @"remove";
        break;
    case CRDTOperationTypeArrayPush:
        typeName = @"arrayPush";
        break;
    case CRDTOperationTypeArrayUnshift:
        typeName = @"arrayUnshift";
        break;
    case CRDTOperationTypeArrayRemove:
        typeName = @"arrayRemove";
        break;
    }
    return
        [NSString stringWithFormat:@"<CRDTOperation: %@ path=%@>", typeName,
                                   [self.path componentsJoinedByString:@"."]];
}

@end
