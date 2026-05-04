//
//  SocketTypes.m
//  ADK
//

#import "SocketTypes.h"

@implementation ConnectionDetail

- (instancetype)initWithConnectionId:(NSString *)connectionId
                          instanceId:(NSString *)instanceId
                          tenantName:(NSString *)tenantName
                         environment:(NSString *)environment
                          projectKey:(NSString *)projectKey {
    self = [super init];
    if (self) {
        _connectionId = [connectionId copy];
        _instanceId = [instanceId copy];
        _tenantName = [tenantName copy];
        _environment = [environment copy];
        _projectKey = [projectKey copy];
    }
    return self;
}

- (NSString *)description {
    return [NSString
        stringWithFormat:@"<%@: connectionId=%@, instanceId=%@, tenantName=%@, "
                         @"environment=%@, projectKey=%@>",
                         NSStringFromClass([self class]), _connectionId,
                         _instanceId, _tenantName, _environment, _projectKey];
}

@end

@implementation PushConfig

- (instancetype)init {
    return [self initWithTo:@[]];
}

- (instancetype)initWithTo:(NSArray<NSString *> *)to {
    self = [super init];
    if (self) {
        _to = [to copy];
    }
    return self;
}

@end

@implementation CallApiProps

- (instancetype)init {
    return [self initWithMethod:@"GET" payload:nil queryParams:nil headers:nil];
}

- (instancetype)initWithMethod:(NSString *)method
                       payload:(id)payload
                   queryParams:
                       (NSDictionary<NSString *, NSString *> *)queryParams
                       headers:(NSDictionary<NSString *, NSString *> *)headers {
    self = [super init];
    if (self) {
        _method = [method copy];
        _payload = payload;
        _queryParams = [queryParams copy];
        _headers = [headers copy];
    }
    return self;
}

@end

@implementation LongPollOptions

- (instancetype)initWithEndpoint:(NSString *)endpoint
                  getAuthHeaders:
                      (void (^)(void (^)(NSDictionary<NSString *, NSString *> *,
                                         NSError *)))getAuthHeaders
                      onMessages:(void (^)(NSArray *))onMessages {
    return [self initWithEndpoint:endpoint
              initialConnectionId:nil
                   getAuthHeaders:getAuthHeaders
                       onMessages:onMessages
                          onError:nil
                     retryDelayMs:1000
                 emptyPollDelayMs:500
              maxEmptyPollDelayMs:5000];
}

- (instancetype)initWithEndpoint:(NSString *)endpoint
             initialConnectionId:(NSString *)initialConnectionId
                  getAuthHeaders:
                      (void (^)(void (^)(NSDictionary<NSString *, NSString *> *,
                                         NSError *)))getAuthHeaders
                      onMessages:(void (^)(NSArray *))onMessages
                         onError:(void (^)(NSError *))onError
                    retryDelayMs:(NSInteger)retryDelayMs
                emptyPollDelayMs:(NSInteger)emptyPollDelayMs
             maxEmptyPollDelayMs:(NSInteger)maxEmptyPollDelayMs {
    self = [super init];
    if (self) {
        _endpoint = [endpoint copy];
        _initialConnectionId = [initialConnectionId copy];
        _getAuthHeaders = [getAuthHeaders copy];
        _onMessages = [onMessages copy];
        _onError = [onError copy];
        _retryDelayMs = retryDelayMs;
        _emptyPollDelayMs = emptyPollDelayMs;
        _maxEmptyPollDelayMs = maxEmptyPollDelayMs;
    }
    return self;
}

@end
