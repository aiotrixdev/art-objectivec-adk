//
//  Auth.m
//  ADK
//

#import "Auth.h"
#import "AuthTypes.h"
#import "Constant.h"
#import "Utils.h"

@interface RefreshInfo : NSObject
@property(nonatomic, assign) BOOL expired;
@property(nonatomic, strong, nullable) NSNumber *exp;
@property(nonatomic, assign) double remaining;
@end

@implementation RefreshInfo
@end

@interface Auth ()
@property(nonatomic, strong) AuthenticationConfig *credentials;
@property(nonatomic, strong) AuthData *authData;
@end

// Singleton. Uses dispatch_once to initialise the lock so there is no
// window where `_singletonLock` could be nil, even if +getInstance is
// called before +initialize has finished (possible under heavy
// early-launch load on multiple threads).
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
        _credentials = credentials;
        _authData = [[AuthData alloc] init];
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

- (void)authenticate:(BOOL)forceAuth
          completion:
              (void (^)(AuthData *_Nullable, NSError *_Nullable))completion {
    if (!forceAuth && self.authData.accessToken.length > 0 &&
        ![self isTokenExpired:self.authData.accessToken]) {
        completion(self.authData, nil);
        return;
    }

    if (self.credentials.getCredentials) {
        CredentialStore *cred = self.credentials.getCredentials();
        self.credentials.accessToken = cred.accessToken;
        self.credentials.clientID = cred.clientID;
        self.credentials.clientSecret = cred.clientSecret;
        self.credentials.orgTitle = cred.orgTitle;
        self.credentials.environment = cred.environment;
        self.credentials.projectKey = cred.projectKey;
    }

    if (self.credentials.orgTitle.length == 0 ||
        self.credentials.environment.length == 0 ||
        self.credentials.projectKey.length == 0) {
        completion(
            nil,
            MakeError(ErrorCodeAuthenticationFailed,
                      @"OrgTitle, Environment and ProjectKey are required"));
        return;
    }

    RefreshInfo *refreshInfo =
        [self getRefreshTokenExpiryInfo:self.authData.refreshToken];
    if (!refreshInfo.expired) {
        [self refreshAuthToken:completion];
        return;
    }

    [self generateAuthToken:completion];
}

- (void)generateAuthToken:(void (^)(AuthData *_Nullable,
                                    NSError *_Nullable))completion {
    if (self.credentials.accessToken == nil ||
        self.credentials.accessToken.length == 0) {
        if (self.credentials.clientID.length == 0 ||
            self.credentials.clientSecret.length == 0) {
            completion(nil, MakeError(ErrorCodeAuthenticationFailed,
                                      @"ClientID and ClientSecret are required "
                                      @"when AccessToken is not present."));
            return;
        }
    }

    NSMutableDictionary<NSString *, NSString *> *headerPayload =
        [NSMutableDictionary dictionaryWithDictionary:@{
            @"Client-Id" : self.credentials.clientID ?: @"",
            @"Client-Secret" : self.credentials.clientSecret ?: @"",
            @"X-Org" : self.credentials.orgTitle ?: @"",
            @"Environment" : self.credentials.environment ?: @"",
            @"ProjectKey" : self.credentials.projectKey ?: @"",
        }];
    if (self.credentials.accessToken &&
        self.credentials.accessToken.length > 0) {
        headerPayload[@"T-pass"] = self.credentials.accessToken;
    }
    if (self.credentials.config.authToken) {
        headerPayload[@"X-pass"] = self.credentials.config.authToken;
    }

    NSString *urlString =
        [NSString stringWithFormat:@"%@/auth/token", Constant.BASE_URL];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        completion(nil, MakeError(ErrorCodeAuthenticationFailed,
                                  @"Incorrect auth token URL"));
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    for (NSString *key in headerPayload) {
        [req setValue:headerPayload[key] forHTTPHeaderField:key];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *netErr) {
            if (netErr) {
                completion(nil, netErr);
                return;
            }

            NSError *validateErr = nil;
            if (![self validateHTTPResponse:response
                                       data:data
                                      error:&validateErr]) {
                completion(nil, validateErr);
                return;
            }

            NSError *jsonErr = nil;
            NSDictionary *json =
                [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:&jsonErr];
            if (jsonErr) {
                completion(nil, jsonErr);
                return;
            }

            NSDictionary *tokenData = json[@"data"];
            if (![tokenData isKindOfClass:[NSDictionary class]]) {
                completion(nil, MakeError(ErrorCodeAuthenticationFailed,
                                          @"Unexpected token response shape"));
                return;
            }

            self.authData = [[AuthData alloc]
                initWithAccessToken:tokenData[@"access_token"] ?: @""
                       refreshToken:tokenData[@"refresh_token"] ?: @""];
            completion(self.authData, nil);
          }];
    [task resume];
}

- (void)refreshAuthToken:(void (^)(AuthData *_Nullable,
                                   NSError *_Nullable))completion {
    if (self.credentials.accessToken == nil ||
        self.credentials.accessToken.length == 0) {
        if (self.credentials.clientID.length == 0) {
            completion(
                nil,
                MakeError(
                    ErrorCodeAuthenticationFailed,
                    @"ClientID is required when AccessToken is not present."));
            return;
        }
    }

    NSDictionary<NSString *, NSString *> *headerPayload = @{
        @"Client-Id" : self.credentials.clientID ?: @"",
        @"X-Org" : self.credentials.orgTitle ?: @"",
        @"Environment" : self.credentials.environment ?: @"",
        @"ProjectKey" : self.credentials.projectKey ?: @"",
    };

    NSString *urlString =
        [NSString stringWithFormat:@"%@/auth/token/refresh", Constant.BASE_URL];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        completion(nil, MakeError(ErrorCodeAuthenticationFailed,
                                  @"Incorrect auth refresh URL"));
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    for (NSString *key in headerPayload) {
        [req setValue:headerPayload[key] forHTTPHeaderField:key];
    }
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSError *bodyErr = nil;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"refresh_token" : self.authData.refreshToken ?: @""
    }
                                                   options:0
                                                     error:&bodyErr];
    if (bodyErr) {
        completion(nil, bodyErr);
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *netErr) {
            if (netErr) {
                completion(nil, netErr);
                return;
            }

            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                if (httpResp.statusCode == 500) {
                    NSDictionary *body =
                        [NSJSONSerialization JSONObjectWithData:data
                                                        options:0
                                                          error:nil];
                    if ([body isKindOfClass:[NSDictionary class]]) {
                        NSString *errMsg = body[@"error"];
                        if ([errMsg isKindOfClass:[NSString class]] &&
                            [errMsg isEqualToString:
                                        @"Failed to get WebSocket backend"]) {
                            completion(nil,
                                       MakeError(ErrorCodeServerError, errMsg));
                            return;
                        }
                    }
                }
            }

            NSError *validateErr = nil;
            if (![self validateHTTPResponse:response
                                       data:data
                                      error:&validateErr]) {
                completion(nil, validateErr);
                return;
            }

            NSError *jsonErr = nil;
            NSDictionary *json =
                [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:&jsonErr];
            if (jsonErr) {
                completion(nil, jsonErr);
                return;
            }

            NSDictionary *tokenData = json[@"data"];
            if (![tokenData isKindOfClass:[NSDictionary class]]) {
                completion(nil,
                           MakeError(ErrorCodeAuthenticationFailed,
                                     @"Unexpected refresh response shape"));
                return;
            }

            self.authData = [[AuthData alloc]
                initWithAccessToken:tokenData[@"access_token"] ?: @""
                       refreshToken:tokenData[@"refresh_token"] ?: @""];
            completion(self.authData, nil);
          }];
    [task resume];
}

- (AuthData *)getAuthData {
    return self.authData;
}

- (AuthenticationConfig *)getCredentials {
    return self.credentials;
}

- (nullable NSDictionary<NSString *, id> *)decodeJWTPayload:(NSString *)token
                                                      error:(NSError **)error {
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count < 2) {
        if (error) {
            *error = MakeError(ErrorCodeAuthenticationFailed, @"Incorrect JWT");
        }
        return nil;
    }

    // Base64-URL decode the payload segment
    NSMutableString *b64 = [parts[1] mutableCopy];
    [b64 replaceOccurrencesOfString:@"-"
                         withString:@"+"
                            options:0
                              range:NSMakeRange(0, b64.length)];
    [b64 replaceOccurrencesOfString:@"_"
                         withString:@"/"
                            options:0
                              range:NSMakeRange(0, b64.length)];

    // Pad to multiple of 4
    NSUInteger pad = (4 - b64.length % 4) % 4;
    for (NSUInteger i = 0; i < pad; i++) {
        [b64 appendString:@"="];
    }

    NSData *jsonData = [[NSData alloc] initWithBase64EncodedString:b64
                                                           options:0];
    if (!jsonData) {
        if (error) {
            *error = MakeError(ErrorCodeAuthenticationFailed,
                               @"Base64 decode failed");
        }
        return nil;
    }

    NSError *jsonErr = nil;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:jsonData
                                                            options:0
                                                              error:&jsonErr];
    if (jsonErr || ![payload isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = MakeError(ErrorCodeAuthenticationFailed,
                               @"JWT payload not a JSON object");
        }
        return nil;
    }

    return payload;
}

- (BOOL)isTokenExpired:(NSString *)token {
    if (token.length == 0)
        return YES;

    NSError *err = nil;
    NSDictionary *payload = [self decodeJWTPayload:token error:&err];
    if (!payload)
        return YES;

    NSNumber *expNum = payload[@"exp"];
    if (![expNum isKindOfClass:[NSNumber class]])
        return YES;

    double exp = expNum.doubleValue;
    double now = [[NSDate date] timeIntervalSince1970];
    return exp < (now - 100);
}

- (RefreshInfo *)getRefreshTokenExpiryInfo:(NSString *)token {
    RefreshInfo *info = [[RefreshInfo alloc] init];
    info.expired = YES;
    info.exp = nil;
    info.remaining = 0;

    if (token.length == 0)
        return info;

    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count < 2)
        return info;

    double exp = [parts[1] doubleValue];
    if (exp == 0)
        return info;

    double now = [[NSDate date] timeIntervalSince1970];
    info.expired = (now >= exp);
    info.exp = @(exp);
    info.remaining = exp - now;
    return info;
}

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

    NSString *msg = nil;
    NSDictionary *body = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0
                                                           error:nil];
    if ([body isKindOfClass:[NSDictionary class]]) {
        msg = body[@"message"];
    }
    if (![msg isKindOfClass:[NSString class]] || msg.length == 0) {
        msg = [NSHTTPURLResponse localizedStringForStatusCode:http.statusCode];
    }

    if (error) {
        *error = MakeError(ErrorCodeAuthenticationFailed, msg);
    }
    return NO;
}

@end
