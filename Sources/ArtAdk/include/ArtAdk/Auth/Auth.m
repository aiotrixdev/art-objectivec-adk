//
//  Auth.m
//  ADK
//

#import "Auth.h"
#import "ARTSupport.h"
#import "AuthTypes.h"
#import "Constant.h"
#import "HTTPCall+Internal.h"
#import "HTTPCall.h"
#import "Utils.h"

/// Seconds before `exp` at which an access token is renewed.
static const double ARTRenewalLeewaySeconds = 30;

typedef void (^ARTAuthCompletion)(AuthData *_Nullable, NSError *_Nullable);

NSErrorDomain const ARTAuthHttpErrorDomain = @"com.art.adk.auth";

@implementation ARTAuthHttpError

+ (instancetype)errorWithMessage:(NSString *)message
                          status:(NSInteger)status
                            body:(id)body {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message ?: @"";
    userInfo[ARTHTTPStatusCodeKey] = @(status);
    if (body) {
        userInfo[ARTHTTPResponseBodyKey] = body;
    }
    return [self errorWithDomain:ARTAuthHttpErrorDomain code:status userInfo:userInfo];
}

- (NSString *)message {
    return self.userInfo[NSLocalizedDescriptionKey] ?: @"";
}

- (NSInteger)status {
    return [self.userInfo[ARTHTTPStatusCodeKey] integerValue];
}

- (id)body {
    return self.userInfo[ARTHTTPResponseBodyKey];
}

- (BOOL)isTerminal {
    return self.status == 401 || self.status == 403;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"authenticationFailed (%ld): %@",
                                      (long)self.status, self.message];
}

@end

BOOL ARTIsTerminalAuthError(NSError *error) {
    return [error isKindOfClass:[ARTAuthHttpError class]] &&
           ((ARTAuthHttpError *)error).isTerminal;
}

static BOOL ARTSameString(NSString *_Nullable a, NSString *_Nullable b) {
    return a == b || [a isEqualToString:b];
}

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

    if (_instance != nil && credentials != nil) {
        if ([self sameIdentity:[_instance getCredentials] as:credentials]) {
            [_instance replaceCredentials:credentials];
        } else {
            _instance = [[Auth alloc] initWithCredentials:credentials];
        }
    }

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

- (void)replaceCredentials:(AuthenticationConfig *)credentials {
    AuthenticationConfig *copy = [credentials copy];
    @synchronized(self.stateLock) {
        self.credentials = copy;
    }
}

+ (BOOL)sameIdentity:(AuthenticationConfig *)a as:(AuthenticationConfig *)b {
    return ARTSameString(a.orgTitle, b.orgTitle) &&
           ARTSameString(a.environment, b.environment) &&
           ARTSameString(a.projectKey, b.projectKey) &&
           ARTSameString(a.clientID, b.clientID);
}

+ (BOOL)usesClientCredentials:(AuthenticationConfig *)credentials {
    return credentials.clientID.length > 0 && credentials.clientSecret.length > 0;
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

    [self readCredentialsProvider];

    AuthenticationConfig *creds;
    NSString *refreshToken;
    @synchronized(self.stateLock) {
        creds = [self.credentials copy];
        refreshToken = self.authData.refreshToken;
    }

    if (creds.orgTitle.length == 0 || creds.environment.length == 0 ||
        creds.projectKey.length == 0) {
        completion(
            nil,
            MakeError(ErrorCodeAuthenticationFailed,
                      @"OrgTitle, Environment and ProjectKey are required"));
        return;
    }

    // Client credentials renew by authenticating again, never through a
    // refresh token, even when an older server still returns one.
    if ([Auth usesClientCredentials:creds]) {
        [self generateAuthToken:creds completion:completion];
        return;
    }

    // Use the refresh token while it is still valid.
    if (![self getRefreshTokenExpiryInfo:refreshToken].expired) {
        [self refreshAuthToken:creds
                  refreshToken:refreshToken
                    completion:completion];
        return;
    }

    [self generateAuthToken:creds completion:completion];
}

/// Applies the `getCredentials` hook. Tokens issued to another identity are
/// dropped, so they are never reused or refreshed.
- (void)readCredentialsProvider {
    CredentialStore *_Nonnull (^getCredentials)(void);
    @synchronized(self.stateLock) {
        getCredentials = self.credentials.getCredentials;
    }
    if (!getCredentials) {
        return;
    }
    CredentialStore *cred = getCredentials();
    @synchronized(self.stateLock) {
        AuthenticationConfig *next = [self.credentials copy];
        next.accessToken = cred.accessToken;
        next.clientID = cred.clientID;
        next.clientSecret = cred.clientSecret;
        next.orgTitle = cred.orgTitle;
        next.environment = cred.environment;
        next.projectKey = cred.projectKey;
        if (![Auth sameIdentity:self.credentials as:next]) {
            self.authData = [[AuthData alloc] init];
        }
        self.credentials = next;
    }
}

#pragma mark - Generate token

- (void)generateAuthToken:(AuthenticationConfig *)credentials
               completion:(ARTAuthCompletion)completion {
    NSString *accessToken = credentials.accessToken ?: @"";
    BOOL clientCredentials = [Auth usesClientCredentials:credentials];
    if (accessToken.length == 0 && !clientCredentials) {
        completion(nil, MakeError(ErrorCodeAuthenticationFailed,
                                  @"ClientID and ClientSecret required when "
                                  @"AccessToken is absent"));
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *headers =
        [self baseHeaders:credentials];
    if (clientCredentials) {
        headers[@"Client-Id"] = credentials.clientID;
        headers[@"Client-Secret"] = credentials.clientSecret;
    } else {
        headers[@"T-pass"] = accessToken;
    }
    [self addPasscode:headers credentials:credentials];

    [self post:@"/auth/token"
            headers:headers
               body:nil
        credentials:credentials
         completion:^(NSDictionary *data, NSError *error) {
           if (error) {
               completion(nil, error);
               return;
           }
           [self store:data
                       credentials:credentials
               missingTokenMessage:@"Authentication did not return an access "
                                   @"token. Please sign in again."
                        completion:completion];
         }];
}

#pragma mark - Refresh token

- (void)refreshAuthToken:(AuthenticationConfig *)credentials
            refreshToken:(NSString *)refreshToken
              completion:(ARTAuthCompletion)completion {
    NSString *accessToken = credentials.accessToken ?: @"";
    if (accessToken.length == 0 && credentials.clientID.length == 0) {
        completion(nil, MakeError(ErrorCodeAuthenticationFailed,
                                  @"ClientID required when AccessToken is absent"));
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *headers =
        [self baseHeaders:credentials];
    if (credentials.clientID.length > 0) {
        headers[@"Client-Id"] = credentials.clientID;
    }
    if (accessToken.length > 0) {
        headers[@"T-pass"] = accessToken;
    }
    [self addPasscode:headers credentials:credentials];

    [self post:@"/auth/token/refresh"
            headers:headers
               body:@{@"refresh_token" : refreshToken ?: @""}
        credentials:credentials
         completion:^(NSDictionary *data, NSError *error) {
           if (error) {
               completion(nil, error);
               return;
           }
           [self store:data
                       credentials:credentials
               missingTokenMessage:@"Authentication refresh did not return an "
                                   @"access token. Please sign in again."
                        completion:completion];
         }];
}

- (NSMutableDictionary<NSString *, NSString *> *)baseHeaders:
    (AuthenticationConfig *)credentials {
    return [@{
        @"Content-Type" : @"application/json",
        @"X-Org" : credentials.orgTitle ?: @"",
        @"Environment" : credentials.environment ?: @"",
        @"ProjectKey" : credentials.projectKey ?: @"",
    } mutableCopy];
}

- (void)addPasscode:(NSMutableDictionary<NSString *, NSString *> *)headers
        credentials:(AuthenticationConfig *)credentials {
    if (credentials.config.authToken.length > 0) {
        headers[@"X-pass"] = credentials.config.authToken;
    }
}

/// Stores the tokens in `data`; fails with `missingTokenMessage` when it
/// holds no access token.
- (void)store:(NSDictionary *)data
            credentials:(AuthenticationConfig *)credentials
    missingTokenMessage:(NSString *)missingTokenMessage
             completion:(ARTAuthCompletion)completion {
    id access = data[@"access_token"];
    if (![access isKindOfClass:[NSString class]] || [(NSString *)access length] == 0) {
        completion(nil, MakeError(ErrorCodeAuthenticationFailed, missingTokenMessage));
        return;
    }
    id refresh = data[@"refresh_token"];
    AuthData *fresh = [[AuthData alloc]
        initWithAccessToken:access
               refreshToken:(![Auth usesClientCredentials:credentials] &&
                             [refresh isKindOfClass:[NSString class]])
                                ? refresh
                                : @""];
    @synchronized(self.stateLock) {
        self.authData = fresh;
    }
    completion(fresh, nil);
}

#pragma mark - HTTP

/// Sends an auth request and completes with the `data` object of its
/// response. Gives up after `AdkConfig.connectionTimeoutMs` (30 seconds by
/// default).
- (void)post:(NSString *)path
        headers:(NSDictionary<NSString *, NSString *> *)headers
           body:(nullable NSDictionary *)body
    credentials:(AuthenticationConfig *)credentials
     completion:(void (^)(NSDictionary *_Nullable data,
                          NSError *_Nullable error))completion {
    NSURL *url = [NSURL
        URLWithString:[NSString stringWithFormat:@"%@%@", Constant.BASE_URL, path]];
    if (!url) {
        completion(nil, MakeError(ErrorCodeAuthenticationFailed, @"Malformed auth URL"));
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    for (NSString *key in headers) {
        [req setValue:headers[key] forHTTPHeaderField:key];
    }
    if (body) {
        req.HTTPBody = [[ARTJSON stringify:body error:nil]
            dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSInteger timeoutMs =
        credentials.config ? credentials.config.connectionTimeoutMs : 30000;
    [ARTHTTPClient
        sendRequest:req
          timeoutMs:timeoutMs
       timeoutError:^NSError * {
         return MakeError(ErrorCodeAuthenticationFailed,
                          @"Authentication timed out. Please check your "
                          @"connection and sign in again.");
       }
         completion:^(NSData *data, NSURLResponse *response, NSError *error) {
           if (error) {
               if ([error.domain isEqualToString:ErrorDomain]) {
                   completion(nil, error);
                   return;
               }
               NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
               userInfo[NSLocalizedDescriptionKey] = error.localizedDescription;
               userInfo[NSUnderlyingErrorKey] = error;
               completion(nil, [NSError errorWithDomain:ErrorDomain
                                                   code:ErrorCodeAuthenticationFailed
                                               userInfo:userInfo]);
               return;
           }

           id json = [ARTJSON parseData:data];
           NSDictionary *object =
               [json isKindOfClass:[NSDictionary class]] ? json : nil;
           NSHTTPURLResponse *http =
               [response isKindOfClass:[NSHTTPURLResponse class]]
                   ? (NSHTTPURLResponse *)response
                   : nil;
           if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
               // Keep both tokens: the gateway only lacked a WebSocket backend.
               id message = object[@"error"];
               if ([path hasSuffix:@"/refresh"] && http.statusCode == 500 &&
                   [message isKindOfClass:[NSString class]] &&
                   [message isEqualToString:@"Failed to get WebSocket backend"]) {
                   completion(nil, MakeError(ErrorCodeServerError, message));
                   return;
               }
               completion(nil,
                          [ARTAuthHttpError
                              errorWithMessage:[Auth errorMessage:object]
                                                   ?: [Auth statusText:http.statusCode]
                                        status:http.statusCode
                                          body:json]);
               return;
           }
           if (!object) {
               completion(nil,
                          MakeError(ErrorCodeAuthenticationFailed,
                                    [NSString stringWithFormat:
                                                  @"Unexpected response from %@",
                                                  path]));
               return;
           }
           id tokenData = object[@"data"];
           completion([tokenData isKindOfClass:[NSDictionary class]] ? tokenData : @{},
                      nil);
         }];
}

+ (nullable NSString *)errorMessage:(nullable NSDictionary *)object {
    for (NSString *key in @[ @"message", @"error" ]) {
        id value = object[key];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return value;
        }
    }
    return nil;
}

+ (NSString *)statusText:(NSInteger)status {
    return [NSString
        stringWithFormat:@"HTTP %ld %@", (long)status,
                         [NSHTTPURLResponse localizedStringForStatusCode:status]];
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

@end
