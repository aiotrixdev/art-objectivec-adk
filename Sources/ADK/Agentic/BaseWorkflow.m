//
//  BaseWorkflow.m
//  ADK
//

#import "BaseWorkflow.h"
#import "Socket.h"
#import "Subscription.h"

typedef void (^ARTSubscriptionWaiter)(Subscription *_Nullable, NSError *_Nullable);

@interface BaseWorkflow ()
@property(nonatomic, strong, readwrite, nullable) Subscription *subscription;
@property(nonatomic, assign) BOOL subscribing;
@property(nonatomic, strong) NSMutableArray<ARTSubscriptionWaiter> *waiters;
@property(nonatomic, strong) NSLock *lock;
@end

@implementation BaseWorkflow

- (instancetype)initWithSocket:(Socket *)socket {
    self = [super init];
    if (self) {
        _socket = socket;
        _waiters = [NSMutableArray array];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (NSString *)channelName {
    NSAssert(NO, @"BaseWorkflow subclasses must override channelName");
    return @"";
}

- (void)getSubscription:(ARTSubscriptionWaiter)completion {
    [self.lock lock];
    if (self.subscription) {
        Subscription *sub = self.subscription;
        [self.lock unlock];
        completion(sub, nil);
        return;
    }
    [self.waiters addObject:[completion copy]];
    if (self.subscribing) {
        // Coalesced — the in-flight subscribe will flush us.
        [self.lock unlock];
        return;
    }
    self.subscribing = YES;
    [self.lock unlock];

    NSString *channel = [self channelName];
    __weak typeof(self) weakSelf = self;
    [self.socket
        subscribe:channel
       completion:^(BaseSubscription *_Nullable raw, NSError *_Nullable error) {
         __strong typeof(weakSelf) strongSelf = weakSelf;
         if (!strongSelf) {
             return;
         }
         Subscription *typed = [raw isKindOfClass:[Subscription class]]
                                   ? (Subscription *)raw
                                   : nil;
         NSError *outErr = error;
         if (!typed && !outErr) {
             outErr = [NSError
                 errorWithDomain:@"ADK.BaseWorkflow"
                            code:-1
                        userInfo:@{
                            NSLocalizedDescriptionKey :
                                [NSString stringWithFormat:
                                              @"Channel %@ did not yield a "
                                              @"Subscription",
                                              channel]
                        }];
         }

         NSArray<ARTSubscriptionWaiter> *pending;
         [strongSelf.lock lock];
         if (typed && !error) {
             strongSelf.subscription = typed;
         }
         strongSelf.subscribing = NO;
         pending = [strongSelf.waiters copy];
         [strongSelf.waiters removeAllObjects];
         [strongSelf.lock unlock];

         for (ARTSubscriptionWaiter waiter in pending) {
             waiter(typed, typed ? nil : outErr);
         }
       }];
}

@end
