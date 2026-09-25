//
//  Agent.m
//  ADK
//

#import "Agent.h"
#import "AgentThread.h"
#import "ARTStorage.h"

@interface Agent ()
@property(nonatomic, copy, readwrite) NSString *agentId;
@end

@implementation Agent

- (instancetype)initWithAgentId:(NSString *)agentId socket:(Socket *)socket {
    self = [super initWithSocket:socket];
    if (self) {
        _agentId = [agentId copy];
    }
    return self;
}

- (NSString *)channelName {
    return [NSString stringWithFormat:@"agent_com_%@", self.agentId];
}

- (AgentThread *)thread {
    return [[AgentThread alloc] initWithAgent:self];
}

- (AgentThread *)threadWithId:(nullable NSString *)threadId {
    return [[AgentThread alloc] initWithAgent:self threadId:threadId];
}

#pragma mark - Storage (agent-scoped)

- (void)uploadFileURL:(NSURL *)fileURL
              options:(ARTUploadOptions *)options
           completion:(void (^)(ARTFileRef *_Nullable,
                                NSError *_Nullable))completion {
    ARTUploadOptions *scoped = options ? [options copy] : [[ARTUploadOptions alloc] init];
    scoped.configId = self.agentId;
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
    scoped.configId = self.agentId;
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
    scoped.configId = self.agentId;
    [[[ARTStorage alloc] init] listFilesWithOptions:scoped completion:completion];
}

@end
