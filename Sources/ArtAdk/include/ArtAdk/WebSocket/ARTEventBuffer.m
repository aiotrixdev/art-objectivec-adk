//
//  ARTEventBuffer.m
//  ADK
//

#import "ARTEventBuffer.h"

@interface ARTEventBuffer ()
@property(nonatomic, strong) NSMutableArray<NSString *> *order;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *items;
@end

@implementation ARTEventBuffer

- (instancetype)init {
    self = [super init];
    if (self) {
        _order = [NSMutableArray array];
        _items = [NSMutableDictionary dictionary];
    }
    return self;
}

+ (instancetype)bufferWithDictionary:
    (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)dictionary {
    ARTEventBuffer *buffer = [[ARTEventBuffer alloc] init];
    for (NSString *event in
         [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        for (NSDictionary *entry in dictionary[event]) {
            [buffer appendEvent:event entry:entry];
        }
    }
    return buffer;
}

- (BOOL)isEmpty {
    return self.order.count == 0;
}

- (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)dictionary {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    [self.items enumerateKeysAndObjectsUsingBlock:^(
                    NSString *event, NSMutableArray *entries, BOOL *stop) {
      snapshot[event] = [entries copy];
    }];
    return [snapshot copy];
}

- (void)appendEvent:(NSString *)event entry:(NSDictionary *)entry {
    NSMutableArray *entries = self.items[event];
    if (!entries) {
        entries = [NSMutableArray array];
        self.items[event] = entries;
        [self.order addObject:event];
    }
    [entries addObject:entry];
}

- (NSArray<NSDictionary *> *)takeEvent:(NSString *)event {
    NSArray *entries = [self.items[event] copy];
    if (!entries) {
        return @[];
    }
    [self.items removeObjectForKey:event];
    [self.order removeObject:event];
    return entries;
}

- (NSArray<NSArray *> *)drainAll {
    NSMutableArray<NSArray *> *drained = [NSMutableArray array];
    for (NSString *event in self.order) {
        for (NSDictionary *entry in self.items[event]) {
            [drained addObject:@[ event, entry ]];
        }
    }
    [self.order removeAllObjects];
    [self.items removeAllObjects];
    return drained;
}

@end
