//
//  LiveObjSubscription.m
//  ADK
//

#import "LiveObjSubscription.h"

static NSArray<NSDictionary *> *SerializeOps(NSArray<CRDTOperation *> *ops);
static NSDictionary *SerializeEntry(LDEntry *entry);
static NSDictionary *SerializeMeta(LDMeta *meta);
static id SerializeValue(LDValue *value, NSString *replicaId);
static NSArray<CRDTOperation *> *DeserializeOps(NSArray<NSDictionary *> *dOps);
static LDEntry *DeserializeEntry(NSDictionary *dEntry);

static NSString *EntryTypeToString(LDEntryType type) {
    switch (type) {
    case LDEntryTypeString:
        return @"string";
    case LDEntryTypeNumber:
        return @"number";
    case LDEntryTypeBoolean:
        return @"boolean";
    case LDEntryTypeObject:
        return @"object";
    case LDEntryTypeArray:
        return @"array";
    }
    return @"object";
}

static LDEntryType EntryTypeFromString(NSString *str) {
    if ([str isEqualToString:@"string"])
        return LDEntryTypeString;
    if ([str isEqualToString:@"number"])
        return LDEntryTypeNumber;
    if ([str isEqualToString:@"boolean"])
        return LDEntryTypeBoolean;
    if ([str isEqualToString:@"array"])
        return LDEntryTypeArray;
    return LDEntryTypeObject;
}

@implementation LiveObjSubscription

- (instancetype)initWithConnectionID:(NSString *)connectionID
                       channelConfig:(ChannelConfig *)channelConfig
                    websocketHandler:(id<WebsocketHandler>)websocketHandler
                             process:(NSString *)process {

    LDMap *snapshotMap;
    if (channelConfig.snapshot) {
        snapshotMap = [Utils fromAnyToLDMap:channelConfig.snapshot];
    } else {
        snapshotMap = [[LDMap alloc] init];
    }

    CRDT *crdtInstance =
        [[CRDT alloc] initWithInitial:snapshotMap
                        mergeCallback:^(NSArray<CRDTOperation *> *ops){
                        }];

    NSString *replicaId = [NSString
        stringWithFormat:@"r-%@",
                         [[[NSUUID UUID] UUIDString] substringToIndex:8]
                             .lowercaseString];
    [crdtInstance setReplicaId:replicaId];

    self = [super initWithConnectionID:connectionID
                         channelConfig:channelConfig
                      websocketHandler:websocketHandler
                               process:process];

    if (self) {
        _crdt = crdtInstance;

        __weak typeof(self) weakSelf = self;
        [_crdt setMergeCallback:^(NSArray<CRDTOperation *> *ops) {
          [weakSelf executeServerMerge:ops];
        }];
    }
    return self;
}

- (CRDTProxy *)state {
    return [_crdt state];
}

- (void)flush:(void (^)(void))completion {
    [_crdt flush:completion];
}

- (CRDTQueryHandle *)query:(NSString *)path {
    return [_crdt queryWithPath:path];
}

- (void)executeServerMerge:(NSArray<CRDTOperation *> *)ops {
    if (ops.count == 0)
        return;
    if ([self.websocketHandler getConnection] == nil)
        return;

    NSArray<NSDictionary *> *serializedOps = SerializeOps(ops);

    __weak typeof(self) weakSelf = self;
    [self
         pushArray:@"merge"
              data:serializedOps
        completion:^(NSError *error) {
          if (error) {
    
          }
          (void)weakSelf;
        }];
}

- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload {

    NSString *returnFlag = payload[@"return_flag"];
    if ([returnFlag isKindOfClass:[NSString class]] &&
        [returnFlag isEqualToString:@"SA"]) {
        return;
    }

    if ([event isEqualToString:@"art_presence"]) {
        id content = payload[@"data"];
        if (content) {
            [self.emitter emit:@"art_presence" data:content];
        }
        return;
    }

    // Match the web protocol exactly.
    if (event.length > 0 && ![event isEqualToString:@"merge"] &&
        ![event isEqualToString:@"update"]) {
        return;
    }

    id rawContent = payload[@"data"] ?: payload[@"content"];
    if (!rawContent)
        return;

    NSArray<NSDictionary *> *rawOps = nil;

    if ([rawContent isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)rawContent;
        if (arr.count == 0 ||
            [arr.firstObject isKindOfClass:[NSDictionary class]]) {
            rawOps = (NSArray<NSDictionary *> *)arr;
        }
    } else if ([rawContent isKindOfClass:[NSString class]]) {
        NSData *jsonData =
            [(NSString *)rawContent dataUsingEncoding:NSUTF8StringEncoding];
        if (jsonData) {
            id parsed = [NSJSONSerialization JSONObjectWithData:jsonData
                                                        options:0
                                                          error:nil];

            if ([parsed isKindOfClass:[NSArray class]]) {
                rawOps = (NSArray<NSDictionary *> *)parsed;
            } else if ([parsed isKindOfClass:[NSString class]]) {
                NSData *innerData =
                    [(NSString *)parsed dataUsingEncoding:NSUTF8StringEncoding];
                if (innerData) {
                    id innerParsed =
                        [NSJSONSerialization JSONObjectWithData:innerData
                                                        options:0
                                                          error:nil];
                    if ([innerParsed isKindOfClass:[NSArray class]]) {
                        rawOps = (NSArray<NSDictionary *> *)innerParsed;
                    }
                }
            }
        }
    }

    if (!rawOps) {
        return;
    }

    NSArray<CRDTOperation *> *ops = DeserializeOps(rawOps);
    if (ops.count == 0)
        return;

    NSString *myReplica = [_crdt getReplicaId];

    NSMutableArray<CRDTOperation *> *filtered = [NSMutableArray array];
    for (CRDTOperation *op in ops) {
        if (![op.replicaId isEqualToString:myReplica]) {
            [filtered addObject:op];
        }
    }

    if (filtered.count == 0)
        return;

    [_crdt merge:filtered];
}

@end

static NSArray<NSDictionary *> *SerializeOps(NSArray<CRDTOperation *> *ops) {
    NSMutableArray<NSDictionary *> *result =
        [NSMutableArray arrayWithCapacity:ops.count];

    for (CRDTOperation *op in ops) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"path"] = op.path;
        d[@"timestamp"] = @(op.timestamp);
        d[@"replicaId"] = op.replicaId;

        switch (op.operationType) {
        case CRDTOperationTypeAdd:
            d[@"op"] = @"add";
            if (op.entry)
                d[@"entry"] = SerializeEntry(op.entry);
            break;

        case CRDTOperationTypeReplace:
            d[@"op"] = @"replace";
            if (op.entry)
                d[@"entry"] = SerializeEntry(op.entry);
            break;

        case CRDTOperationTypeRemove:
            d[@"op"] = @"remove";
            break;

        case CRDTOperationTypeArrayPush:
            d[@"op"] = @"array-push";
            if (op.entry)
                d[@"entry"] = SerializeEntry(op.entry);
            if (op.ref)
                d[@"ref"] = op.ref;
            break;

        case CRDTOperationTypeArrayUnshift:
            d[@"op"] = @"array-unshift";
            if (op.entry)
                d[@"entry"] = SerializeEntry(op.entry);
            break;

        case CRDTOperationTypeArrayRemove:
            d[@"op"] = @"array-remove";
            if (op.ref)
                d[@"ref"] = op.ref;
            break;
        }

        [result addObject:d];
    }

    return result;
}

static NSDictionary *SerializeEntry(LDEntry *entry) {
    return @{
        @"id" : entry.entryId,
        @"key" : entry.key,
        @"type" : EntryTypeToString(entry.type),
        @"value" : SerializeValue(entry.value, entry.meta.replicaId),
        @"meta" : SerializeMeta(entry.meta)
    };
}

static NSDictionary *SerializeMeta(LDMeta *meta) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"updatedAt"] = @(meta.updatedAt);
    d[@"version"] = @(meta.version);
    d[@"replicaId"] = meta.replicaId;

    if (meta.tombstone) {
        d[@"tombstone"] = meta.tombstone;
    }
    if (meta.afterIsSet) {
        d[@"after"] = meta.after ?: [NSNull null];
    }

    return d;
}

static id SerializeValue(LDValue *value, NSString *replicaId) {
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
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];

        for (NSString *key in m.index) {
            LDEntry *entry = m.index[key];

            if ([key isEqualToString:@"index"] &&
                entry.value.type == LDValueTypeMap) {
                LDMap *innerMap = entry.value.mapValue;
                NSMutableDictionary *indexDict =
                    [NSMutableDictionary dictionary];
                for (NSString *k in innerMap.index) {
                    indexDict[k] = SerializeEntry(innerMap.index[k]);
                }
                dict[@"index"] = indexDict;
            } else {
                dict[key] = SerializeEntry(entry);
            }
        }

        dict[@"meta"] = @{
            @"updatedAt" : @(m.meta.updatedAt),
            @"version" : @(m.meta.version),
            @"replicaId" : replicaId
        };

        return dict;
    }

    case LDValueTypeArray: {
        LDArray *a = value.arrayValue;
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];

        for (NSString *entryId in a.entries) {
            dict[entryId] = SerializeEntry(a.entries[entryId]);
        }

        return dict;
    }
    }

    return [NSNull null];
}

static NSArray<CRDTOperation *> *DeserializeOps(NSArray<NSDictionary *> *dOps) {
    NSMutableArray<CRDTOperation *> *result = [NSMutableArray array];

    for (NSDictionary *d in dOps) {
        if (![d isKindOfClass:[NSDictionary class]])
            continue;

        NSString *op = d[@"op"];
        NSArray<NSString *> *path = d[@"path"];
        NSNumber *tsNum = d[@"timestamp"];
        NSString *replicaId = d[@"replicaId"];

        if (![op isKindOfClass:[NSString class]] ||
            ![path isKindOfClass:[NSArray class]] || !tsNum ||
            ![replicaId isKindOfClass:[NSString class]]) {
            continue;
        }

        NSInteger ts = tsNum.integerValue;

        if ([op isEqualToString:@"add"]) {
            LDEntry *entry = nil;
            NSDictionary *entryDict = d[@"entry"];
            if ([entryDict isKindOfClass:[NSDictionary class]]) {
                entry = DeserializeEntry(entryDict);
            }
            [result addObject:[CRDTOperation addWithPath:path
                                                   entry:entry
                                               timestamp:ts
                                               replicaId:replicaId]];

        } else if ([op isEqualToString:@"replace"]) {
            NSDictionary *entryDict = d[@"entry"];
            if (![entryDict isKindOfClass:[NSDictionary class]])
                continue;
            [result addObject:[CRDTOperation
                                  replaceWithPath:path
                                            entry:DeserializeEntry(entryDict)
                                        timestamp:ts
                                        replicaId:replicaId]];

        } else if ([op isEqualToString:@"remove"]) {
            [result addObject:[CRDTOperation removeWithPath:path
                                                  timestamp:ts
                                                  replicaId:replicaId]];

        } else if ([op isEqualToString:@"array-push"]) {
            NSDictionary *entryDict = d[@"entry"];
            if (![entryDict isKindOfClass:[NSDictionary class]])
                continue;
            NSString *ref =
                [d[@"ref"] isKindOfClass:[NSString class]] ? d[@"ref"] : nil;
            [result addObject:[CRDTOperation
                                  arrayPushWithPath:path
                                                ref:ref
                                              entry:DeserializeEntry(entryDict)
                                          timestamp:ts
                                          replicaId:replicaId]];

        } else if ([op isEqualToString:@"array-unshift"]) {
            NSDictionary *entryDict = d[@"entry"];
            if (![entryDict isKindOfClass:[NSDictionary class]])
                continue;
            [result
                addObject:[CRDTOperation
                              arrayUnshiftWithPath:path
                                             entry:DeserializeEntry(entryDict)
                                         timestamp:ts
                                         replicaId:replicaId]];

        } else if ([op isEqualToString:@"array-remove"]) {
            NSString *ref = d[@"ref"];
            if (![ref isKindOfClass:[NSString class]])
                continue;
            [result addObject:[CRDTOperation arrayRemoveWithPath:path
                                                             ref:ref
                                                       timestamp:ts
                                                       replicaId:replicaId]];
        }
    }

    return result;
}

static LDEntry *DeserializeEntry(NSDictionary *dEntry) {

    NSString *entryId = [dEntry[@"id"] isKindOfClass:[NSString class]]
                            ? dEntry[@"id"]
                            : [Utils generateId];
    NSString *key = [dEntry[@"key"] isKindOfClass:[NSString class]]
                        ? dEntry[@"key"]
                        : entryId;

    NSString *typeStr = [dEntry[@"type"] isKindOfClass:[NSString class]]
                            ? dEntry[@"type"]
                            : @"object";
    LDEntryType entryType = EntryTypeFromString(typeStr);

    LDValue *value;
    id rawVal = dEntry[@"value"];

    if (rawVal) {
        if (entryType == LDEntryTypeObject &&
            [rawVal isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)rawVal;
            LDMap *ldMap = [[LDMap alloc] init];

            for (NSString *k in dict) {
                id v = dict[k];

                if ([v isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *vDict = (NSDictionary *)v;
                    if (vDict[@"id"] != nil) {
                        ldMap.index[k] = DeserializeEntry(vDict);
                    } else {
                        LDValue *ldVal = [Utils toLDValue:v];
                        ldMap.index[k] = [[LDEntry alloc]
                            initWithId:[Utils generateId]
                                   key:k
                                  type:[Utils determineType:ldVal]
                                 value:ldVal
                                  meta:[[LDMeta alloc]
                                           initWithUpdatedAt:(NSInteger)
                                                                 [Utils nowMs]
                                                     version:1
                                                   replicaId:@"remote"
                                                       order:nil
                                                   tombstone:nil
                                                       after:nil
                                                  afterIsSet:NO
                                                        next:nil]];
                    }
                } else {
                    LDValue *ldVal = [Utils toLDValue:v];
                    ldMap.index[k] = [[LDEntry alloc]
                        initWithId:[Utils generateId]
                               key:k
                              type:[Utils determineType:ldVal]
                             value:ldVal
                              meta:[[LDMeta alloc]
                                       initWithUpdatedAt:(NSInteger)[Utils
                                                                         nowMs]
                                                 version:1
                                               replicaId:@"remote"
                                                   order:nil
                                               tombstone:nil
                                                   after:nil
                                              afterIsSet:NO
                                                    next:nil]];
                }
            }

            value = [LDValue mapValue:ldMap];
        } else {
            value = [Utils toLDValue:rawVal];
        }
    } else {
        value = [LDValue nullValue];
    }

    LDMeta *meta = [[LDMeta alloc] init];

    NSDictionary *m = dEntry[@"meta"];
    if ([m isKindOfClass:[NSDictionary class]]) {
        NSNumber *updatedAtNum = m[@"updatedAt"];
        meta.updatedAt = [updatedAtNum isKindOfClass:[NSNumber class]]
                             ? updatedAtNum.integerValue
                             : (NSInteger)[Utils nowMs];

        NSNumber *versionNum = m[@"version"];
        meta.version = [versionNum isKindOfClass:[NSNumber class]]
                           ? versionNum.integerValue
                           : 1;

        NSString *rid = m[@"replicaId"];
        meta.replicaId = [rid isKindOfClass:[NSString class]] ? rid : @"remote";

        NSNumber *tombstone = m[@"tombstone"];
        if ([tombstone isKindOfClass:[NSNumber class]]) {
            meta.tombstone = tombstone;
        }

        if ([m.allKeys containsObject:@"after"]) {
            id afterVal = m[@"after"];
            if ([afterVal isKindOfClass:[NSString class]]) {
                meta.after = afterVal;
            } else {
                meta.after = [NSNull null];
            }
            meta.afterIsSet = YES;
        }
    }

    return [[LDEntry alloc] initWithId:entryId
                                   key:key
                                  type:entryType
                                 value:value
                                  meta:meta];
}
