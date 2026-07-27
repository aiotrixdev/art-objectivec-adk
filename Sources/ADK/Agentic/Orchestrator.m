//
//  Orchestrator.m
//  ADK
//

#import "Orchestrator.h"
#import "OrchestratorThread.h"
#import "Subscription.h"

@interface Orchestrator ()
@property(nonatomic, copy, readwrite) NSString *orchestratorId;
@end

@implementation Orchestrator

- (instancetype)initWithOrchestratorId:(NSString *)orchestratorId
                                socket:(Socket *)socket {
    self = [super initWithSocket:socket];
    if (self) {
        _orchestratorId = [orchestratorId copy];
    }
    return self;
}

- (NSString *)channelName {
    return [NSString stringWithFormat:@"orch_com_%@", self.orchestratorId];
}

- (void)thread:(void (^)(OrchestratorThread *_Nullable,
                         NSError *_Nullable))completion {
    [self threadWithId:nil completion:completion];
}

- (void)threadWithId:(nullable NSString *)threadId
          completion:(void (^)(OrchestratorThread *_Nullable,
                               NSError *_Nullable))completion {
    [self getSubscription:^(Subscription *_Nullable sub,
                            NSError *_Nullable error) {
      if (error || !sub) {
          completion(nil, error);
          return;
      }
      OrchestratorThread *t = [sub threadUnchecked:threadId];
      completion(t, nil);
    }];
}

@end
