//
//  Adk.m
//  ADK
//

#import "Adk.h"
#import "Auth.h"
#import "AuthTypes.h"
#import "BaseSubscription.h"
#import "ChannelTypes.h"
#import "Constant.h"
#import "CryptoBox.h"
#import "CryptoTypes.h"
#import "Interception.h"
#import "LogTracer.h"
#import "Socket.h"
#import "SocketTypes.h"
#import "Utils.h"

@interface Adk ()

@property(nonatomic, strong, readwrite) Socket *socket;
@property(nonatomic, assign, readwrite) AdkState state;

// Reconnection state
@property(nonatomic, assign) NSInteger reconnectAttempts;
@property(nonatomic, assign) NSInteger maxReconnectAttempts;
@property(nonatomic, assign) double reconnectDelay; // ms
@property(nonatomic, assign) double maxDelay;       // ms

// SDK config
@property(nonatomic, strong, nullable) AdkConfig *adkConfig;

// Flags
@property(nonatomic, assign) BOOL isPaused;
@property(nonatomic, assign) BOOL isConnectable;

// Reconnect dispatch work item
@property(nonatomic, strong, nullable) dispatch_block_t reconnectWorkItem;

// Event listener identifiers
@property(nonatomic, strong) NSUUID *connectionListenerId;
@property(nonatomic, strong) NSUUID *closeListenerId;

@end

@implementation Adk

- (instancetype)initWithConfig:(nullable AdkConfig *)config {
    self = [super init];
    if (self) {
        _adkConfig = config;
        _state = AdkStateStopped;
        _reconnectAttempts = 0;
        _maxReconnectAttempts = 5;
        _reconnectDelay = 3000; // 3 seconds
        _maxDelay = 5000;       // 5 seconds
        _isPaused = NO;
        _isConnectable = NO;

        // Normalise the URI: strip any scheme the caller may have
        // included ("https://", "http://", "wss://", "ws://") so the
        // format strings below produce a single, well-formed URL.
        NSString *rawUrl = config.uri ?: @"";
        rawUrl = [rawUrl stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        NSArray<NSString *> *schemesToStrip =
            @[ @"https://", @"http://", @"wss://", @"ws://" ];
        for (NSString *scheme in schemesToStrip) {
            if ([rawUrl.lowercaseString hasPrefix:scheme]) {
                rawUrl = [rawUrl substringFromIndex:scheme.length];
                break;
            }
        }
        // Strip a trailing slash if present.
        while (rawUrl.length > 0 && [rawUrl hasSuffix:@"/"]) {
            rawUrl = [rawUrl substringToIndex:rawUrl.length - 1];
        }
        if (rawUrl.length == 0) {
            [LogTracer
                log:@" Adk: WARNING - empty URI, network calls will fail"];
        }

        Constant.BASE_URL = [NSString stringWithFormat:@"https://%@", rawUrl];
        Constant.WS_URL =
            [NSString stringWithFormat:@"wss://%@/v1/connect", rawUrl];
        Constant.SSE_URL =
            [NSString stringWithFormat:@"https://%@/v1/connect/sse", rawUrl];
        Constant.LPOLL = [NSString
            stringWithFormat:@"https://%@/v1/connect/longpoll", rawUrl];

        _socket = [Socket
            getInstance:^(
                NSString *data, NSString *key,
                void (^completion)(NSString *_Nullable, NSError *_Nullable)) {
              completion(data, nil);
            }
            decrypt:^(
                NSString *data, NSString *key,
                void (^completion)(NSString *_Nullable, NSError *_Nullable)) {
              completion(data, nil);
            }];

        __weak typeof(self) weakSelf = self;

        _socket.encryptBlock =
            ^(NSString *data, NSString *pubKey,
              void (^completion)(NSString *_Nullable, NSError *_Nullable)) {
              typeof(self) strongSelf = weakSelf;
              if (!strongSelf) {
                  completion(nil, MakeError(ErrorCodeEncryptionError,
                                            @"Adk deallocated"));
                  return;
              }
              [strongSelf encrypt:data
                  recipientPublicKey:pubKey
                          completion:completion];
            };

        _socket.decryptBlock =
            ^(NSString *data, NSString *pubKey,
              void (^completion)(NSString *_Nullable, NSError *_Nullable)) {
              typeof(self) strongSelf = weakSelf;
              if (!strongSelf) {
                  completion(nil, MakeError(ErrorCodeDecryptionError,
                                            @"Adk deallocated"));
                  return;
              }
              [strongSelf decrypt:data
                  senderPublicKey:pubKey
                       completion:completion];
            };

        _connectionListenerId =
            [_socket on:@"connection"
                handler:^(id data) {
                  typeof(self) strongSelf = weakSelf;
                  if (!strongSelf)
                      return;
                  if ([data isKindOfClass:[ConnectionDetail class]]) {
                      [strongSelf handleOnConnection:(ConnectionDetail *)data];
                  }
                }];

        _closeListenerId = [_socket on:@"close"
                               handler:^(id data) {
                                 typeof(self) strongSelf = weakSelf;
                                 if (!strongSelf)
                                     return;
                                 [strongSelf handleOnClose];
                               }];
    }
    return self;
}

- (void)dealloc {
    // Unregister our socket event listeners so their blocks don't
    // accumulate in the Socket's emitter (which is a long-lived
    // singleton). Without this, every Adk instance leaks two dead
    // handler slots on the emitter's array.
    if (_socket) {
        if (_connectionListenerId) {
            [_socket off:@"connection" identifier:_connectionListenerId];
        }
        if (_closeListenerId) {
            [_socket off:@"close" identifier:_closeListenerId];
        }
    }
    // Cancel any pending reconnect work item.
    if (_reconnectWorkItem) {
        dispatch_block_cancel(_reconnectWorkItem);
        _reconnectWorkItem = nil;
    }
}

- (void)connect:(nullable ConnectConfig *)config
     completion:(nullable void (^)(void))completion {
    self.isConnectable = YES;
    self.state = AdkStateConnecting;

    __weak typeof(self) weakSelf = self;
    [self initiateSocketConnection:^{
      typeof(self) strongSelf = weakSelf;
      if (strongSelf) {
          strongSelf.state = AdkStateConnected;
      }
      if (completion)
          completion();
    }];
}

- (void)pause {
    if (self.isPaused)
        return;
    self.isPaused = YES;
    self.reconnectAttempts = self.maxReconnectAttempts;

    __weak typeof(self) weakSelf = self;
    [self.socket closeWebSocket:NO
                     completion:^{
                       typeof(self) strongSelf = weakSelf;
                       if (strongSelf) {
                           strongSelf.state = AdkStatePaused;
                       }
                     }];
}

- (void)resume:(nullable void (^)(void))completion {
    if (!self.isPaused) {
        if (completion)
            completion();
        return;
    }
    self.isPaused = NO;
    self.reconnectAttempts = 0;
    self.reconnectDelay = 3000;
    self.state = AdkStateConnecting;

    __weak typeof(self) weakSelf = self;
    [self.socket connectWebSocket:^(NSError *_Nullable error) {
      typeof(self) strongSelf = weakSelf;
      if (strongSelf) {
          strongSelf.state = AdkStateConnected;
      }
      if (completion)
          completion();
    }];
}

- (void)disconnect:(nullable void (^)(void))completion {
    self.isConnectable = NO;
    self.reconnectAttempts = self.maxReconnectAttempts;

    // Cancel pending reconnect
    if (self.reconnectWorkItem) {
        dispatch_block_cancel(self.reconnectWorkItem);
        self.reconnectWorkItem = nil;
    }

    __weak typeof(self) weakSelf = self;
    [self.socket closeWebSocket:YES
                     completion:^{
                       typeof(self) strongSelf = weakSelf;
                       if (strongSelf) {
                           strongSelf.state = AdkStateStopped;
                           strongSelf.socket.isConnectionActive = NO;
                       }
                       if (completion)
                           completion();
                     }];
}

- (NSString *)getState {
    if (self.isPaused)
        return @"paused";
    if (self.reconnectAttempts >= self.maxReconnectAttempts)
        return @"stopped";
    if (self.reconnectAttempts > 0)
        return @"retrying";
    if (self.socket.isConnectionActive)
        return @"connected";
    return @"stopped";
}

- (void)initiateSocketConnection:(void (^)(void))completion {

    __weak typeof(self) weakSelf = self;

    // Helper to finalize once we have the auth config.
    void (^proceed)(AuthenticationConfig *) = ^(AuthenticationConfig *authConfig) {
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf) {
          if (completion) completion();
          return;
      }
      authConfig.config = strongSelf.adkConfig;
      authConfig.getCredentials = strongSelf.adkConfig.getCredentials;
      [strongSelf.socket initiateSocket:authConfig
                             completion:^(NSError *_Nullable error) {
                               if (completion) completion();
                             }];
    };

    if (self.adkConfig.getCredentials) {
        CredentialStore *store = self.adkConfig.getCredentials();
        AuthenticationConfig *authConfig =
            [[AuthenticationConfig alloc] initWithEnvironment:store.environment
                                                   projectKey:store.projectKey
                                                     orgTitle:store.orgTitle
                                                     clientID:store.clientID
                                                 clientSecret:store.clientSecret
                                                       config:nil
                                                  accessToken:store.accessToken
                                               getCredentials:nil];
        proceed(authConfig);
        return;
    }

    // Async load from adk-services.json — NEVER block the caller thread.
    [self loadConfigAsync:^(AuthenticationConfig *loaded) {
      proceed(loaded);
    }];
}

- (void)handleOnConnection:(ConnectionDetail *)connection {
    self.reconnectAttempts = 0;
    self.reconnectDelay = 3000;
    [self onConnectedHook:connection];
}

- (void)handleOnClose {
    if (!self.isConnectable)
        return;
    self.socket.isReConnecting = YES;
    [self handleReconnection];
}

- (void)handleReconnection {
    if (self.reconnectWorkItem) {
        dispatch_block_cancel(self.reconnectWorkItem);
        self.reconnectWorkItem = nil;
    }

    __weak typeof(self) weakSelf = self;

    if (self.reconnectAttempts < self.maxReconnectAttempts) {
        self.reconnectAttempts++;
        [LogTracer
            log:[NSString stringWithFormat:
                              @"Attempting to reconnect in %.0fs (attempt %ld)",
                              self.reconnectDelay / 1000.0,
                              (long)self.reconnectAttempts]];

        double delayMs = self.reconnectDelay;
        dispatch_block_t work = dispatch_block_create(0, ^{
          typeof(self) strongSelf = weakSelf;
          if (!strongSelf)
              return;
          [strongSelf connect:nil completion:nil];
          strongSelf.reconnectDelay =
              MIN(strongSelf.reconnectDelay + 2000, strongSelf.maxDelay);
        });
        self.reconnectWorkItem = work;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delayMs * NSEC_PER_MSEC)),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
            work);
    } else {
        [LogTracer
            log:[NSString stringWithFormat:@" Max reconnection attempts "
                                           @"reached. Will retry every %.0fs",
                                           self.maxDelay / 1000.0]];

        dispatch_block_t work = dispatch_block_create(0, ^{
          typeof(self) strongSelf = weakSelf;
          if (!strongSelf)
              return;
          [strongSelf connect:nil completion:nil];
        });
        self.reconnectWorkItem = work;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(self.maxDelay * NSEC_PER_MSEC)),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
            work);
    }
}

- (NSUUID *)on:(NSString *)event handler:(void (^)(id))handler {
    return [self.socket on:event handler:handler];
}

- (void)off:(NSString *)event identifier:(NSUUID *)identifier {
    [self.socket off:event identifier:identifier];
}

- (void)subscribe:(NSString *)channel
       completion:(void (^)(BaseSubscription *_Nullable,
                            NSError *_Nullable))completion {
    [self.socket subscribe:channel completion:completion];
}

- (void)intercept:(NSString *)interceptor
               fn:(void (^)(NSDictionary *, void (^)(id),
                            void (^)(NSString *)))fn
       completion:
           (void (^)(Interception *_Nullable, NSError *_Nullable))completion {
    [self.socket intercept:interceptor fn:fn completion:completion];
}

- (void)closeWebSocket:(nullable void (^)(void))completion {
    [self.socket closeWebSocket:NO completion:completion];
}

- (void)pushForSecureLine:(NSString *)event
                     data:(id)data
                   listen:(BOOL)listen
               completion:
                   (void (^)(id _Nullable, NSError *_Nullable))completion {
    [self.socket pushForSecureLine:event
                              data:data
                            listen:listen
                        completion:completion];
}

- (void)onConnectedHook:(ConnectionDetail *)connection {
    // No-op; subclasses may override.
}

- (void)encrypt:(NSString *)data
    recipientPublicKey:(NSString *)key
            completion:
                (void (^)(NSString *_Nullable, NSError *_Nullable))completion {
    if (!self.myKeyPair) {
        completion(
            nil,
            MakeError(
                ErrorCodeEncryptionError,
                @"Please generate a new key pair or set an existing key pair"));
        return;
    }

    NSError *err = nil;
    NSString *result = [CryptoBox encrypt:data
                                publicKey:key
                               privateKey:self.myKeyPair.privateKey
                                    error:&err];
    completion(result, err);
}

- (void)decrypt:(NSString *)data
    senderPublicKey:(NSString *)key
         completion:
             (void (^)(NSString *_Nullable, NSError *_Nullable))completion {
    if (!self.myKeyPair) {
        completion(
            nil,
            MakeError(
                ErrorCodeDecryptionError,
                @"Please generate a new key pair or set an existing key pair"));
        return;
    }

    NSError *err = nil;
    NSString *result = [CryptoBox decrypt:data
                                publicKey:key
                               privateKey:self.myKeyPair.privateKey
                                    error:&err];
    completion(result, err);
}

- (void)loadConfigAsync:(void (^)(AuthenticationConfig *))completion {
    AuthenticationConfig *empty = [[AuthenticationConfig alloc] init];

    NSURL *url = [NSURL URLWithString:Constant.CONFIG_JSON_PATH];
    if (!url) {
        if (completion) completion(empty);
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
          dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          AuthenticationConfig *result = empty;
          if (data && !error) {
              NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:0
                                                                     error:nil];
              if ([json isKindOfClass:[NSDictionary class]]) {
                  result = [[AuthenticationConfig alloc]
                      initWithEnvironment:json[@"Environment"] ?: @""
                               projectKey:json[@"ProjectKey"] ?: @""
                                 orgTitle:json[@"Org-Title"] ?: @""
                                 clientID:json[@"Client-ID"] ?: @""
                             clientSecret:json[@"Client-Secret"] ?: @""
                                   config:nil
                              accessToken:nil
                           getCredentials:nil];
              }
          }
          if (completion) completion(result);
        }];
    [task resume];
}

- (void)savePublicKey:(KeyPairType *)keyPair
           completion:(void (^)(NSError *_Nullable))completion {

    NSError *authErr = nil;
    Auth *auth = [Auth getInstance:nil error:&authErr];
    if (!auth) {
        if (completion)
            completion(authErr);
        return;
    }

    [auth
        authenticate:NO
          completion:^(AuthData *authData, NSError *authError) {
            if (authError) {
                if (completion)
                    completion(authError);
                return;
            }

            AuthenticationConfig *creds = [auth getCredentials];

            NSString *urlStr = [NSString
                stringWithFormat:@"%@/v1/update-publickey", Constant.BASE_URL];
            NSURL *url = [NSURL URLWithString:urlStr];
            if (!url) {
                if (completion)
                    completion(MakeError(ErrorCodeServerError,
                                         @"Malformed public key URL"));
                return;
            }

            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            req.HTTPMethod = @"POST";
            [req setValue:@"application/json"
                forHTTPHeaderField:@"Content-Type"];
            [req setValue:[NSString stringWithFormat:@"Bearer %@",
                                                     authData.accessToken]
                forHTTPHeaderField:@"Authorization"];
            [req setValue:creds.orgTitle forHTTPHeaderField:@"X-Org"];
            [req setValue:creds.environment forHTTPHeaderField:@"Environment"];
            [req setValue:creds.projectKey forHTTPHeaderField:@"ProjectKey"];

            NSError *bodyErr = nil;
            req.HTTPBody = [NSJSONSerialization
                dataWithJSONObject:@{@"public_key" : keyPair.publicKey}
                           options:0
                             error:&bodyErr];
            if (bodyErr) {
                if (completion)
                    completion(bodyErr);
                return;
            }

            NSURLSessionDataTask *task = [[NSURLSession sharedSession]
                dataTaskWithRequest:req
                  completionHandler:^(NSData *data, NSURLResponse *response,
                                      NSError *netError) {
                    if (netError) {
                        if (completion)
                            completion(netError);
                        return;
                    }

                    if (data) {
                        [LogTracer printJSONData:data
                                           title:@"SavePublicKey Response"];
                    }

                    NSHTTPURLResponse *http = nil;
                    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                        http = (NSHTTPURLResponse *)response;
                    }

                    if (!http || http.statusCode != 200) {
                        if (completion)
                            completion(MakeError(ErrorCodeServerError,
                                                 @"Error updating keypair"));
                        return;
                    }

                    self.myKeyPair = keyPair;
                    if (completion)
                        completion(nil);
                  }];
            [task resume];
          }];
}

- (void)generateKeyPair:(void (^)(KeyPairType *_Nullable,
                                  NSError *_Nullable))completion {
    NSError *err = nil;
    KeyPairType *keyPair = [CryptoBox generateKeyPair:&err];
    if (!keyPair) {
        completion(nil, err);
        return;
    }

    [self setKeyPair:keyPair
          completion:^(NSError *_Nullable setError) {
            if (setError) {
                completion(nil, setError);
            } else {
                completion(keyPair, nil);
            }
          }];
}

- (void)setKeyPair:(KeyPairType *)keyPair
        completion:(void (^)(NSError *_Nullable))completion {
    if (keyPair.publicKey.length == 0 || keyPair.privateKey.length == 0) {
        completion(
            MakeError(ErrorCodeEncryptionError,
                      @"Invalid KeyPair: keys must be non-empty strings"));
        return;
    }

    [self savePublicKey:keyPair completion:completion];
}

- (void)callEndpoint:(NSString *)endpoint
             options:(CallApiProps *)options
          completion:(void (^)(id _Nullable, NSError *_Nullable))completion {

    NSError *authErr = nil;
    Auth *auth = [Auth getInstance:nil error:&authErr];
    if (!auth) {
        completion(nil, authErr);
        return;
    }

    [auth
        authenticate:NO
          completion:^(AuthData *authData, NSError *authError) {
            if (authError) {
                completion(nil, authError);
                return;
            }

            AuthenticationConfig *creds = [auth getCredentials];

            // Build URL with optional query params
            NSMutableString *urlStr = [NSMutableString
                stringWithFormat:@"%@%@", Constant.BASE_URL, endpoint];
            if (options.queryParams.count > 0) {
                NSMutableArray<NSString *> *pairs = [NSMutableArray array];
                [options.queryParams
                    enumerateKeysAndObjectsUsingBlock:^(
                        NSString *key, NSString *val, BOOL *stop) {
                      [pairs addObject:[NSString stringWithFormat:@"%@=%@", key,
                                                                  val]];
                    }];
                [urlStr
                    appendFormat:@"?%@", [pairs componentsJoinedByString:@"&"]];
            }

            NSURL *url = [NSURL URLWithString:urlStr];
            if (!url) {
                completion(
                    nil,
                    MakeError(
                        ErrorCodeServerError,
                        [NSString stringWithFormat:@"Malformed API URL: %@",
                                                   endpoint]));
                return;
            }

            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            req.HTTPMethod = [options.method uppercaseString];
            [req setValue:[NSString stringWithFormat:@"Bearer %@",
                                                     authData.accessToken]
                forHTTPHeaderField:@"Authorization"];
            [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
            [req setValue:creds.orgTitle forHTTPHeaderField:@"X-Org"];
            [req setValue:creds.environment forHTTPHeaderField:@"Environment"];
            [req setValue:creds.projectKey forHTTPHeaderField:@"ProjectKey"];

            // Custom headers
            [options.headers enumerateKeysAndObjectsUsingBlock:^(
                                 NSString *key, NSString *val, BOOL *stop) {
              [req setValue:val forHTTPHeaderField:key];
            }];

            // Body payload
            if (options.payload) {
                [req setValue:@"application/json"
                    forHTTPHeaderField:@"Content-Type"];
                NSError *bodyErr = nil;
                req.HTTPBody =
                    [NSJSONSerialization dataWithJSONObject:options.payload
                                                    options:0
                                                      error:&bodyErr];
                if (bodyErr) {
                    completion(nil, bodyErr);
                    return;
                }
            }

            NSURLSessionDataTask *task = [[NSURLSession sharedSession]
                dataTaskWithRequest:req
                  completionHandler:^(NSData *data, NSURLResponse *response,
                                      NSError *netError) {
                    if (netError) {
                        completion(nil, netError);
                        return;
                    }

                    NSHTTPURLResponse *http = nil;
                    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                        http = (NSHTTPURLResponse *)response;
                    }
                    if (!http) {
                        completion(nil, MakeError(ErrorCodeServerError,
                                                  @"No HTTP response"));
                        return;
                    }

                    // 204 No Content
                    if (http.statusCode == 204) {
                        completion([NSNull null], nil);
                        return;
                    }

                    // Non-success
                    if (http.statusCode < 200 || http.statusCode >= 300) {
                        NSString *msg = nil;
                        if (data) {
                            NSDictionary *body =
                                [NSJSONSerialization JSONObjectWithData:data
                                                                options:0
                                                                  error:nil];
                            if ([body isKindOfClass:[NSDictionary class]]) {
                                msg = body[@"message"];
                            }
                        }
                        if (![msg isKindOfClass:[NSString class]] ||
                            msg.length == 0) {
                            msg = [NSHTTPURLResponse
                                localizedStringForStatusCode:http.statusCode];
                        }
                        completion(
                            nil,
                            MakeError(
                                ErrorCodeServerError,
                                [NSString stringWithFormat:@"API %@ failed: %@",
                                                           endpoint, msg]));
                        return;
                    }

                    // Parse JSON response
                    if (!data) {
                        completion(nil, MakeError(ErrorCodeServerError,
                                                  @"Empty response body"));
                        return;
                    }

                    NSError *jsonErr = nil;
                    id result =
                        [NSJSONSerialization JSONObjectWithData:data
                                                        options:0
                                                          error:&jsonErr];
                    if (jsonErr) {
                        completion(nil, jsonErr);
                        return;
                    }

                    completion(result, nil);
                  }];
            [task resume];
          }];
}

@end
