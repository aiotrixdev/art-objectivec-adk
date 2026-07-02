//
//  OrchestratorThread.m
//  ADK
//

#import "OrchestratorThread.h"
#import "Subscription.h"

@interface OrchestratorThread ()
@property(nonatomic, strong) Subscription *subscription;
@property(nonatomic, strong) NSMutableSet<NSString *> *attachedEvents;
@property(nonatomic, assign, readwrite, getter=isDisposed) BOOL disposed;
@end

@implementation OrchestratorThread

- (instancetype)initWithSubscription:(Subscription *)subscription
                            threadId:(NSString *)threadId {
    self = [super init];
    if (self) {
        _subscription = subscription;
        _threadId = threadId.length ? [threadId copy] : [[self class] generateThreadId];
        _attachedEvents = [NSMutableSet set];
        _disposed = NO;
    }
    return self;
}

+ (NSString *)generateThreadId {
    long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    uint32_t value = arc4random();
    static const char *digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    char buf[8];
    int i = 8;
    if (value == 0) {
        buf[--i] = '0';
    }
    while (value > 0 && i > 0) {
        buf[--i] = digits[value % 36];
        value /= 36;
    }
    NSString *rand = [[NSString alloc] initWithBytes:buf + i
                                              length:(NSUInteger)(8 - i)
                                            encoding:NSASCIIStringEncoding];
    return [NSString stringWithFormat:@"thread_%lld_%@", ts, rand];
}

- (void)push:(NSString *)event
        data:(NSDictionary<NSString *, id> *)data
  completion:(void (^)(NSError *_Nullable))completion {
    if (self.disposed) {
        if (completion) {
            completion([NSError
                errorWithDomain:@"ADK.OrchestratorThread"
                           code:-1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               [NSString stringWithFormat:
                                             @"OrchestratorThread %@ disposed",
                                             self.threadId]
                       }]);
        }
        return;
    }
    PushConfig *options = [[PushConfig alloc] initWithTo:@[] threadID:self.threadId];
    [self.subscription push:event
                        data:data
                     options:options
                  completion:^(NSError *_Nullable error) {
                    if (completion) {
                        completion(error);
                    }
                  }];
}

- (void)listen:(void (^)(NSDictionary<NSString *, id> *))callback {
    if (self.disposed) {
        return;
    }
    [self.subscription attachThreadListener:self.threadId callback:callback];
    [self.attachedEvents addObject:@"all"];
}

- (void)bind:(NSString *)event callback:(void (^)(id))callback {
    if (self.disposed) {
        return;
    }
    [self.subscription attachThreadBind:self.threadId event:event callback:callback];
    [self.attachedEvents addObject:event];
}

- (void)remove:(NSString *)event {
    if (self.disposed) {
        return;
    }
    [self.subscription detachThreadListener:self.threadId event:event];
    [self.attachedEvents removeObject:event];
}

- (void)dispose {
    if (self.disposed) {
        return;
    }
    self.disposed = YES;
    for (NSString *event in [self.attachedEvents copy]) {
        [self.subscription detachThreadListener:self.threadId event:event];
    }
    [self.attachedEvents removeAllObjects];
    [self.subscription unregisterThread:self.threadId];
}

@end
