//
//  LiveObjSubscription.h
//  ADK
//


#import <Foundation/Foundation.h>
#import "BaseSubscription.h"
#import "../CRDT/CRDT.h"

NS_ASSUME_NONNULL_BEGIN

@interface LiveObjSubscription : BaseSubscription

@property (nonatomic, strong, readonly) CRDT *crdt;

- (CRDTProxy *)state;

- (void)flush:(void(^)(void))completion;

- (CRDTQueryHandle *)query:(nullable NSString *)path;

- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload;

@end

NS_ASSUME_NONNULL_END
