//
//  Utils.m
//  ADK
//

#import "Utils.h"

NSString *const ErrorDomain = @"com.art.adk";

NSError *MakeError(ErrorCode code, NSString *message) {
    return
        [NSError errorWithDomain:ErrorDomain
                            code:code
                        userInfo:@{NSLocalizedDescriptionKey : message ?: @""}];
}

@implementation LDContainer

+ (LDContainer *)containerWithMap:(LDMap *)map {
    LDContainer *c = [[LDContainer alloc] init];
    c.kind = LDContainerKindMap;
    c.map = map;
    return c;
}

+ (LDContainer *)containerWithArray:(LDArray *)array {
    LDContainer *c = [[LDContainer alloc] init];
    c.kind = LDContainerKindArray;
    c.array = array;
    return c;
}

@end

static NSString *_Nullable FirstAfter(LDArray *arr, NSString *_Nullable after) {
    NSMutableArray<NSString *> *matching = [NSMutableArray array];
    for (NSString *entryId in arr.entries) {
        LDEntry *e = arr.entries[entryId];
        if (e.meta.afterIsSet) {
            if (after == nil) {
                if ([e.meta.after isEqual:[NSNull null]]) {
                    [matching addObject:entryId];
                }
            } else {
                if ([e.meta.after isKindOfClass:[NSString class]] &&
                    [e.meta.after isEqualToString:after]) {
                    [matching addObject:entryId];
                }
            }
        } else {
            if (after == nil) {
                [matching addObject:entryId];
            }
        }
    }
    [matching sortUsingSelector:@selector(compare:)];
    return matching.firstObject;
}

@implementation Utils

+ (NSString *)generateId {
    int64_t ts = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000);

    uint32_t upperBound = (uint32_t)pow(36.0, 6.0);
    uint32_t rand = arc4random_uniform(upperBound);

    NSMutableString *randStr = [NSMutableString string];
    uint32_t val = rand;
    if (val == 0) {
        [randStr appendString:@"0"];
    } else {
        static const char digits[] = "0123456789abcdefghijklmnopqrstuvwxyz";
        char buf[16];
        int pos = 15;
        buf[pos] = '\0';
        while (val > 0 && pos > 0) {
            pos--;
            buf[pos] = digits[val % 36];
            val /= 36;
        }
        [randStr appendFormat:@"%s", &buf[pos]];
    }

    return [NSString stringWithFormat:@"%lld-%@", (long long)ts, randStr];
}

+ (double)nowMs {
    return [[NSDate date] timeIntervalSince1970] * 1000;
}

+ (LDMeta *)defaultMetaWithReplicaId:(NSString *)replicaId {
    return [LDMeta defaultMetaWithReplicaId:replicaId];
}

+ (LDEntryType)determineType:(LDValue *)value {
    switch (value.type) {
    case LDValueTypeString:
        return LDEntryTypeString;
    case LDValueTypeNumber:
        return LDEntryTypeNumber;
    case LDValueTypeBoolean:
        return LDEntryTypeBoolean;
    case LDValueTypeArray:
        return LDEntryTypeArray;
    case LDValueTypeMap:
        return LDEntryTypeObject;
    case LDValueTypeNull:
        return LDEntryTypeObject;
    }
}

+ (LDValue *)toLDValue:(nullable id)value replicaId:(NSString *)replicaId {
    if (value == nil || [value isEqual:[NSNull null]]) {
        return [LDValue nullValue];
    }

    if ([value isKindOfClass:[NSString class]]) {
        return [LDValue stringValue:value];
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)value;
        const char *t = num.objCType;
        if (strcmp(t, @encode(BOOL)) == 0 || strcmp(t, @encode(char)) == 0) {
            return [LDValue booleanValue:num.boolValue];
        }
        return [LDValue numberValue:num.doubleValue];
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)value;
        LDMeta *arrMeta = [self defaultMetaWithReplicaId:replicaId];
        LDArray *ldArr =
            [[LDArray alloc] initWithEntries:[NSMutableDictionary dictionary]
                                        head:nil
                                        meta:arrMeta];
        NSString *prev = nil;
        for (id item in arr) {
            NSString *entryId = [self generateId];
            LDValue *ldVal = [self toLDValue:item replicaId:replicaId];
            LDMeta *m = [self defaultMetaWithReplicaId:replicaId];
            if (prev == nil) {
                m.after = [NSNull null]; // head position
            } else {
                m.after = prev;
            }
            m.afterIsSet = YES;

            LDEntry *entry =
                [[LDEntry alloc] initWithId:entryId
                                        key:entryId
                                       type:[self determineType:ldVal]
                                      value:ldVal
                                       meta:m];
            ldArr.entries[entryId] = entry;
            prev = entryId;
        }
        ldArr.head = FirstAfter(ldArr, nil);
        return [LDValue arrayValue:ldArr];
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)value;
        LDMeta *mapMeta = [self defaultMetaWithReplicaId:replicaId];
        LDMap *ldMap =
            [[LDMap alloc] initWithIndex:[NSMutableDictionary dictionary]
                                    meta:mapMeta];
        for (NSString *k in dict) {
            id val = dict[k];
            LDValue *ldVal;

            if ([val isKindOfClass:[NSString class]] ||
                [val isKindOfClass:[NSNumber class]]) {
                ldVal = [self toLDValue:val replicaId:replicaId];
            } else if ([val isKindOfClass:[NSDictionary class]]) {
                ldVal = [self toLDValue:val replicaId:replicaId];
            } else if ([val isKindOfClass:[NSArray class]]) {
                ldVal = [self toLDValue:val replicaId:replicaId];
            } else {
                ldVal = [LDValue nullValue];
            }

            LDEntry *entry = [[LDEntry alloc]
                initWithId:[self generateId]
                       key:k
                      type:[self determineType:ldVal]
                     value:ldVal
                      meta:[self defaultMetaWithReplicaId:replicaId]];
            ldMap.index[k] = entry;
        }
        return [LDValue mapValue:ldMap];
    }

    return [LDValue nullValue];
}

+ (LDValue *)toLDValue:(nullable id)value {
    return [self toLDValue:value replicaId:@"client"];
}

+ (LDMap *)fromAnyToLDMap:(nullable id)value {
    if (value == nil)
        return [[LDMap alloc] init];
    if ([value isKindOfClass:[LDMap class]])
        return value;

    LDValue *ldVal = [self toLDValue:value];
    if (ldVal.type == LDValueTypeMap) {
        return ldVal.mapValue;
    }
    return [[LDMap alloc] init];
}

+ (id)toAny:(LDValue *)value {
    switch (value.type) {
    case LDValueTypeString:
        return value.stringValue ?: @"";

    case LDValueTypeNumber:
        return @(value.numberValue);

    case LDValueTypeBoolean:
        return @(value.booleanValue);

    case LDValueTypeNull:
        return [NSNull null];

    case LDValueTypeMap: {
        LDMap *m = value.mapValue;
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (NSString *k in m.index) {
            LDEntry *e = m.index[k];
            out[k] = [self toAny:e.value];
        }
        return out;
    }

    case LDValueTypeArray: {
        LDArray *a = value.arrayValue;
        NSArray<NSString *> *ids = [self linearizeRGA:a];
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:ids.count];
        for (NSString *entryId in ids) {
            LDEntry *e = a.entries[entryId];
            if (e) {
                [out addObject:[self toAny:e.value]];
            }
        }
        return out;
    }
    }
}

+ (NSArray<NSString *> *)linearizeRGA:(LDArray *)arr {
    NSMutableDictionary<NSString *, NSMutableArray<LDEntry *> *> *afterToKids =
        [NSMutableDictionary dictionary];
    static NSString *const kNilKey = @"__art_nil_sentinel__";

    for (NSString *entryId in arr.entries) {
        LDEntry *e = arr.entries[entryId];
        NSString *afterKey;

        if (e.meta.afterIsSet) {
            if (e.meta.after == nil || [e.meta.after isEqual:[NSNull null]]) {
                afterKey = kNilKey;
            } else if ([e.meta.after isKindOfClass:[NSString class]]) {
                afterKey = e.meta.after;
            } else {
                afterKey = kNilKey;
            }
        } else {
            afterKey = kNilKey;
        }

        NSMutableArray *kids = afterToKids[afterKey];
        if (!kids) {
            kids = [NSMutableArray array];
            afterToKids[afterKey] = kids;
        }
        [kids addObject:e];
    }

    for (NSString *key in afterToKids) {
        [afterToKids[key] sortUsingComparator:^NSComparisonResult(LDEntry *a,
                                                                  LDEntry *b) {
          if (a.meta.updatedAt != b.meta.updatedAt) {
              return a.meta.updatedAt < b.meta.updatedAt ? NSOrderedAscending
                                                         : NSOrderedDescending;
          }
          NSComparisonResult rc = [a.meta.replicaId compare:b.meta.replicaId];
          if (rc != NSOrderedSame)
              return rc;
          return [a.entryId compare:b.entryId];
        }];
    }

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    // Iterative DFS walk using an explicit stack of child-iterators.
    // Avoids the __block/__weak self-referential block trap of the
    // original recursive closure.
    NSMutableArray<NSArray<LDEntry *> *> *stack = [NSMutableArray array];
    NSMutableArray<NSNumber *> *stackIndex = [NSMutableArray array];

    NSArray<LDEntry *> *rootKids = afterToKids[kNilKey];
    if (rootKids) {
        [stack addObject:rootKids];
        [stackIndex addObject:@(0)];
    }

    while (stack.count > 0) {
        NSArray<LDEntry *> *kids = stack.lastObject;
        NSUInteger i = stackIndex.lastObject.unsignedIntegerValue;

        if (i >= kids.count) {
            [stack removeLastObject];
            [stackIndex removeLastObject];
            continue;
        }

        // Advance parent iterator first so siblings are visited after
        // we finish the current child's subtree.
        stackIndex[stackIndex.count - 1] = @(i + 1);

        LDEntry *e = kids[i];
        if ([seen containsObject:e.entryId]) {
            continue;
        }
        [seen addObject:e.entryId];
        if (e.meta.tombstone == nil || ![e.meta.tombstone boolValue]) {
            [out addObject:e.entryId];
        }

        NSArray<LDEntry *> *childKids = afterToKids[e.entryId];
        if (childKids) {
            [stack addObject:childKids];
            [stackIndex addObject:@(0)];
        }
    }

    return [out copy];
}

+ (nullable LDContainer *)toContainer:(LDValue *)value error:(NSError **)error {
    if (value.type == LDValueTypeMap) {
        return [LDContainer containerWithMap:value.mapValue];
    }
    if (value.type == LDValueTypeArray) {
        return [LDContainer containerWithArray:value.arrayValue];
    }
    if (error) {
        *error = MakeError(ErrorCodeInvalidPath, @"Value is not a container");
    }
    return nil;
}

@end
