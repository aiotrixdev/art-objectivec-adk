//
//  ChannelTypes.m
//  ADK
//

#import "ChannelTypes.h"

@implementation ChannelConfig

- (instancetype)initWithChannelName:(NSString *)channelName {
    return [self initWithChannelName:channelName
                    channelNamespace:@""
                         channelType:@"default"
                       presenceUsers:@[]
                            snapshot:nil
                      subscriptionID:nil];
}

- (instancetype)initWithChannelName:(NSString *)channelName
                   channelNamespace:(NSString *)channelNamespace
                        channelType:(NSString *)channelType
                      presenceUsers:(NSArray<NSString *> *)presenceUsers
                           snapshot:(id)snapshot
                     subscriptionID:(NSString *)subscriptionID {
    self = [super init];
    if (self) {
        _channelName = [channelName copy];
        _channelNamespace = [channelNamespace copy];
        _channelType = [channelType copy];
        _presenceUsers = [presenceUsers copy];
        _snapshot = snapshot;
        _subscriptionID = [subscriptionID copy];
    }
    return self;
}

@end
