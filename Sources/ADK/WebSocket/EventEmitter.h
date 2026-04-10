//
//  EventEmitter.h
//  ADK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EventEmitter : NSObject

- (NSUUID *)on:(NSString *)event handler:(void (^)(id data))handler;

- (void)off:(NSString *)event identifier:(NSUUID *)identifier;

- (void)offEvent:(NSString *)event;

- (void)removeAllListeners;

- (void)emit:(NSString *)event data:(nullable id)data;

- (NSInteger)listenerCount:(NSString *)event;

@end

NS_ASSUME_NONNULL_END
