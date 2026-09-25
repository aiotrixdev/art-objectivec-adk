//
//  Orchestrator.m
//  ADK
//

#import "Orchestrator.h"
#import "OrchestratorThread.h"
#import "Subscription.h"
#import "ARTStorage.h"

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

#pragma mark - Storage (orchestrator-scoped)

- (void)uploadFileURL:(NSURL *)fileURL
              options:(ARTUploadOptions *)options
           completion:(void (^)(ARTFileRef *_Nullable,
                                NSError *_Nullable))completion {
    ARTUploadOptions *scoped = options ? [options copy] : [[ARTUploadOptions alloc] init];
    scoped.configId = self.orchestratorId;
    [[[ARTStorage alloc] init] uploadFileURL:fileURL
                                     options:scoped
                                  completion:completion];
}

- (void)uploadData:(NSData *)data
          filename:(NSString *)filename
       contentType:(NSString *)contentType
           options:(ARTUploadOptions *)options
        completion:(void (^)(ARTFileRef *_Nullable,
                             NSError *_Nullable))completion {
    ARTUploadOptions *scoped = options ? [options copy] : [[ARTUploadOptions alloc] init];
    scoped.configId = self.orchestratorId;
    [[[ARTStorage alloc] init] uploadData:data
                                 filename:filename
                              contentType:contentType
                                  options:scoped
                               completion:completion];
}

- (void)listFilesWithOptions:(ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable,
                                       NSError *_Nullable))completion {
    ARTListOptions *scoped = options ? [options copy] : [[ARTListOptions alloc] init];
    scoped.configId = self.orchestratorId;
    [[[ARTStorage alloc] init] listFilesWithOptions:scoped completion:completion];
}

@end
