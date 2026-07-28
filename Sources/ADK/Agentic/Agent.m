//
//  Agent.m
//  ADK
//

#import "Agent.h"
#import "AgentThread.h"

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

@end
