//
//  AuthTypes.m
//  ADK
//

#import "AuthTypes.h"

@implementation AdkConfig

- (instancetype)initWithUri:(NSString *)uri {
    return [self initWithUri:uri authToken:nil getCredentials:nil root:nil];
}

- (instancetype)initWithUri:(NSString *)uri
                  authToken:(NSString *)authToken
             getCredentials:(CredentialStore * (^)(void))getCredentials
                       root:(NSString *)root {
    self = [super init];
    if (self) {
        _uri = [uri copy];
        _authToken = [authToken copy];
        _getCredentials = [getCredentials copy];
        _root = [root copy];
    }
    return self;
}

@end

@implementation CredentialStore

- (instancetype)init {
    return [self initWithEnvironment:@""
                          projectKey:@""
                            orgTitle:@""
                            clientID:@""
                        clientSecret:@""
                              config:nil
                         accessToken:nil];
}

- (instancetype)initWithEnvironment:(NSString *)environment
                         projectKey:(NSString *)projectKey
                           orgTitle:(NSString *)orgTitle
                           clientID:(NSString *)clientID
                       clientSecret:(NSString *)clientSecret
                             config:(AdkConfig *)config
                        accessToken:(NSString *)accessToken {
    self = [super init];
    if (self) {
        _environment = [environment copy];
        _projectKey = [projectKey copy];
        _orgTitle = [orgTitle copy];
        _clientID = [clientID copy];
        _clientSecret = [clientSecret copy];
        _config = config;
        _accessToken = [accessToken copy];
    }
    return self;
}

@end

@implementation AuthenticationConfig

- (instancetype)init {
    return [self initWithEnvironment:@""
                          projectKey:@""
                            orgTitle:@""
                            clientID:@""
                        clientSecret:@""
                              config:nil
                         accessToken:nil
                      getCredentials:nil];
}

- (instancetype)initWithEnvironment:(NSString *)environment
                         projectKey:(NSString *)projectKey
                           orgTitle:(NSString *)orgTitle
                           clientID:(NSString *)clientID
                       clientSecret:(NSString *)clientSecret
                             config:(AdkConfig *)config
                        accessToken:(NSString *)accessToken
                     getCredentials:
                         (CredentialStore * (^)(void))getCredentials {
    self = [super init];
    if (self) {
        _environment = [environment copy];
        _projectKey = [projectKey copy];
        _orgTitle = [orgTitle copy];
        _clientID = [clientID copy];
        _clientSecret = [clientSecret copy];
        _config = config;
        _accessToken = [accessToken copy];
        _getCredentials = [getCredentials copy];
    }
    return self;
}

@end

@implementation AuthData

- (instancetype)init {
    return [self initWithAccessToken:@"" refreshToken:@""];
}

- (instancetype)initWithAccessToken:(NSString *)accessToken
                       refreshToken:(NSString *)refreshToken {
    self = [super init];
    if (self) {
        _accessToken = [accessToken copy];
        _refreshToken = [refreshToken copy];
    }
    return self;
}

@end

@implementation ConnectConfig

- (instancetype)init {
    return [self initWithRestoreConnection:NO];
}

- (instancetype)initWithRestoreConnection:(BOOL)restoreConnection {
    self = [super init];
    if (self) {
        _restoreConnection = restoreConnection;
    }
    return self;
}

@end
