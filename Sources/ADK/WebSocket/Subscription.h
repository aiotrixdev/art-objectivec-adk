//
//  Subscription.h
//  ADK
//

#import "BaseSubscription.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Subscription : BaseSubscription

- (void)listen:(void (^)(NSDictionary<NSString *, id> *message))callback;

- (void)bind:(NSString *)event callback:(void (^)(id content))callback;

- (void)remove:(NSString *)event;

- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload;

@end

NS_ASSUME_NONNULL_END
