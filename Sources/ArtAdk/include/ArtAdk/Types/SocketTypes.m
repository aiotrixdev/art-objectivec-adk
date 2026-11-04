//
//  SocketTypes.m
//  ADK
//

#import "SocketTypes.h"
#import "ARTSupport.h"

NSErrorDomain const ARTConnectionErrorDomain = @"com.art.adk.connection";
NSErrorUserInfoKey const ARTConnectionErrorCodeKey = @"ARTConnectionErrorCode";

ARTConnectionErrorCode const ARTConnectionErrorCodeTimeout = @"CONNECTION_TIMEOUT";
ARTConnectionErrorCode const ARTConnectionErrorCodeLost = @"CONNECTION_LOST";
ARTConnectionErrorCode const ARTConnectionErrorCodePaused = @"CONNECTION_PAUSED";
ARTConnectionErrorCode const ARTConnectionErrorCodeClosed = @"CONNECTION_CLOSED";
ARTConnectionErrorCode const ARTConnectionErrorCodeCancelled = @"CONNECTION_CANCELLED";
ARTConnectionErrorCode const ARTConnectionErrorCodeAuthorizationFailed =
    @"CONNECTION_AUTHORIZATION_FAILED";
ARTConnectionErrorCode const ARTConnectionErrorCodeAuthenticationFailed =
    @"AUTHENTICATION_FAILED";
ARTConnectionErrorCode const ARTConnectionErrorCodeAckTimeout = @"ACK_TIMEOUT";
ARTConnectionErrorCode const ARTConnectionErrorCodeMinutesLimitExceeded =
    @"CONNECTION_MINUTES_LIMIT_EXCEEDED";
ARTConnectionErrorCode const ARTConnectionErrorCodeConcurrentLimitExceeded =
    @"CONCURRENT_LIMIT_EXCEEDED";

ARTExecutionOrigin const ARTExecutionOriginPlayground = @"playground";

@implementation ARTConnectionError

+ (instancetype)errorWithMessage:(NSString *)message
                            code:(ARTConnectionErrorCode)code
                          status:(NSNumber *)status {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message ?: @"";
    userInfo[ARTConnectionErrorCodeKey] = code ?: @"";
    if (status) {
        userInfo[ARTHTTPStatusCodeKey] = status;
    }
    return [self errorWithDomain:ARTConnectionErrorDomain code:1 userInfo:userInfo];
}

+ (instancetype)errorWithMessage:(NSString *)message code:(ARTConnectionErrorCode)code {
    return [self errorWithMessage:message code:code status:nil];
}

- (ARTConnectionErrorCode)connectionCode {
    return self.userInfo[ARTConnectionErrorCodeKey] ?: @"";
}

- (NSString *)message {
    return self.userInfo[NSLocalizedDescriptionKey] ?: @"";
}

- (NSNumber *)status {
    return self.userInfo[ARTHTTPStatusCodeKey];
}

- (NSString *)description {
    if (self.status) {
        return [NSString stringWithFormat:@"%@ (%@): %@", self.connectionCode,
                                          self.status, self.message];
    }
    return [NSString stringWithFormat:@"%@: %@", self.connectionCode, self.message];
}

@end

@implementation ARTAuthenticationFailedDetail

- (instancetype)initWithStatus:(NSInteger)status error:(NSString *)error {
    self = [super init];
    if (self) {
        _status = status;
        _error = [error copy] ?: @"";
    }
    return self;
}

@end

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
        _to = [to copy] ?: @[];
        _fileMeta = @[];
    }
    return self;
}

- (instancetype)initWithTo:(NSArray<NSString *> *)to
                  threadID:(NSString *)threadID {
    return [self initWithTo:to threadID:threadID fileMeta:nil];
}

- (instancetype)initWithTo:(NSArray<NSString *> *)to
                  threadID:(NSString *)threadID
                  fileMeta:(NSArray<ARTMediaRef *> *)fileMeta {
    return [self initWithTo:to threadID:threadID fileMeta:fileMeta executionOrigin:nil];
}

- (instancetype)initWithTo:(NSArray<NSString *> *)to
                  threadID:(NSString *)threadID
                  fileMeta:(NSArray<ARTMediaRef *> *)fileMeta
           executionOrigin:(ARTExecutionOrigin)executionOrigin {
    self = [self initWithTo:to];
    if (self) {
        _threadID = [threadID copy];
        _fileMeta = [fileMeta copy] ?: @[];
        _executionOrigin = [executionOrigin copy];
    }
    return self;
}

- (void)setFileMeta:(NSArray<ARTMediaRef *> *)fileMeta {
    _fileMeta = [fileMeta copy] ?: @[];
}

- (id)copyWithZone:(NSZone *)zone {
    return [[PushConfig allocWithZone:zone] initWithTo:self.to
                                              threadID:self.threadID
                                              fileMeta:self.fileMeta
                                       executionOrigin:self.executionOrigin];
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
        _method = [method copy] ?: @"GET";
        _payload = payload;
        _queryParams = [queryParams copy];
        _headers = [headers copy];
    }
    return self;
}

- (instancetype)initWithMethod:(NSString *)method
                       payload:(id)payload
                   queryParams:
                       (NSDictionary<NSString *, NSString *> *)queryParams
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                       baseUrl:(NSString *)baseUrl
                     timeoutMs:(NSNumber *)timeoutMs {
    self = [self initWithMethod:method
                        payload:payload
                    queryParams:queryParams
                        headers:headers];
    if (self) {
        _baseUrl = [baseUrl copy];
        _timeoutMs = timeoutMs;
    }
    return self;
}

@end

@implementation ARTFormDataFile

- (instancetype)initWithField:(NSString *)field
                         data:(NSData *)data
                     filename:(NSString *)filename
                  contentType:(NSString *)contentType {
    self = [super init];
    if (self) {
        _field = [field copy];
        _data = [data copy];
        _filename = [filename copy];
        _contentType = [contentType copy];
    }
    return self;
}

@end

@implementation ARTFormDataPayload

- (instancetype)init {
    return [self initWithFields:nil files:nil];
}

- (instancetype)initWithFields:(NSDictionary<NSString *, NSString *> *)fields
                         files:(NSArray<ARTFormDataFile *> *)files {
    self = [super init];
    if (self) {
        _fields = [fields copy] ?: @{};
        _files = [files copy] ?: @[];
    }
    return self;
}

@end

@implementation ARTUpdateProfileData

- (NSDictionary<NSString *, id> *)payload {
    NSMutableDictionary<NSString *, id> *body = [NSMutableDictionary dictionary];
    if (self.firstName) {
        body[@"first_name"] = self.firstName;
    }
    if (self.lastName) {
        body[@"last_name"] = self.lastName;
    }
    if (self.email) {
        body[@"email"] = self.email;
    }
    if (self.attributes) {
        body[@"attributes"] = self.attributes;
    }
    return [body copy];
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
