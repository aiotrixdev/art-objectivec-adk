#ifndef ARTADK_CRDT_CRDT_H
#define ARTADK_CRDT_CRDT_H

#pragma once

//
//  CRDT.h
//  ADK
//

#import "CRDTTypes.h"
#import "Utils.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class CRDT;
@class CRDTProxy;
@class CRDTQueryHandle;

typedef void (^CRDTListener)(id _Nullable value);

typedef void (^CRDTMergeCallback)(NSArray<CRDTOperation *> *ops);

@interface CRDTProxy : NSObject

/// Navigate into an object property by string key.
- (CRDTProxy *)objectForKeyedSubscript:(NSString *)key;

/// Navigate into an array element by numeric index.
- (CRDTProxy *)objectAtIndexedSubscript:(NSUInteger)idx;

/// Read the current scalar / tree value at this path.
- (nullable id)value;

/// Replace the value at this path.
- (void)set:(nullable id)value;

/// Delete the value at this path.
- (void)deleteValue;

/// Append one or more items to the array at this path.
- (NSInteger)pushItems:(NSArray *)items;

/// Append a single item to the array at this path.
- (NSInteger)pushItem:(id)item;

/// Prepend one or more items to the array at this path.
- (NSInteger)unshiftItems:(NSArray *)items;

/// Prepend a single item to the array at this path.
- (NSInteger)unshiftItem:(id)item;

/// Remove and return the last element of the array at this path.
- (nullable id)pop;

/// Remove and return the element at the given index.
- (nullable id)removeAtIndex:(NSInteger)index;

/// Splice the array: delete `deleteCount` elements starting at `start`
/// then insert `items` at that position. Returns the removed entry IDs.
- (NSArray<NSString *> *)spliceStart:(NSInteger)start
                         deleteCount:(NSInteger)deleteCount
                         insertItems:(NSArray *)items;

/// Returns the visible length of the array at this path.
- (NSInteger)length;

/// Flushes pending operations immediately.
- (void)flushWithCompletion:(nullable void (^)(void))completion;

@end

/// Handle returned by `queryWithPath:`.
@interface CRDTQueryHandle : NSObject

/// Execute a one-shot read of the value at the query path.
- (void)executeWithCompletion:(void (^)(id _Nullable result))completion;

/// Start listening for changes. The callback is invoked immediately with
/// the current value, then again on every relevant merge.
/// Returns an unsubscribe block.
- (void (^)(void))listenWithCallback:(CRDTListener)callback;

@end

/// The core CRDT engine. Maintains an LDMap snapshot, accepts local
/// mutations via proxy, and merges remote operations.
@interface CRDT : NSObject

/// Designated initialiser.
/// @param initial  The initial snapshot (e.g. from server).
/// @param mergeCallback Invoked with compacted ops after every flush.
- (instancetype)initWithInitial:(LDMap *)initial
                  mergeCallback:(CRDTMergeCallback)mergeCallback
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Returns the root proxy for reading / writing state.
- (CRDTProxy *)state;

/// Replace the merge callback (e.g. after reconnect).
- (void)setMergeCallback:(CRDTMergeCallback)callback;

/// Set the client replica ID (assigned after auth).
- (void)setReplicaId:(NSString *)replicaId;

/// Returns the current replica ID.
- (NSString *)getReplicaId;

/// Returns the raw snapshot.
- (LDMap *)getState;

/// Flush all pending operations immediately.
- (void)flush:(nullable void (^)(void))completion;

/// Merge remote operations into the local snapshot and notify listeners.
- (void)merge:(NSArray<CRDTOperation *> *)ops;

/// Create a query handle for the given dot-separated path (or nil / empty
/// for root).
- (CRDTQueryHandle *)queryWithPath:(nullable NSString *)path;

/// The client replica ID used for all local operations.
@property(nonatomic, copy) NSString *clientReplicaId;

- (void)appendPendingOp:(CRDTOperation *)op;
- (void)appendPendingOps:(NSArray<CRDTOperation *> *)ops;
- (void)scheduleFlush;
- (nullable id)readJSONAtPath:(NSArray<NSString *> *)path;
- (nullable LDValue *)getContainerAtPath:(NSArray<NSString *> *)path;
- (LDArray *)ensureArrayContainerAtPath:(NSArray<NSString *> *)path;
- (NSArray<NSString *> *)visibleIdsForPath:(NSArray<NSString *> *)path;
- (nullable NSString *)getArrayIdAtPath:(NSArray<NSString *> *)path
                                  index:(NSInteger)idx;
- (NSArray<CRDTOperation *> *)ensureParentsOpsForPath:
    (NSArray<NSString *> *)full;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_CRDT_CRDT_H */
