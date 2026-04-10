//
//  EventEmitter.m
//  ADK
//

#import "EventEmitter.h"

static NSString *const kListenerIdKey = @"id";
static NSString *const kListenerHandlerKey = @"handler";

@interface EventEmitter ()

@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *>
        *listeners;

@property(nonatomic, strong) NSLock *lock;

@end

@implementation EventEmitter

- (instancetype)init {
    self = [super init];
    if (self) {
        _listeners = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (NSUUID *)on:(NSString *)event handler:(void (^)(id))handler {
    NSUUID *identifier = [NSUUID UUID];
    NSDictionary *entry =
        @{kListenerIdKey : identifier, kListenerHandlerKey : [handler copy]};

    [_lock lock];
    NSMutableArray *eventListeners = _listeners[event];
    if (!eventListeners) {
        eventListeners = [NSMutableArray array];
        _listeners[event] = eventListeners;
    }
    [eventListeners addObject:entry];
    [_lock unlock];

    return identifier;
}

- (void)off:(NSString *)event identifier:(NSUUID *)identifier {
    [_lock lock];
    NSMutableArray *eventListeners = _listeners[event];
    if (eventListeners) {
        NSIndexSet *indexes = [eventListeners
            indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry,
                                              NSUInteger idx, BOOL *stop) {
              return [entry[kListenerIdKey] isEqual:identifier];
            }];
        [eventListeners removeObjectsAtIndexes:indexes];
    }
    [_lock unlock];
}

- (void)offEvent:(NSString *)event {
    [_lock lock];
    [_listeners removeObjectForKey:event];
    [_lock unlock];
}

- (void)removeAllListeners {
    [_lock lock];
    [_listeners removeAllObjects];
    [_lock unlock];
}

- (void)emit:(NSString *)event data:(id)data {
    id emitData = data ?: [NSNull null];

    [_lock lock];
    NSArray<NSDictionary *> *snapshot = [_listeners[event] copy];
    [_lock unlock];

    for (NSDictionary *entry in snapshot) {
        void (^handler)(id) = entry[kListenerHandlerKey];
        if (handler) {
            handler(emitData);
        }
    }
}

- (NSInteger)listenerCount:(NSString *)event {
    [_lock lock];
    NSInteger count = (NSInteger)_listeners[event].count;
    [_lock unlock];
    return count;
}

@end
