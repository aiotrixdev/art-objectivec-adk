//
//  CRDT.m
//  ADK
//

#import "CRDT.h"

/// Completion block that receives the query result.
typedef void (^QueryResultCompletion)(id _Nullable result);

/// Block that takes a completion and executes the query.
typedef void (^QueryExecuteBlock)(QueryResultCompletion completion);

/// Unsubscribe block returned by listen.
typedef void (^UnsubscribeBlock)(void);

/// Block that takes a listener callback and returns an unsubscribe block.
typedef UnsubscribeBlock _Nonnull (^QueryListenBlock)(
    CRDTListener _Nonnull callback);

@interface CRDTProxy ()
@property(nonatomic, weak) CRDT *crdt; // weak to break rootProxy<->CRDT cycle
@property(nonatomic, strong) NSArray<NSString *> *parentPath;
- (instancetype)initWithCRDT:(CRDT *)crdt
                  parentPath:(NSArray<NSString *> *)parentPath;
@end

@interface CRDTQueryHandle ()
@property(nonatomic, copy) QueryExecuteBlock executeBlock;
@property(nonatomic, copy) QueryListenBlock listenBlock;
@end

@interface CRDT ()

@property(nonatomic, strong) LDMap *snapshot;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableArray<CRDTListener> *> *listeners;
@property(nonatomic, copy) CRDTMergeCallback mergeCallback;
@property(nonatomic, strong, nullable) CRDTProxy *rootProxy;
@property(nonatomic, strong) NSMutableArray<CRDTOperation *> *pending;

@property(nonatomic, assign) double lastFlushAt;
@property(nonatomic, assign) double minFlushMs;
@property(nonatomic, assign) BOOL trailingTimerScheduled;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSRecursiveLock *snapshotLock;

- (nullable LDValue *)navigatePath:(NSArray<NSString *> *)path
                             error:(NSError **)error;
- (nullable LDContainer *)navigateToParentPath:(NSArray<NSString *> *)path
                                   forceCreate:(BOOL)forceCreate
                                         error:(NSError **)error;
- (void)ensureMapParentsWithRoot:(LDMap *)root
                            path:(NSArray<NSString *> *)path
                              ts:(NSInteger)ts
                       replicaId:(NSString *)replicaId;

- (NSArray<CRDTOperation *> *)compactOps:(NSArray<CRDTOperation *> *)batch;

- (NSArray<CRDTOperation *> *)pendingArrayOpsForPath:
    (NSArray<NSString *> *)parentPath;
- (NSArray<NSString *> *)baseIdsForPath:(NSArray<NSString *> *)path;

- (id)withSnapshotLock:(id (^)(void))block;

@end

@implementation CRDTProxy

- (instancetype)initWithCRDT:(CRDT *)crdt
                  parentPath:(NSArray<NSString *> *)parentPath {
    self = [super init];
    if (self) {
        _crdt = crdt;
        _parentPath = [parentPath copy];
    }
    return self;
}

- (CRDTProxy *)objectForKeyedSubscript:(NSString *)key {
    CRDT *crdt = self.crdt;
    NSMutableArray *newPath = [self.parentPath mutableCopy];
    [newPath addObject:key];
    return [[CRDTProxy alloc] initWithCRDT:crdt parentPath:newPath];
}

- (CRDTProxy *)objectAtIndexedSubscript:(NSUInteger)idx {
    CRDT *crdt = self.crdt;
    NSString *entryId = [crdt getArrayIdAtPath:self.parentPath
                                         index:(NSInteger)idx];
    NSMutableArray *newPath = [self.parentPath mutableCopy];
    if (entryId) {
        [newPath addObject:entryId];
    } else {
        [newPath addObject:[NSString stringWithFormat:@"__oob_%lu",
                                                      (unsigned long)idx]];
    }
    return [[CRDTProxy alloc] initWithCRDT:crdt parentPath:newPath];
}

- (nullable id)value {
    CRDT *crdt = self.crdt;
    if (!crdt) return nil;
    return [crdt readJSONAtPath:self.parentPath];
}

- (void)set:(nullable id)value {
    CRDT *crdt = self.crdt;
    if (!crdt) return;
    NSString *key = self.parentPath.lastObject ?: @"";
    NSArray<NSString *> *full = self.parentPath;

    NSArray<CRDTOperation *> *parents =
        [crdt ensureParentsOpsForPath:full];

    LDValue *ldVal = [Utils toLDValue:value];
    [self patchReplicaWithCRDT:crdt value:ldVal];

    LDMeta *meta = [[LDMeta alloc] initWithUpdatedAt:(NSInteger)[Utils nowMs]
                                             version:1
                                           replicaId:crdt.clientReplicaId
                                               order:nil
                                           tombstone:nil
                                               after:nil
                                          afterIsSet:NO
                                                next:nil];

    LDEntry *entry = [[LDEntry alloc] initWithId:[Utils generateId]
                                             key:key
                                            type:[Utils determineType:ldVal]
                                           value:ldVal
                                            meta:meta];

    [crdt appendPendingOps:parents];

    CRDTOperation *replaceOp =
        [CRDTOperation replaceWithPath:full
                                 entry:entry
                             timestamp:(NSInteger)[Utils nowMs]
                             replicaId:crdt.clientReplicaId];
    [crdt appendPendingOp:replaceOp];

    [crdt scheduleFlush];
}

- (void)patchReplicaWithCRDT:(CRDT *)crdt value:(LDValue *)v {
    if (!crdt) return;
    switch (v.type) {
    case LDValueTypeMap: {
        LDMap *m = v.mapValue;
        for (NSString *k in m.index) {
            LDEntry *e = m.index[k];
            e.meta.replicaId = crdt.clientReplicaId;
            [self patchReplicaWithCRDT:crdt value:e.value];
        }
        break;
    }
    case LDValueTypeArray: {
        LDArray *a = v.arrayValue;
        for (NSString *k in a.entries) {
            LDEntry *e = a.entries[k];
            e.meta.replicaId = crdt.clientReplicaId;
            [self patchReplicaWithCRDT:crdt value:e.value];
        }
        break;
    }
    default:
        break;
    }
}

- (void)deleteValue {
    CRDT *crdt = self.crdt;
    if (!crdt) return;
    if ([crdt readJSONAtPath:self.parentPath] == nil)
        return;

    CRDTOperation *op =
        [CRDTOperation removeWithPath:self.parentPath
                            timestamp:(NSInteger)[Utils nowMs]
                            replicaId:crdt.clientReplicaId];
    [crdt appendPendingOp:op];
    [crdt scheduleFlush];
}

- (NSInteger)pushItems:(NSArray *)items {
    CRDT *crdt = self.crdt;
    if (!crdt) return 0;
    [crdt ensureArrayContainerAtPath:self.parentPath];
    NSMutableArray<NSString *> *cur =
        [[crdt visibleIdsForPath:self.parentPath] mutableCopy];
    NSString *prev = cur.lastObject;

    for (id item in items) {
        NSString *entryId = [Utils generateId];
        LDValue *ldVal = [Utils toLDValue:item];
        LDMeta *m = [[LDMeta alloc]
            initWithUpdatedAt:(NSInteger)[Utils nowMs]
                      version:1
                    replicaId:crdt.clientReplicaId
                        order:nil
                    tombstone:nil
                        after:(prev ?: (id)[NSNull null])afterIsSet:YES
                         next:nil];

        LDEntry *entry = [[LDEntry alloc] initWithId:entryId
                                                 key:entryId
                                                type:[Utils determineType:ldVal]
                                               value:ldVal
                                                meta:m];

        CRDTOperation *op =
            [CRDTOperation arrayPushWithPath:self.parentPath
                                         ref:prev
                                       entry:entry
                                   timestamp:m.updatedAt
                                   replicaId:crdt.clientReplicaId];
        [crdt appendPendingOp:op];
        [cur addObject:entryId];
        prev = entryId;
    }

    [crdt scheduleFlush];
    return (NSInteger)cur.count;
}

- (NSInteger)pushItem:(id)item {
    return [self pushItems:@[ item ]];
}

- (NSInteger)unshiftItems:(NSArray *)items {
    CRDT *crdt = self.crdt;
    if (!crdt) return 0;
    [crdt ensureArrayContainerAtPath:self.parentPath];

    for (id item in items) {
        NSString *entryId = [Utils generateId];
        LDValue *ldVal = [Utils toLDValue:item];
        LDMeta *m = [[LDMeta alloc] initWithUpdatedAt:(NSInteger)[Utils nowMs]
                                              version:1
                                            replicaId:crdt.clientReplicaId
                                                order:nil
                                            tombstone:nil
                                                after:[NSNull null]
                                           afterIsSet:YES
                                                 next:nil];

        LDEntry *entry = [[LDEntry alloc] initWithId:entryId
                                                 key:entryId
                                                type:[Utils determineType:ldVal]
                                               value:ldVal
                                                meta:m];

        CRDTOperation *op =
            [CRDTOperation arrayUnshiftWithPath:self.parentPath
                                          entry:entry
                                      timestamp:m.updatedAt
                                      replicaId:crdt.clientReplicaId];
        [crdt appendPendingOp:op];
    }

    [crdt scheduleFlush];
    return (NSInteger)[crdt visibleIdsForPath:self.parentPath].count;
}

- (NSInteger)unshiftItem:(id)item {
    return [self unshiftItems:@[ item ]];
}

- (nullable id)pop {
    CRDT *crdt = self.crdt;
    if (!crdt) return nil;
    NSArray<NSString *> *ids = [crdt visibleIdsForPath:self.parentPath];
    NSString *lastId = ids.lastObject;
    if (!lastId)
        return nil;

    LDValue *container = [crdt getContainerAtPath:self.parentPath];
    id ret = nil;
    if (container && container.type == LDValueTypeArray) {
        LDEntry *e = container.arrayValue.entries[lastId];
        if (e) {
            ret = [Utils toAny:e.value];
        }
    }

    CRDTOperation *op =
        [CRDTOperation arrayRemoveWithPath:self.parentPath
                                       ref:lastId
                                 timestamp:(NSInteger)[Utils nowMs]
                                 replicaId:crdt.clientReplicaId];
    [crdt appendPendingOp:op];
    [crdt scheduleFlush];
    return ret;
}

- (nullable id)removeAtIndex:(NSInteger)index {
    CRDT *crdt = self.crdt;
    if (!crdt) return nil;
    NSString *entryId = [crdt getArrayIdAtPath:self.parentPath
                                         index:index];
    if (!entryId)
        return nil;

    LDValue *container = [crdt getContainerAtPath:self.parentPath];
    id ret = nil;
    if (container && container.type == LDValueTypeArray) {
        LDEntry *e = container.arrayValue.entries[entryId];
        if (e) {
            ret = [Utils toAny:e.value];
        }
    }

    CRDTOperation *op =
        [CRDTOperation arrayRemoveWithPath:self.parentPath
                                       ref:entryId
                                 timestamp:(NSInteger)[Utils nowMs]
                                 replicaId:crdt.clientReplicaId];
    [crdt appendPendingOp:op];
    [crdt scheduleFlush];
    return ret;
}

- (NSArray<NSString *> *)spliceStart:(NSInteger)start
                         deleteCount:(NSInteger)deleteCount
                         insertItems:(NSArray *)items {
    CRDT *crdt = self.crdt;
    if (!crdt) return @[];
    NSArray<NSString *> *ids = [crdt visibleIdsForPath:self.parentPath];
    NSInteger len = (NSInteger)ids.count;
    NSInteger s = MIN(MAX(0, start), len);
    NSInteger dc = MAX(0, MIN(deleteCount, len - s));

    // Delete phase
    for (NSInteger i = 0; i < dc; i++) {
        NSString *entryId = ids[(NSUInteger)(s + i)];
        CRDTOperation *op =
            [CRDTOperation arrayRemoveWithPath:self.parentPath
                                           ref:entryId
                                     timestamp:(NSInteger)[Utils nowMs]
                                     replicaId:crdt.clientReplicaId];
        [crdt appendPendingOp:op];
    }

    // Insert phase
    NSString *prev = (s > 0) ? ids[(NSUInteger)(s - 1)] : nil;
    for (id item in items) {
        NSString *entryId = [Utils generateId];
        LDValue *ldVal = [Utils toLDValue:item];
        LDMeta *m = [[LDMeta alloc]
            initWithUpdatedAt:(NSInteger)[Utils nowMs]
                      version:1
                    replicaId:crdt.clientReplicaId
                        order:nil
                    tombstone:nil
                        after:(prev ?: (id)[NSNull null])afterIsSet:YES
                         next:nil];

        LDEntry *entry = [[LDEntry alloc] initWithId:entryId
                                                 key:entryId
                                                type:[Utils determineType:ldVal]
                                               value:ldVal
                                                meta:m];

        if (prev != nil) {
            CRDTOperation *op =
                [CRDTOperation arrayPushWithPath:self.parentPath
                                             ref:prev
                                           entry:entry
                                       timestamp:m.updatedAt
                                       replicaId:crdt.clientReplicaId];
            [crdt appendPendingOp:op];
        } else {
            CRDTOperation *op =
                [CRDTOperation arrayUnshiftWithPath:self.parentPath
                                              entry:entry
                                          timestamp:m.updatedAt
                                          replicaId:crdt.clientReplicaId];
            [crdt appendPendingOp:op];
        }
        prev = entryId;
    }

    [crdt scheduleFlush];

    // Return the removed IDs
    NSRange range = NSMakeRange((NSUInteger)s, (NSUInteger)dc);
    return [ids subarrayWithRange:range];
}

- (NSInteger)length {
    CRDT *crdt = self.crdt;
    if (!crdt) return 0;
    return (NSInteger)[crdt visibleIdsForPath:self.parentPath].count;
}

- (void)flushWithCompletion:(void (^)(void))completion {
    CRDT *crdt = self.crdt;
    if (!crdt) {
        if (completion) completion();
        return;
    }
    [crdt flush:completion];
}

@end

@implementation CRDTQueryHandle

- (void)executeWithCompletion:(void (^)(id _Nullable))completion {
    if (self.executeBlock) {
        self.executeBlock(completion);
    } else {
        completion(nil);
    }
}

- (void (^)(void))listenWithCallback:(CRDTListener)callback {
    if (self.listenBlock) {
        return self.listenBlock(callback);
    }
    return ^{
    };
}

@end

@implementation CRDT

- (instancetype)initWithInitial:(LDMap *)initial
                  mergeCallback:(CRDTMergeCallback)mergeCallback {
    self = [super init];
    if (self) {
        _snapshot = initial;
        _mergeCallback = [mergeCallback copy];
        _listeners = [NSMutableDictionary dictionary];
        _pending = [NSMutableArray array];
        _clientReplicaId = @"client";
        _lastFlushAt = 0;
        _minFlushMs = 50;
        _trailingTimerScheduled = NO;
        _queue = dispatch_queue_create("crdt.queue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(
            _queue, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        _snapshotLock = [[NSRecursiveLock alloc] init];
    }
    return self;
}

- (id)withSnapshotLock:(id (^)(void))block {
    [_snapshotLock lock];
    id result = block();
    [_snapshotLock unlock];
    return result;
}

- (CRDTProxy *)state {
    if (!_rootProxy) {
        _rootProxy = [[CRDTProxy alloc] initWithCRDT:self parentPath:@[]];
    }
    return _rootProxy;
}

- (void)setMergeCallback:(CRDTMergeCallback)callback {
    _mergeCallback = [callback copy];
}

- (void)setReplicaId:(NSString *)replicaId {
    _clientReplicaId = [replicaId copy];
}

- (NSString *)getReplicaId {
    return _clientReplicaId;
}

- (LDMap *)getState {
    return _snapshot;
}

- (void)appendPendingOp:(CRDTOperation *)op {
    dispatch_sync(_queue, ^{
      [self.pending addObject:op];
    });
}

- (void)appendPendingOps:(NSArray<CRDTOperation *> *)ops {
    dispatch_sync(_queue, ^{
      [self.pending addObjectsFromArray:ops];
    });
}

- (void)flush:(void (^)(void))completion {
    __block NSArray<CRDTOperation *> *ops = nil;

    dispatch_sync(_queue, ^{
      if (self.pending.count == 0)
          return;
      ops = [self compactOps:self.pending];
      [self.pending removeAllObjects];
    });

    if (!ops || ops.count == 0) {
        if (completion)
            completion();
        return;
    }

    [self withSnapshotLock:^id {
      [self merge:ops];
      return nil;
    }];

    if (self.mergeCallback) {
        self.mergeCallback(ops);
    }

    if (completion)
        completion();
}

- (void)scheduleFlush {
    __weak typeof(self) weakSelf = self;
    dispatch_sync(_queue, ^{
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf) return;
      if (strongSelf.trailingTimerScheduled)
          return;
      strongSelf.trailingTimerScheduled = YES;

      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(strongSelf.minFlushMs * NSEC_PER_MSEC)),
          dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            typeof(self) innerSelf = weakSelf;
            if (!innerSelf) return;
            dispatch_sync(innerSelf.queue, ^{
              typeof(self) s2 = weakSelf;
              if (s2) s2.trailingTimerScheduled = NO;
            });
            [innerSelf flush:nil];
          });
    });
}

- (NSArray<CRDTOperation *> *)compactOps:(NSArray<CRDTOperation *> *)batch {
    NSMutableSet<NSString *> *parentAddsSeen = [NSMutableSet set];
    NSMutableArray<CRDTOperation *> *parentAdds = [NSMutableArray array];
    NSMutableArray<CRDTOperation *> *arrayOps = [NSMutableArray array];

    // LeafAcc: stores either a replace entry or a remove marker
    // We use an NSDictionary with @"kind" -> @"replace"/@"remove" and optional
    // @"entry"
    NSMutableDictionary<NSString *, NSDictionary *> *leafMap =
        [NSMutableDictionary dictionary];

    for (CRDTOperation *op in batch) {
        switch (op.operationType) {
        case CRDTOperationTypeArrayPush:
        case CRDTOperationTypeArrayUnshift:
        case CRDTOperationTypeArrayRemove:
            [arrayOps addObject:op];
            break;

        case CRDTOperationTypeAdd: {
            LDEntry *entry = op.entry;
            if (entry != nil) {
                if (entry.type == LDEntryTypeObject ||
                    entry.type == LDEntryTypeArray) {
                    NSString *k = [op.path componentsJoinedByString:@"."];
                    if (![parentAddsSeen containsObject:k]) {
                        [parentAddsSeen addObject:k];
                        [parentAdds addObject:op];
                    }
                    continue; // skip leafMap for parent containers
                }
            }
            NSString *key = [op.path componentsJoinedByString:@"."];
            if (entry != nil) {
                leafMap[key] = @{@"kind" : @"replace", @"entry" : entry};
            }
            break;
        }

        case CRDTOperationTypeReplace: {
            NSString *key = [op.path componentsJoinedByString:@"."];
            leafMap[key] = @{@"kind" : @"replace", @"entry" : op.entry};
            break;
        }

        case CRDTOperationTypeRemove: {
            NSString *key = [op.path componentsJoinedByString:@"."];
            leafMap[key] = @{@"kind" : @"remove"};
            break;
        }
        }
    }

    // Sort parent adds by path depth (shortest first)
    [parentAdds sortUsingComparator:^NSComparisonResult(CRDTOperation *a,
                                                        CRDTOperation *b) {
      if (a.path.count < b.path.count)
          return NSOrderedAscending;
      if (a.path.count > b.path.count)
          return NSOrderedDescending;
      return NSOrderedSame;
    }];

    NSMutableArray<CRDTOperation *> *leaves = [NSMutableArray array];
    for (NSString *k in leafMap) {
        NSDictionary *acc = leafMap[k];
        NSArray<NSString *> *path = [k componentsSeparatedByString:@"."];
        if ([acc[@"kind"] isEqualToString:@"remove"]) {
            [leaves
                addObject:[CRDTOperation removeWithPath:path
                                              timestamp:(NSInteger)[Utils nowMs]
                                              replicaId:self.clientReplicaId]];
        } else {
            LDEntry *entry = acc[@"entry"];
            [leaves addObject:[CRDTOperation
                                  replaceWithPath:path
                                            entry:entry
                                        timestamp:(NSInteger)[Utils nowMs]
                                        replicaId:self.clientReplicaId]];
        }
    }

    NSMutableArray<CRDTOperation *> *result = [NSMutableArray
        arrayWithCapacity:parentAdds.count + leaves.count + arrayOps.count];
    [result addObjectsFromArray:parentAdds];
    [result addObjectsFromArray:leaves];
    [result addObjectsFromArray:arrayOps];
    return result;
}

- (nullable LDValue *)getContainerAtPath:(NSArray<NSString *> *)path {
    [_snapshotLock lock];
    @try {
        LDValue *node = [LDValue mapValue:_snapshot];
        for (NSString *seg in path) {
            if (node.type == LDValueTypeMap) {
                LDEntry *e = node.mapValue.index[seg];
                if (!e)
                    return nil;
                node = e.value;
            } else if (node.type == LDValueTypeArray) {
                LDEntry *e = node.arrayValue.entries[seg];
                if (!e)
                    return nil;
                node = e.value;
            } else {
                return nil;
            }
        }
        if (node.type == LDValueTypeMap || node.type == LDValueTypeArray) {
            return node;
        }
        return nil;
    } @finally {
        [_snapshotLock unlock];
    }
}

- (nullable id)readJSONAtPath:(NSArray<NSString *> *)path {
    [_snapshotLock lock];
    @try {
        LDValue *node = [LDValue mapValue:_snapshot];
        for (NSString *seg in path) {
            if (node.type == LDValueTypeMap) {
                LDEntry *e = node.mapValue.index[seg];
                if (!e)
                    return nil;
                node = e.value;
            } else if (node.type == LDValueTypeArray) {
                LDEntry *e = node.arrayValue.entries[seg];
                if (!e)
                    return nil;
                node = e.value;
            } else {
                return nil;
            }
        }
        return [Utils toAny:node];
    } @finally {
        [_snapshotLock unlock];
    }
}

- (nullable LDValue *)navigatePath:(NSArray<NSString *> *)path
                             error:(NSError **)error {
    [_snapshotLock lock];
    @try {
        LDValue *node = [LDValue mapValue:_snapshot];
        for (NSUInteger i = 0; i < path.count; i++) {
            NSString *seg = path[i];
            if (i == 0 && [seg isEqualToString:@"index"])
                continue;

            if (node.type == LDValueTypeMap) {
                LDEntry *e = node.mapValue.index[seg];
                if (!e) {
                    if (error)
                        *error =
                            MakeError(ErrorCodeInvalidPath,
                                      [path componentsJoinedByString:@"."]);
                    return nil;
                }
                node = e.value;
            } else if (node.type == LDValueTypeArray) {
                LDEntry *e = node.arrayValue.entries[seg];
                if (!e) {
                    if (error)
                        *error =
                            MakeError(ErrorCodeInvalidPath,
                                      [path componentsJoinedByString:@"."]);
                    return nil;
                }
                node = e.value;
            } else {
                if (error)
                    *error = MakeError(
                        ErrorCodeInvalidPath,
                        [NSString
                            stringWithFormat:
                                @"Cannot navigate into primitive at %@", seg]);
                return nil;
            }
        }
        return node;
    } @finally {
        [_snapshotLock unlock];
    }
}

/// Returns YES if all characters in `str` are ASCII digits.
static BOOL AllDigits(NSString *str) {
    if (str.length == 0)
        return NO;
    NSCharacterSet *nonDigits =
        [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [str rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

- (nullable LDContainer *)navigateToParentPath:(NSArray<NSString *> *)path
                                   forceCreate:(BOOL)forceCreate
                                         error:(NSError **)error {
    [_snapshotLock lock];
    @try {
        LDContainer *node = [LDContainer containerWithMap:_snapshot];
        if (path.count < 2)
            return node;
        for (NSUInteger i = 0; i < path.count - 1; i++) {
            NSString *seg = path[i];
            if (i == 0 && [seg isEqualToString:@"index"])
                continue;

            if (node.kind == LDContainerKindMap) {
                LDMap *m = node.map;
                if (m.index[seg] == nil) {
                    if (!forceCreate) {
                        if (error)
                            *error =
                                MakeError(ErrorCodeInvalidPath,
                                          [path componentsJoinedByString:@"."]);
                        return nil;
                    }
                    NSString *nextSeg = path[i + 1];
                    BOOL isArr = AllDigits(nextSeg);
                    LDValue *ldVal =
                        isArr ? [LDValue arrayValue:[[LDArray alloc] init]]
                              : [LDValue mapValue:[[LDMap alloc] init]];
                    LDMeta *meta = [[LDMeta alloc]
                        initWithUpdatedAt:(NSInteger)[Utils nowMs]
                                  version:1
                                replicaId:self.clientReplicaId
                                    order:nil
                                tombstone:nil
                                    after:nil
                               afterIsSet:NO
                                     next:nil];
                    m.index[seg] = [[LDEntry alloc]
                        initWithId:[Utils generateId]
                               key:seg
                              type:isArr ? LDEntryTypeArray : LDEntryTypeObject
                             value:ldVal
                              meta:meta];
                }
                LDEntry *e = m.index[seg];
                NSError *containerErr = nil;
                LDContainer *next = [Utils toContainer:e.value
                                                 error:&containerErr];
                if (!next) {
                    if (error)
                        *error = containerErr;
                    return nil;
                }
                node = next;
            } else {
                // LDContainerKindArray
                LDArray *a = node.array;
                if (a.entries[seg] == nil) {
                    if (!forceCreate) {
                        if (error)
                            *error =
                                MakeError(ErrorCodeInvalidPath,
                                          [path componentsJoinedByString:@"."]);
                        return nil;
                    }
                    LDMeta *meta = [[LDMeta alloc]
                        initWithUpdatedAt:(NSInteger)[Utils nowMs]
                                  version:1
                                replicaId:self.clientReplicaId
                                    order:nil
                                tombstone:nil
                                    after:[NSNull null]
                               afterIsSet:YES
                                     next:nil];
                    a.entries[seg] = [[LDEntry alloc]
                        initWithId:seg
                               key:seg
                              type:LDEntryTypeObject
                             value:[LDValue mapValue:[[LDMap alloc] init]]
                              meta:meta];
                }
                NSError *containerErr = nil;
                LDContainer *next = [Utils toContainer:a.entries[seg].value
                                                 error:&containerErr];
                if (!next) {
                    if (error)
                        *error = containerErr;
                    return nil;
                }
                node = next;
            }
        }
        return node;
    } @finally {
        [_snapshotLock unlock];
    }
}

- (void)ensureMapParentsWithRoot:(LDMap *)root
                            path:(NSArray<NSString *> *)path
                              ts:(NSInteger)ts
                       replicaId:(NSString *)replicaId {
    [_snapshotLock lock];
    @try {
        if (path.count < 2)
            return;
        LDContainer *node = [LDContainer containerWithMap:root];
        for (NSUInteger i = 0; i < path.count - 1; i++) {
            NSString *seg = path[i];

            if (node.kind == LDContainerKindMap) {
                LDMap *m = node.map;
                if (m.index[seg] == nil) {
                    LDMeta *meta = [[LDMeta alloc] initWithUpdatedAt:ts
                                                             version:1
                                                           replicaId:replicaId
                                                               order:nil
                                                           tombstone:nil
                                                               after:nil
                                                          afterIsSet:NO
                                                                next:nil];
                    m.index[seg] = [[LDEntry alloc]
                        initWithId:[Utils generateId]
                               key:seg
                              type:LDEntryTypeObject
                             value:[LDValue mapValue:[[LDMap alloc] init]]
                              meta:meta];
                }
                LDEntry *e = m.index[seg];
                if (e.value.type == LDValueTypeMap) {
                    node = [LDContainer containerWithMap:e.value.mapValue];
                } else if (e.value.type == LDValueTypeArray) {
                    node = [LDContainer containerWithArray:e.value.arrayValue];
                }
            } else {
                // LDContainerKindArray
                LDArray *a = node.array;
                if (a.entries[seg] == nil) {
                    LDMeta *meta =
                        [[LDMeta alloc] initWithUpdatedAt:ts
                                                  version:1
                                                replicaId:replicaId
                                                    order:nil
                                                tombstone:nil
                                                    after:[NSNull null]
                                               afterIsSet:YES
                                                     next:nil];
                    a.entries[seg] = [[LDEntry alloc]
                        initWithId:seg
                               key:seg
                              type:LDEntryTypeObject
                             value:[LDValue mapValue:[[LDMap alloc] init]]
                              meta:meta];
                }
                LDEntry *e = a.entries[seg];
                if (e.value.type == LDValueTypeMap) {
                    node = [LDContainer containerWithMap:e.value.mapValue];
                }
            }
        }
    } @finally {
        [_snapshotLock unlock];
    }
}

- (LDArray *)ensureArrayContainerAtPath:(NSArray<NSString *> *)path {
    [_snapshotLock lock];
    @try {
        LDValue *existing = [self getContainerAtPath:path];
        if (existing && existing.type == LDValueTypeArray) {
            return existing.arrayValue;
        }

        LDMeta *arrMeta = [Utils defaultMetaWithReplicaId:self.clientReplicaId];
        LDArray *newArr =
            [[LDArray alloc] initWithEntries:[NSMutableDictionary dictionary]
                                        head:nil
                                        meta:arrMeta];
        NSString *key = path.lastObject ?: @"";
        LDMeta *entryMeta =
            [[LDMeta alloc] initWithUpdatedAt:(NSInteger)[Utils nowMs]
                                      version:1
                                    replicaId:self.clientReplicaId
                                        order:nil
                                    tombstone:nil
                                        after:nil
                                   afterIsSet:NO
                                         next:nil];
        LDEntry *entry = [[LDEntry alloc] initWithId:[Utils generateId]
                                                 key:key
                                                type:LDEntryTypeArray
                                               value:[LDValue arrayValue:newArr]
                                                meta:entryMeta];

        if (path.count <= 1) {
            _snapshot.index[key] = entry;
        } else {
            NSArray<NSString *> *parentPath =
                [path subarrayWithRange:NSMakeRange(0, path.count - 1)];
            LDValue *parent = [self getContainerAtPath:parentPath];
            if (parent && parent.type == LDValueTypeMap) {
                parent.mapValue.index[key] = entry;
            }
        }
        return newArr;
    } @finally {
        [_snapshotLock unlock];
    }
}

- (NSArray<CRDTOperation *> *)pendingArrayOpsForPath:
    (NSArray<NSString *> *)parentPath {
    NSString *key = [parentPath componentsJoinedByString:@"."];

    __block NSArray<CRDTOperation *> *result = nil;
    dispatch_sync(_queue, ^{
      NSMutableArray *filtered = [NSMutableArray array];
      for (CRDTOperation *op in self.pending) {
          if (op.operationType == CRDTOperationTypeArrayPush ||
              op.operationType == CRDTOperationTypeArrayUnshift ||
              op.operationType == CRDTOperationTypeArrayRemove) {
              if ([[op.path componentsJoinedByString:@"."]
                      isEqualToString:key]) {
                  [filtered addObject:op];
              }
          }
      }
      result = [filtered copy];
    });
    return result;
}

- (NSArray<NSString *> *)baseIdsForPath:(NSArray<NSString *> *)path {
    [_snapshotLock lock];
    @try {
        LDValue *cont = [self getContainerAtPath:path];
        if (!cont || cont.type != LDValueTypeArray)
            return @[];
        return [Utils linearizeRGA:cont.arrayValue];
    } @finally {
        [_snapshotLock unlock];
    }
}

- (NSArray<NSString *> *)visibleIdsForPath:(NSArray<NSString *> *)path {
    // Snapshot the base IDs and the pending ops under the same
    // snapshot-lock acquisition. Releasing the lock in between (as the
    // previous implementation did) opened a race: a concurrent merge
    // could land between the two reads, producing a visible-id list
    // that reflected neither the old nor the new state.
    [_snapshotLock lock];
    NSMutableArray<NSString *> *ids = nil;
    @try {
        LDValue *cont = [self getContainerAtPath:path];
        if (!cont || cont.type != LDValueTypeArray) {
            ids = [NSMutableArray array];
        } else {
            ids = [[Utils linearizeRGA:cont.arrayValue] mutableCopy];
        }
    } @catch (id e) {
        [_snapshotLock unlock];
        @throw;
    }
    [_snapshotLock unlock];

    // pendingArrayOpsForPath: serialises on its own queue, so we fetch
    // it after releasing the snapshot lock to avoid cross-lock ordering.
    NSArray<CRDTOperation *> *pendingOps = [self pendingArrayOpsForPath:path];
    for (CRDTOperation *op in pendingOps) {
        switch (op.operationType) {
        case CRDTOperationTypeArrayPush: {
            NSString *ref = op.ref;
            NSUInteger pos;
            if (ref) {
                NSUInteger refIdx = [ids indexOfObject:ref];
                pos = (refIdx != NSNotFound) ? refIdx + 1 : ids.count;
            } else {
                pos = ids.count;
            }
            [ids insertObject:op.entry.entryId atIndex:pos];
            break;
        }
        case CRDTOperationTypeArrayUnshift:
            [ids insertObject:op.entry.entryId atIndex:0];
            break;
        case CRDTOperationTypeArrayRemove: {
            NSUInteger idx = [ids indexOfObject:op.ref];
            if (idx != NSNotFound) {
                [ids removeObjectAtIndex:idx];
            }
            break;
        }
        default:
            break;
        }
    }
    return [ids copy];
}

- (nullable NSString *)getArrayIdAtPath:(NSArray<NSString *> *)path
                                  index:(NSInteger)idx {
    NSArray<NSString *> *ids = [self visibleIdsForPath:path];
    NSInteger n = (NSInteger)ids.count;
    NSInteger i = idx < 0 ? n + idx : idx;
    if (i < 0 || i >= n)
        return nil;
    return ids[(NSUInteger)i];
}

- (NSArray<CRDTOperation *> *)ensureParentsOpsForPath:
    (NSArray<NSString *> *)full {
    [_snapshotLock lock];
    @try {
        NSMutableArray<CRDTOperation *> *ops = [NSMutableArray array];
        if (full.count < 2)
            return ops;
        for (NSUInteger i = 0; i < full.count - 1; i++) {
            NSArray<NSString *> *sub =
                [full subarrayWithRange:NSMakeRange(0, i + 1)];
            if ([self readJSONAtPath:sub] != nil)
                continue;

            NSString *seg = full[i];
            NSArray<NSString *> *parentPath =
                [full subarrayWithRange:NSMakeRange(0, i)];
            LDValue *parentCont = [self getContainerAtPath:parentPath];
            if (parentCont && parentCont.type == LDValueTypeArray)
                continue; // skip; merge upserts

            LDMeta *meta =
                [[LDMeta alloc] initWithUpdatedAt:(NSInteger)[Utils nowMs]
                                          version:1
                                        replicaId:self.clientReplicaId
                                            order:nil
                                        tombstone:nil
                                            after:nil
                                       afterIsSet:NO
                                             next:nil];
            LDEntry *entry = [[LDEntry alloc]
                initWithId:[Utils generateId]
                       key:seg
                      type:LDEntryTypeObject
                     value:[LDValue mapValue:[[LDMap alloc] init]]
                      meta:meta];
            [ops addObject:[CRDTOperation addWithPath:sub
                                                entry:entry
                                            timestamp:(NSInteger)[Utils nowMs]
                                            replicaId:self.clientReplicaId]];
        }
        return ops;
    } @finally {
        [_snapshotLock unlock];
    }
}

- (void)merge:(NSArray<CRDTOperation *> *)ops {
    [_snapshotLock lock];
    @try {
        for (CRDTOperation *op in ops) {
            switch (op.operationType) {

            case CRDTOperationTypeArrayPush: {
                LDArray *arr = [self ensureArrayContainerAtPath:op.path];
                LDEntry *entry = op.entry;
                entry.meta.updatedAt = op.timestamp;
                entry.meta.replicaId = op.replicaId;
                if (op.ref) {
                    entry.meta.after = op.ref;
                } else {
                    entry.meta.after = [NSNull null];
                }
                entry.meta.afterIsSet = YES;
                arr.entries[entry.entryId] = entry;
                break;
            }

            case CRDTOperationTypeArrayUnshift: {
                LDArray *arr = [self ensureArrayContainerAtPath:op.path];
                LDEntry *entry = op.entry;
                entry.meta.updatedAt = op.timestamp;
                entry.meta.replicaId = op.replicaId;
                entry.meta.after = [NSNull null]; // head
                entry.meta.afterIsSet = YES;
                arr.entries[entry.entryId] = entry;
                break;
            }

            case CRDTOperationTypeArrayRemove: {
                LDArray *arr = [self ensureArrayContainerAtPath:op.path];
                LDEntry *target = arr.entries[op.ref];
                if (target) {
                    BOOL currentlyTombstoned =
                        (target.meta.tombstone != nil &&
                         [target.meta.tombstone boolValue]);
                    if (!currentlyTombstoned ||
                        target.meta.updatedAt <= op.timestamp) {
                        target.meta.tombstone = @YES;
                        target.meta.updatedAt = op.timestamp;
                        target.meta.replicaId = op.replicaId;
                    }
                }
                break;
            }

            case CRDTOperationTypeRemove: {
                NSString *key = op.path.lastObject ?: @"";
                if (op.path.count == 1) {
                    [_snapshot.index removeObjectForKey:key];
                } else {
                    NSError *navErr = nil;
                    LDContainer *parent = [self navigateToParentPath:op.path
                                                         forceCreate:NO
                                                               error:&navErr];
                    if (parent) {
                        if (parent.kind == LDContainerKindMap) {
                            [parent.map.index removeObjectForKey:key];
                        } else {
                            [parent.array.entries removeObjectForKey:key];
                        }
                    }
                }
                break;
            }

            case CRDTOperationTypeAdd: {
                LDEntry *entry = op.entry;
                if (!entry)
                    continue;

                [self ensureMapParentsWithRoot:_snapshot
                                          path:op.path
                                            ts:op.timestamp
                                     replicaId:op.replicaId];

                NSString *key = op.path.lastObject ?: @"";
                NSError *navErr = nil;
                LDContainer *parent = [self navigateToParentPath:op.path
                                                     forceCreate:YES
                                                           error:&navErr];
                if (!parent)
                    continue;

                if (parent.kind == LDContainerKindMap) {
                    parent.map.index[key] = entry;
                } else {
                    parent.array.entries[key] = entry;
                }
                break;
            }

            case CRDTOperationTypeReplace: {
                [self ensureMapParentsWithRoot:_snapshot
                                          path:op.path
                                            ts:op.timestamp
                                     replicaId:op.replicaId];

                NSString *key = op.path.lastObject ?: @"";
                NSError *navErr = nil;
                LDContainer *parent = [self navigateToParentPath:op.path
                                                     forceCreate:YES
                                                           error:&navErr];

                if (!parent) {
                    // Fallback: array element upsert
                    if (op.path.count >= 3) {
                        NSArray<NSString *> *arrayPath = [op.path
                            subarrayWithRange:NSMakeRange(0,
                                                          op.path.count - 2)];
                        NSString *elemId = op.path[op.path.count - 2];

                        LDValue *cont = [self getContainerAtPath:arrayPath];
                        if (cont && cont.type == LDValueTypeArray) {
                            LDArray *a = cont.arrayValue;
                            if (a.entries[elemId] == nil) {
                                LDMeta *elemMeta = [[LDMeta alloc]
                                    initWithUpdatedAt:op.timestamp
                                              version:1
                                            replicaId:op.replicaId
                                                order:nil
                                            tombstone:nil
                                                after:[NSNull null]
                                           afterIsSet:YES
                                                 next:nil];
                                a.entries[elemId] = [[LDEntry alloc]
                                    initWithId:elemId
                                           key:elemId
                                          type:LDEntryTypeObject
                                         value:[LDValue mapValue:[[LDMap alloc]
                                                                     init]]
                                          meta:elemMeta];
                            }

                            NSError *retryErr = nil;
                            parent = [self navigateToParentPath:op.path
                                                    forceCreate:NO
                                                          error:&retryErr];
                            if (!parent)
                                continue;
                        } else {
                            continue;
                        }
                    } else {
                        continue;
                    }
                }

                if (parent.kind == LDContainerKindMap) {
                    parent.map.index[key] = op.entry;
                } else {
                    parent.array.entries[key] = op.entry;
                }
                break;
            }
            }
        }

        // Collect listener notifications WITHOUT invoking them yet.
        // We must release the lock before firing callbacks, otherwise a
        // listener that calls back into the CRDT (or dispatches to another
        // queue that waits on the CRDT) would deadlock.
        NSMutableSet<NSString *> *affectedPaths = [NSMutableSet set];
        for (CRDTOperation *op in ops) {
            [affectedPaths addObject:[op.path componentsJoinedByString:@"."]];
        }

        NSDictionary<NSString *, NSMutableArray<CRDTListener> *>
            *snapshotListeners = [_listeners copy];

        // Build {json value, [callbacks]} pairs while holding the lock.
        NSMutableArray<NSDictionary *> *toFire = [NSMutableArray array];
        for (NSString *subPath in snapshotListeners) {
            NSArray<CRDTListener> *cbs = [snapshotListeners[subPath] copy];
            if (cbs.count == 0)
                continue;
            BOOL affected = NO;
            for (NSString *ap in affectedPaths) {
                if ([ap hasPrefix:subPath]) {
                    affected = YES;
                    break;
                }
            }
            if (!affected)
                continue;

            NSArray<NSString *> *segments;
            if (subPath.length == 0) {
                segments = @[];
            } else {
                segments = [subPath componentsSeparatedByString:@"."];
            }

            NSError *navErr = nil;
            LDValue *navResult = [self navigatePath:segments error:&navErr];
            id json = navResult ? [Utils toAny:navResult] : [NSNull null];

            [toFire addObject:@{@"value" : json, @"cbs" : cbs}];
        }

        [_snapshotLock unlock];

        // Fire listeners OUTSIDE the lock to avoid reentrancy/deadlock.
        for (NSDictionary *entry in toFire) {
            id value = entry[@"value"];
            NSArray<CRDTListener> *cbs = entry[@"cbs"];
            for (CRDTListener cb in cbs) {
                cb(value);
            }
        }
        return;
    } @catch (id e) {
        [_snapshotLock unlock];
        @throw;
    }
}

- (CRDTQueryHandle *)queryWithPath:(nullable NSString *)path {
    NSArray<NSString *> *segments;
    if (path && path.length > 0 && ![path isEqualToString:@"index"]) {
        segments = [path componentsSeparatedByString:@"."];
    } else {
        segments = @[];
    }

    __weak typeof(self) weakSelf = self;
    NSString *listenerKey = path ?: @"";

    CRDTQueryHandle *handle = [[CRDTQueryHandle alloc] init];

    handle.executeBlock = ^(QueryResultCompletion completion) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          completion(nil);
          return;
      }
      id result = [strongSelf withSnapshotLock:^id {
        NSError *err = nil;
        LDValue *val = [strongSelf navigatePath:segments error:&err];
        return val ? [Utils toAny:val] : nil;
      }];
      completion(result);
    };

    handle.listenBlock = ^UnsubscribeBlock(CRDTListener cb) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf) {
          return ^{
          };
      }

      dispatch_sync(strongSelf.queue, ^{
        NSMutableArray<CRDTListener> *arr = strongSelf.listeners[listenerKey];
        if (!arr) {
            arr = [NSMutableArray array];
            strongSelf.listeners[listenerKey] = arr;
        }
        [arr addObject:[cb copy]];
      });

      id initialValue = [strongSelf withSnapshotLock:^id {
        NSError *err = nil;
        LDValue *val = [strongSelf navigatePath:segments error:&err];
        return val ? [Utils toAny:val] : [NSNull null];
      }];
      cb(initialValue);

      return ^{
        __strong typeof(weakSelf) strongSelf2 = weakSelf;
        if (strongSelf2) {
            [strongSelf2.listeners[listenerKey] removeAllObjects];
        }
      };
    };

    return handle;
}

@end
