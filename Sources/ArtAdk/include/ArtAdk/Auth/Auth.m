//
//  Auth.m
//  ADK
//

#import "Auth.h"
#import "ARTSupport.h"
#import "AuthTypes.h"
#import "Constant.h"
#import "HTTPCall.h"
#import "Utils.h"

/// Seconds before `exp` at which an access token is renewed.
static const double ARTRenewalLeewaySeconds = 30;

typedef void (^ARTAuthCompletion)(AuthData *_Nullable, NSError *_Nullable);

@interface RefreshInfo : NSObject
@property(nonatomic, assign) BOOL expired;
@property(nonatomic, strong, nullable) NSNumber *exp;
@property(nonatomic, assign) double remaining;
@end

@implementation RefreshInfo
@end

@interface Auth ()
/// Guards `credentials`, `authData`, `waiters` and `inFlight`.
@property(nonatomic, strong, readonly) NSObject *stateLock;
@property(nonatomic, strong) AuthenticationConfig *credentials;
@property(nonatomic, strong) AuthData *authData;
@property(nonatomic, strong) NSMutableArray<ARTAuthCompletion> *waiters;
@property(nonatomic, assign) BOOL inFlight;
@end

// Singleton. dispatch_once-based lock init so the lock can never be nil,
// even when +getInstance is called from several threads at launch.
static Auth *_instance = nil;

static NSLock *AuthSingletonLock(void) {
    static NSLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      lock = [[NSLock alloc] init];
    });
    return lock;
}

@implementation Auth

+ (void)reset {
    NSLock *lock = AuthSingletonLock();
    [lock lock];
    _instance = nil;
    [lock unlock];
}

- (instancetype)initWithCredentials:(AuthenticationConfig *)credentials {
    self = [super init];
    if (self) {
        _stateLock = [[NSObject alloc] init];
        _credentials = [credentials copy];
        _authData = [[AuthData alloc] init];
        _waiters = [NSMutableArray array];
    }
    return self;
}

+ (nullable Auth *)getInstance:(nullable AuthenticationConfig *)credentials
                         error:(NSError **)error {
    NSLock *lock = AuthSingletonLock();
    [lock lock];

    if (_instance != nil) {
        Auth *existing = _instance;
        [lock unlock];
        return existing;
    }

    if (credentials == nil) {
        [lock unlock];
        if (error) {
            *error = MakeError(ErrorCodeForbidden,
                               @"Auth not initialised – provide "
                               @"credentials on first call");
        }
        return nil;
    }

    _instance = [[Auth alloc] initWithCredentials:credentials];
    Auth *result = _instance;
    [lock unlock];
    return result;
}

#pragma mark - Authenticate

- (void)authenticate:(BOOL)forceAuth
          completion:(void (^)(AuthData *_Nullable,
                               NSError *_Nullable))completion {
    @synchronized(self.stateLock) {
        [self.waiters addObject:[completion copy]];
        if (self.inFlight) {
            // Joins the request already running.
            return;
        }
        self.inFlight = YES;
    }

    // The request's blocks keep this instance alive until it finishes, so
    // every waiter is called even if `+reset` runs meanwhile.
    [self authenticateOnce:forceAuth
                completion:^(AuthData *data, NSError *error) {
                  NSArray<ARTAuthCompletion> *waiters;
                  @synchronized(self.stateLock) {
                      waiters = [self.waiters copy];
                      [self.waiters removeAllObjects];
                      self.inFlight = NO;
                  }
                  for (ARTAuthCompletion waiter in waiters) {
                      waiter([data copy], error);
                  }
                }];
}

- (void)authenticateOnce:(BOOL)forceAuth completion:(ARTAuthCompletion)completion {
    AuthData *cached;
    @synchronized(self.stateLock) {
        cached = [self.authData copy];
    }
    if (!forceAuth && cached.accessToken.length > 0 &&
        ![self isTokenExpired:cached.accessToken]) {
        completion(cached, nil);
        return;
    }

    // Re-read credentials from the getCredentials hook when there is one.
    CredentialStore *_Nonnull (^getCredentials)(void);
    @synchronized(self.stateLock) {
        getCredentials = self.credentials.getCredentials;
    }
    if (getCredentials) {
        CredentialStore *cred = getCredentials();
        @synchronized(self.stateLock) {
            self.credentials.accessToken = cred.accessToken;
            self.credentials.clientID = cred.clientID;
            self.credentials.clientSecret = cred.clientSecret;
            self.credentials.orgTitle = cred.orgTitle;
            self.credentials.environment = cred.environment;
            self.credentials.projectKey = cred.projectKey;
        }
    }

    AuthenticationConfig *creds;
    @synchronized(self.stateLock) {
        creds = [self.credentials copy];
    }

    if (creds.orgTitle.length == 0 || creds.environment.length == 0 ||
        creds.projectKey.length == 0) {
        completion(
            nil,
            MakeError(ErrorCodeAuthenticationFailed,
                      @"OrgTitle, Environment and ProjectKey are required"));
        return;
    }

    // Use the refresh token while it is still valid.
    RefreshInfo *refreshInfo =
        [self getRefreshTokenExpiryInfo:cached.refreshToken];
    if (!refreshInfo.expired) {
        [self refreshAuthToken:creds
                  refreshToken:cached.refreshToken
                    completion:completion];
        return;
    }

    [self generateAuthToken:creds completion:completion];
}

#pragma mark - Generate token

- (void)generateAuthToken:(AuthenticationConfig *)credentials
               completion:(ARTAuthCompletion)completion {
    if (credentials.accessToken.length == 0) {
        if (credentials.clientID.length == 0 ||
            credentials.clientSecret.length == 0) {
            completion(nil, MakeError(ErrorCodeAuthenticationFailed,
                                      @"ClientID and ClientSecret are required "
                                      @"when AccessToken is not present."));
            return;
        }
    }

    NSMutableDictionary<NSString *, NSString *> *headers =
        [NSMutableDictionary dictionaryWithDictionary:@{
            @"Client-Id" : credentials.clientID ?: @"",
            @"Client-Secret" : credentials.clientSecret ?: @"",
            @"X-Org" : credentials.orgTitle ?: @"",
            @"Environment" : credentials.environment ?: @"",
            @"ProjectKey" : credentials.projectKey ?: @"",
        }];
    if (credentials.accessToken.length > 0) {
        headers[@"T-pass"] = credentials.accessToken;
    }
    if (credentials.config.authToken) {
        headers[@"X-pass"] = credentials.config.authToken;
    }

    NSURL *url = [NSURL
        URLWithString:[NSString stringWithFormat:@"%@/auth/token",
                                                 Constant.BASE_URL]];
    if (!url) {
        completion(nil, MakeError(ErrorCodeAuthenticationFailed,
                                  @"Incorrect auth token URL"));
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    for (NSString *key in headers) {
        [req setValue:headers[key] forHTTPHeaderField:key];
    }

    NSURLSessionDataTask *task = [ARTHTTPClient.session
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *netErr) {
            if (netErr) {
                completion(nil, netErr);
                return;
            }
            [self storeTokenResponse:response
                                    data:data
                            shapeMessage:@"Unexpected token response shape"
                              completion:completion];
          }];
    [task resume];
}

#pragma mark - Refresh token

- (void)refreshAuthToken:(AuthenticationConfig *)credentials
            refreshToken:(NSString *)refreshToken
              completion:(ARTAuthCompletion)completion {
    if (credentials.accessToken.length == 0 &&
        credentials.clientID.length == 0) {
        completion(nil,
                   MakeError(ErrorCodeAuthenticationFailed,
                             @"ClientID is required when AccessToken is not "
                             @"present."));
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *headers =
        [NSMutableDictionary dictionaryWithDictionary:@{
            @"X-Org" : credentials.orgTitle ?: @"",
            @"Environment" : credentials.environment ?: @"",
            @"ProjectKey" : credentials.projectKey ?: @"",
        }];
    // Client-Id and the passcode / auth token go out on refresh too.
    if (credentials.clientID.length > 0) {
        headers[@"Client-Id"] = credentials.clientID;
    }
    if (credentials.accessToken.length > 0) {
        headers[@"T-pass"] = credentials.accessToken;
    }
    if (credentials.config.authToken) {
        headers[@"X-pass"] = credentials.config.authToken;
    }

    NSURL *url = [NSURL
        URLWithString:[NSString stringWithFormat:@"%@/auth/token/refresh",
                                                 Constant.BASE_URL]];
    if (!url) {
        completion(nil, MakeError(ErrorCodeAuthenticationFailed,
                                  @"Incorrect auth refresh URL"));
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    for (NSString *key in headers) {
        [req setValue:headers[key] forHTTPHeaderField:key];
    }
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [[ARTJSON stringify:@{@"refresh_token" : refreshToken ?: @""}
                                 error:nil]
        dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionDataTask *task = [ARTHTTPClient.session
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *netErr) {
            if (netErr) {
                completion(nil, netErr);
                return;
            }

            // The gateway has no socket backend: keep the current tokens.
            if ([response isKindOfClass:[NSHTTPURLResponse class]] &&
                ((NSHTTPURLResponse *)response).statusCode == 500) {
                id body = [ARTJSON parseData:data];
                id errMsg = [body isKindOfClass:[NSDictionary class]]
                                ? ((NSDictionary *)body)[@"error"]
                                : nil;
                if ([errMsg isKindOfClass:[NSString class]] &&
                    [errMsg isEqualToString:@"Failed to get WebSocket backend"]) {
                    completion(nil, MakeError(ErrorCodeServerError, errMsg));
                    return;
                }
            }

            [self storeTokenResponse:response
                                data:data
                        shapeMessage:@"Unexpected refresh response shape"
                              completion:completion];
          }];
    [task resume];
}

/// Validates a token response and stores the new token pair.
- (void)storeTokenResponse:(NSURLResponse *)response
                      data:(NSData *)data
              shapeMessage:(NSString *)shapeMessage
                completion:(ARTAuthCompletion)completion {
    NSError *validateErr = nil;
    if (![self validateHTTPResponse:response data:data error:&validateErr]) {
        completion(nil, validateErr);
        return;
    }

    id json = [ARTJSON parseData:data];
    NSDictionary *tokenData = [json isKindOfClass:[NSDictionary class]]
                                  ? ((NSDictionary *)json)[@"data"]
                                  : nil;
    if (![tokenData isKindOfClass:[NSDictionary class]]) {
        completion(nil, MakeError(ErrorCodeAuthenticationFailed, shapeMessage));
        return;
    }

    id access = tokenData[@"access_token"];
    id refresh = tokenData[@"refresh_token"];
    AuthData *fresh = [[AuthData alloc]
        initWithAccessToken:[access isKindOfClass:[NSString class]] ? access : @""
               refreshToken:[refresh isKindOfClass:[NSString class]] ? refresh
                                                                      : @""];
    @synchronized(self.stateLock) {
        self.authData = fresh;
    }
    completion(fresh, nil);
}

#pragma mark - Getters

- (AuthData *)getAuthData {
    @synchronized(self.stateLock) {
        return [self.authData copy];
    }
}

- (AuthenticationConfig *)getCredentials {
    @synchronized(self.stateLock) {
        return [self.credentials copy];
    }
}

#pragma mark - JWT helpers

- (nullable NSDictionary<NSString *, id> *)decodeJWTPayload:(NSString *)token {
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count < 2) {
        return nil;
    }

    // Base64-URL → Base64, padded to a multiple of 4.
    NSMutableString *b64 = [parts[1] mutableCopy];
    [b64 replaceOccurrencesOfString:@"-"
                         withString:@"+"
                            options:0
                              range:NSMakeRange(0, b64.length)];
    [b64 replaceOccurrencesOfString:@"_"
                         withString:@"/"
                            options:0
                              range:NSMakeRange(0, b64.length)];
    NSUInteger pad = (4 - b64.length % 4) % 4;
    for (NSUInteger i = 0; i < pad; i++) {
        [b64 appendString:@"="];
    }

    NSData *jsonData = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    id payload = jsonData ? [ARTJSON parseData:jsonData] : nil;
    return [payload isKindOfClass:[NSDictionary class]] ? payload : nil;
}

/// YES when the token can't be decoded or expires within
/// `ARTRenewalLeewaySeconds`.
- (BOOL)isTokenExpired:(NSString *)token {
    if (token.length == 0) {
        return YES;
    }
    NSDictionary *payload = [self decodeJWTPayload:token];
    NSNumber *expNum = payload[@"exp"];
    if (![expNum isKindOfClass:[NSNumber class]]) {
        return YES;
    }
    double now = [[NSDate date] timeIntervalSince1970];
    return expNum.doubleValue <= now + ARTRenewalLeewaySeconds;
}

- (RefreshInfo *)getRefreshTokenExpiryInfo:(NSString *)token {
    RefreshInfo *info = [[RefreshInfo alloc] init];
    info.expired = YES;
    info.exp = nil;
    info.remaining = 0;

    if (token.length == 0) {
        return info;
    }
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count < 2) {
        return info;
    }
    double exp = [parts[1] doubleValue];
    if (exp == 0) {
        return info;
    }

    double now = [[NSDate date] timeIntervalSince1970];
    info.expired = (now >= exp);
    info.exp = @(exp);
    info.remaining = exp - now;
    return info;
}

#pragma mark - HTTP helper

- (BOOL)validateHTTPResponse:(NSURLResponse *)response
                        data:(NSData *)data
                       error:(NSError **)error {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        return YES;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    if (http.statusCode >= 200 && http.statusCode < 300) {
        return YES;
    }

    id body = [ARTJSON parseData:data];
    id msg = [body isKindOfClass:[NSDictionary class]]
                 ? ((NSDictionary *)body)[@"message"]
                 : nil;
    if (![msg isKindOfClass:[NSString class]] || [msg length] == 0) {
        msg = [NSHTTPURLResponse localizedStringForStatusCode:http.statusCode];
    }
    if (error) {
        *error = MakeError(ErrorCodeAuthenticationFailed, msg);
    }
    return NO;
}

@end
