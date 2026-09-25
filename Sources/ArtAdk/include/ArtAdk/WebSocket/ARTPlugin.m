//
//  ARTPlugin.m
//  ADK
//

#import "ARTPlugin.h"
#import "Utils.h"

@interface ARTAdkPluginContext ()
@property(nonatomic, copy) ARTPluginSubscribeBlock subscribeBlock;
@property(nonatomic, copy) ARTPluginCallBlock callBlock;
@property(nonatomic, copy) AuthenticationConfig *_Nullable (^credentialsBlock)(void);
@property(nonatomic, copy) NSString * (^baseUrlBlock)(void);
@end

@implementation ARTAdkPluginContext

- (instancetype)
    initWithSubscribe:(ARTPluginSubscribeBlock)subscribe
                 call:(ARTPluginCallBlock)call
       getCredentials:(AuthenticationConfig *_Nullable (^)(void))getCredentials
              baseUrl:(NSString * (^)(void))baseUrl {
    self = [super init];
    if (self) {
        _subscribeBlock = [subscribe copy];
        _callBlock = [call copy];
        _credentialsBlock = [getCredentials copy];
        _baseUrlBlock = [baseUrl copy];
    }
    return self;
}

- (void)subscribe:(NSString *)channel
       completion:(void (^)(BaseSubscription *_Nullable,
                            NSError *_Nullable))completion {
    self.subscribeBlock(channel, completion);
}

- (void)call:(NSString *)endpoint
       options:(CallApiProps *)options
    completion:(void (^)(id _Nullable, NSError *_Nullable))completion {
    self.callBlock(endpoint, options, completion);
}

- (AuthenticationConfig *)getCredentials:(NSError **)error {
    AuthenticationConfig *credentials = self.credentialsBlock();
    if (!credentials && error) {
        *error = MakeError(ErrorCodeForbidden,
                           @"Auth not initialised – call connect first");
    }
    return credentials;
}

- (NSString *)baseUrl {
    return self.baseUrlBlock();
}

@end
