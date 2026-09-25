//
//  Adk.m
//  ADK
//

#import "Adk.h"
#import "ARTConnector.h"
#import "ARTPlugin.h"
#import "ARTStorage.h"
#import "ARTSupport.h"
#import "Agent.h"
#import "Auth.h"
#import "AuthTypes.h"
#import "BaseSubscription.h"
#import "ChannelTypes.h"
#import "Constant.h"
#import "CryptoBox.h"
#import "CryptoTypes.h"
#import "HTTPCall.h"
#import "Interception.h"
#import "Orchestrator.h"
#import "Socket.h"
#import "SocketTypes.h"
#import "Utils.h"

@interface Adk ()

@property(nonatomic, strong, readwrite) Socket *socket;
@property(atomic, assign, readwrite) AdkState state;

/// Guards the connection flags, credentials, plugins and handlers below.
@property(nonatomic, strong, readonly) NSObject *lock;

// Reconnection state
@property(nonatomic, assign) NSInteger reconnectAttempts;
@property(nonatomic, assign) NSInteger maxReconnectAttempts;
@property(nonatomic, assign) double reconnectDelay; // ms
@property(nonatomic, assign) double maxDelay;       // ms

// SDK config
@property(nonatomic, strong, nullable) AdkConfig *adkConfig;
/// Credentials from `setCredentials:` or `adk-services.json`.
@property(nonatomic, strong, nullable) CredentialStore *credentialData;

// Flags
@property(nonatomic, assign) BOOL isPaused;
@property(nonatomic, assign) BOOL isConnectable;
/// Set once the server reports a billing / concurrency limit. Latches
/// auto-reconnection off: `handleOnClose` / `handleReconnection` return
/// early while it is YES.
@property(nonatomic, assign) BOOL isLimitExceeded;

// Reconnect dispatch work item
@property(nonatomic, strong, nullable) dispatch_block_t reconnectWorkItem;

// Event listener identifiers
@property(nonatomic, strong) NSUUID *connectionListenerId;
@property(nonatomic, strong) NSUUID *closeListenerId;
@property(nonatomic, strong) NSUUID *limitListenerId;

// Agentic reconnect hooks
@property(nonatomic, strong)
    NSMutableDictionary<NSUUID *, void (^)(void)> *reconnectedHandlers;
@property(nonatomic, assign) BOOL hasConnectedOnce;

/// Installed plugin APIs, keyed by plugin name.
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *plugins;

@end

@implementation Adk

- (instancetype)initWithConfig:(nullable AdkConfig *)config {
    self = [super init];
    if (self) {
        _lock = [[NSObject alloc] init];
        _adkConfig = config;
        _state = AdkStateStopped;
        _reconnectAttempts = 0;
        _maxReconnectAttempts = 5;
        _reconnectDelay = 3000; // 3 seconds
        _maxDelay = 5000;       // 5 seconds
        _isPaused = NO;
        _isConnectable = NO;
        _isLimitExceeded = NO;
        _reconnectedHandlers = [NSMutableDictionary dictionary];
        _hasConnectedOnce = NO;
        _plugins = [NSMutableDictionary dictionary];

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
                  if ([data isKindOfClass:[ConnectionDetail class]]) {
                      [strongSelf handleOnConnection:(ConnectionDetail *)data];
                  }
                }];

        _closeListenerId = [_socket on:@"close"
                               handler:^(id data) {
                                 [weakSelf handleOnClose];
                               }];

        _limitListenerId = [_socket
                 on:@"limitExceeded"
            handler:^(id data) {
              typeof(self) strongSelf = weakSelf;
              if (!strongSelf) {
                  return;
              }
              NSDictionary *info = [data isKindOfClass:[NSDictionary class]]
                                       ? (NSDictionary *)data
                                       : @{};
              NSString *code = info[@"code"] ?: @"";
              NSString *errText = info[@"error"] ?: @"";
              if ([code isEqualToString:@"CONCURRENT_LIMIT_EXCEEDED"]) {
                  NSLog(@"[ART] Concurrent connection limit reached: %@. All "
                        @"reconnection attempts stopped. Call connect() again "
                        @"to retry.",
                        errText);
              } else {
                  NSLog(@"[ART] Billing limit reached: %@. All reconnection "
                        @"attempts permanently stopped.",
                        errText);
              }
              @synchronized(strongSelf.lock) {
                  strongSelf.isLimitExceeded = YES;
                  strongSelf.isConnectable = NO;
                  strongSelf.state = AdkStateStopped;
              }
            }];
    }
    return self;
}

- (void)dealloc {
    // Unregister our socket listeners so their blocks don't accumulate in
    // the long-lived Socket singleton's emitter.
    if (_socket) {
        if (_connectionListenerId) {
            [_socket off:@"connection" identifier:_connectionListenerId];
        }
        if (_closeListenerId) {
            [_socket off:@"close" identifier:_closeListenerId];
        }
        if (_limitListenerId) {
            [_socket off:@"limitExceeded" identifier:_limitListenerId];
        }
    }
    if (_reconnectWorkItem) {
        dispatch_block_cancel(_reconnectWorkItem);
        _reconnectWorkItem = nil;
    }
}

#pragma mark - Connect

- (void)connect:(nullable ConnectConfig *)config
     completion:(nullable void (^)(void))completion {
    __weak typeof(self) weakSelf = self;
    void (^start)(void) = ^{
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf) {
          if (completion) {
              completion();
          }
          return;
      }
      @synchronized(strongSelf.lock) {
          strongSelf.isConnectable = YES;
          strongSelf.state = AdkStateConnecting;
      }
      [strongSelf initiateSocketConnection:^{
        typeof(self) strongSelf2 = weakSelf;
        if (strongSelf2 && strongSelf2.socket.isConnectionActive) {
            @synchronized(strongSelf2.lock) {
                if (strongSelf2.state == AdkStateConnecting) {
                    strongSelf2.state = AdkStateConnected;
                }
            }
        }
        if (completion) {
            completion();
        }
      }];
    };

    if (!self.adkConfig.getCredentials) {
        BOOL hasCredentials;
        @synchronized(self.lock) {
            hasCredentials = self.credentialData != nil;
        }
        if (self.adkConfig.autoLoadCredsFromJSON || !hasCredentials) {
            [self loadConfig:^(CredentialStore *_Nullable loaded) {
              typeof(self) strongSelf = weakSelf;
              if (loaded && strongSelf) {
                  @synchronized(strongSelf.lock) {
                      strongSelf.credentialData = loaded;
                  }
              }
              start();
            }];
            return;
        }
    }
    start();
}

- (void)setCredentials:(CredentialStore *)credentials {
    CredentialStore *store = [credentials copy];
    store.config = nil;
    @synchronized(self.lock) {
        self.credentialData = store;
    }
}

- (void)pause {
    BOOL shouldPause = NO;
    @synchronized(self.lock) {
        if (!self.isPaused) {
            shouldPause = YES;
            self.isPaused = YES;
            self.reconnectAttempts = self.maxReconnectAttempts;
            self.state = AdkStatePaused;
        }
    }
    if (!shouldPause) {
        return;
    }
    [self cancelReconnect];
    [self.socket closeWebSocket:NO completion:nil];
}

- (void)resume:(nullable void (^)(void))completion {
    BOOL shouldResume = NO;
    @synchronized(self.lock) {
        if (self.isPaused) {
            shouldResume = YES;
            self.isPaused = NO;
            self.reconnectAttempts = 0;
            self.reconnectDelay = 3000;
            self.state = AdkStateConnecting;
        }
    }
    if (!shouldResume) {
        if (completion) {
            completion();
        }
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self.socket connectWebSocket:^(NSError *_Nullable error) {
      typeof(self) strongSelf = weakSelf;
      if (strongSelf && strongSelf.socket.isConnectionActive) {
          @synchronized(strongSelf.lock) {
              if (strongSelf.state == AdkStateConnecting) {
                  strongSelf.state = AdkStateConnected;
              }
          }
      }
      if (completion) {
          completion();
      }
    }];
}

- (void)disconnect:(nullable void (^)(void))completion {
    @synchronized(self.lock) {
        self.isConnectable = NO;
        self.reconnectAttempts = self.maxReconnectAttempts;
        self.state = AdkStateStopped;
    }
    [self cancelReconnect];

    __weak typeof(self) weakSelf = self;
    [self.socket closeWebSocket:YES
                     completion:^{
                       weakSelf.socket.isConnectionActive = NO;
                       if (completion) {
                           completion();
                       }
                     }];
}

- (NSString *)getState {
    BOOL paused;
    NSInteger attempts;
    @synchronized(self.lock) {
        paused = self.isPaused;
        attempts = self.reconnectAttempts;
    }
    if (paused)
        return @"paused";
    if (attempts >= self.maxReconnectAttempts)
        return @"stopped";
    if (attempts > 0)
        return @"retrying";
    if (self.socket.isConnectionActive)
        return @"connected";
    return @"stopped";
}

- (void)initiateSocketConnection:(void (^)(void))completion {
    AuthenticationConfig *authConfig = nil;
    CredentialStore *_Nonnull (^provider)(void) = self.adkConfig.getCredentials;
    CredentialStore *store = nil;
    if (provider) {
        store = provider();
    } else {
        @synchronized(self.lock) {
            store = self.credentialData;
        }
    }

    if (!store) {
        ARTLogError(@"Configuration not loaded — call setCredentials:, set "
                    @"AdkConfig.getCredentials, or provide adk-services.json");
        @synchronized(self.lock) {
            self.state = AdkStateStopped;
        }
        completion();
        return;
    }

    authConfig = [[AuthenticationConfig alloc] initWithEnvironment:store.environment
                                                        projectKey:store.projectKey
                                                          orgTitle:store.orgTitle
                                                          clientID:store.clientID
                                                      clientSecret:store.clientSecret
                                                            config:nil
                                                       accessToken:store.accessToken
                                                    getCredentials:nil];
    authConfig.config = self.adkConfig;
    authConfig.getCredentials = self.adkConfig.getCredentials;
    [self.socket initiateSocket:authConfig
                     completion:^(NSError *_Nullable error) {
                       completion();
                     }];
}

#pragma mark - Connection events

- (void)handleOnConnection:(ConnectionDetail *)connection {
    BOOL wasReconnect;
    NSArray<void (^)(void)> *handlers;
    @synchronized(self.lock) {
        wasReconnect = self.hasConnectedOnce;
        self.hasConnectedOnce = YES;
        self.reconnectAttempts = 0;
        self.reconnectDelay = 3000;
        if (!self.isPaused) {
            self.state = AdkStateConnected;
        }
        handlers = [self.reconnectedHandlers.allValues copy];
    }
    [self onConnectedHook:connection];

    // After every connect but the first, let agentic threads re-attach
    // their listeners.
    if (wasReconnect) {
        for (void (^handler)(void) in handlers) {
            handler();
        }
    }
}

- (void)handleOnClose {
    @synchronized(self.lock) {
        // Billing / concurrency limit: never reconnect automatically.
        if (self.isLimitExceeded) {
            self.state = AdkStateStopped;
            return;
        }
        // Paused: stay closed until resume.
        if (self.isPaused) {
            return;
        }
        if (!self.isConnectable) {
            self.state = AdkStateStopped;
            return;
        }
        self.state = AdkStateConnecting;
    }
    self.socket.isReConnecting = YES;
    [self handleReconnection];
}

- (void)cancelReconnect {
    dispatch_block_t work;
    @synchronized(self.lock) {
        work = self.reconnectWorkItem;
        self.reconnectWorkItem = nil;
    }
    if (work) {
        dispatch_block_cancel(work);
    }
}

- (void)handleReconnection {
    [self cancelReconnect];

    double delayMs;
    BOOL growDelay;
    NSInteger attempt;
    @synchronized(self.lock) {
        if (self.isLimitExceeded) {
            return;
        }
        if (self.reconnectAttempts < self.maxReconnectAttempts) {
            self.reconnectAttempts++;
            delayMs = self.reconnectDelay;
            growDelay = YES;
        } else {
            delayMs = self.maxDelay;
            growDelay = NO;
        }
        attempt = self.reconnectAttempts;
    }
    if (growDelay) {
        ARTLogInfo(@"Attempting to reconnect in %g seconds... (Attempt %ld)",
                   delayMs / 1000.0, (long)attempt);
    } else {
        ARTLogWarn(@"Max reconnection attempts reached. Will retry every %g "
                   @"seconds.",
                   self.maxDelay / 1000.0);
    }

    __weak typeof(self) weakSelf = self;
    dispatch_block_t work = dispatch_block_create(0, ^{
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf) {
          return;
      }
      BOOL stillWanted;
      @synchronized(strongSelf.lock) {
          stillWanted = strongSelf.isConnectable && !strongSelf.isPaused &&
                        !strongSelf.isLimitExceeded;
      }
      if (!stillWanted) {
          return;
      }
      [strongSelf connect:nil completion:nil];
      if (growDelay) {
          // Linear backoff, capped at maxDelay.
          @synchronized(strongSelf.lock) {
              strongSelf.reconnectDelay =
                  MIN(strongSelf.reconnectDelay + 2000, strongSelf.maxDelay);
          }
      }
    });
    @synchronized(self.lock) {
        self.reconnectWorkItem = work;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delayMs * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                   work);
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

#pragma mark - Agentic

- (Agent *)agent:(NSString *)agentId {
    return [[Agent alloc] initWithAgentId:agentId socket:self.socket];
}

- (Orchestrator *)orchestrator:(NSString *)orchestratorId {
    return [[Orchestrator alloc] initWithOrchestratorId:orchestratorId
                                                 socket:self.socket];
}

- (NSUUID *)onReconnected:(void (^)(void))handler {
    NSUUID *identifier = [NSUUID UUID];
    @synchronized(self.lock) {
        self.reconnectedHandlers[identifier] = [handler copy];
    }
    return identifier;
}

- (void)offReconnected:(NSUUID *)identifier {
    if (identifier) {
        @synchronized(self.lock) {
            [self.reconnectedHandlers removeObjectForKey:identifier];
        }
    }
}

#pragma mark - Profiles

- (void)updateProfile:(ARTUpdateProfileData *)data
           completion:(void (^)(NSError *_Nullable))completion {
    CallApiProps *props = [[CallApiProps alloc] initWithMethod:@"POST"
                                                       payload:[data payload]
                                                   queryParams:nil
                                                       headers:nil];
    [ARTHTTPClient call:@"/v1/update-profile"
                options:props
             completion:^(id result, NSError *error) {
               if (completion) {
                   completion(error);
               }
             }];
}

- (nullable ARTConnector *)connector:(NSString *)connectorId
                               error:(NSError **)error {
    return [[ARTConnector alloc] initWithConnectorId:connectorId
                                             handler:self.socket
                                               error:error];
}

#pragma mark - Plugins

- (id)use:(id<ARTAdkPlugin>)plugin {
    id api = [plugin installWithContext:[self pluginContext]];
    if (api) {
        @synchronized(self.lock) {
            self.plugins[plugin.name] = api;
        }
    }
    return api;
}

- (nullable id)pluginNamed:(NSString *)name {
    @synchronized(self.lock) {
        return self.plugins[name];
    }
}

- (ARTAdkPluginContext *)pluginContext {
    Socket *socket = self.socket;
    return [[ARTAdkPluginContext alloc]
        initWithSubscribe:^(NSString *channel,
                            void (^completion)(BaseSubscription *_Nullable,
                                               NSError *_Nullable)) {
          [socket subscribe:channel completion:completion];
        }
        call:^(NSString *endpoint, CallApiProps *options,
               void (^completion)(id _Nullable, NSError *_Nullable)) {
          [ARTHTTPClient call:endpoint options:options completion:completion];
        }
        getCredentials:^AuthenticationConfig * {
          return [[Auth getInstance:nil error:nil] getCredentials];
        }
        baseUrl:^NSString * {
          return ARTGateway.origin;
        }];
}

#pragma mark - Storage

- (void)uploadFileURL:(NSURL *)fileURL
              options:(ARTUploadOptions *)options
           completion:(void (^)(ARTFileRef *_Nullable,
                                NSError *_Nullable))completion {
    [[[ARTStorage alloc] init] uploadFileURL:fileURL
                                     options:options
                                  completion:completion];
}

- (void)uploadData:(NSData *)data
          filename:(NSString *)filename
       contentType:(NSString *)contentType
           options:(ARTUploadOptions *)options
        completion:(void (^)(ARTFileRef *_Nullable,
                             NSError *_Nullable))completion {
    [[[ARTStorage alloc] init] uploadData:data
                                 filename:filename
                              contentType:contentType
                                  options:options
                               completion:completion];
}

- (void)listFilesWithOptions:(ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable,
                                       NSError *_Nullable))completion {
    [[[ARTStorage alloc] init] listFilesWithOptions:options completion:completion];
}

- (void)getFile:(NSString *)fileId
      timeoutMs:(NSNumber *)timeoutMs
     completion:(void (^)(ARTStorageFile *_Nullable,
                          NSError *_Nullable))completion {
    [[[ARTStorage alloc] init] getFile:fileId
                             timeoutMs:timeoutMs
                            completion:completion];
}

- (void)deleteFile:(NSString *)fileId
              hard:(BOOL)hard
         timeoutMs:(NSNumber *)timeoutMs
        completion:(void (^)(NSError *_Nullable))completion {
    [[[ARTStorage alloc] init] deleteFile:fileId
                                     hard:hard
                                timeoutMs:timeoutMs
                               completion:^(NSError *error) {
                                 if (completion) {
                                     completion(error);
                                 }
                               }];
}

#pragma mark - Channels and crypto

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

#pragma mark - adk-services.json

/// Looks for the credentials file, in order: an absolute URL in
/// `Constant.CONFIG_JSON_PATH`, `AdkConfig.root` + `CONFIG_FILE_NAME`, then
/// the app bundle. Keys: `Client-ID`, `Client-Secret`, `Environment`,
/// `Org-Title`, `ProjectKey`.
- (void)loadConfig:(void (^)(CredentialStore *_Nullable))completion {
    [self readConfigData:^(NSData *_Nullable data) {
      id json = data ? [ARTJSON parseData:data] : nil;
      if (![json isKindOfClass:[NSDictionary class]]) {
          ARTLogWarn(@"Failed to load configuration (%@)",
                     Constant.CONFIG_FILE_NAME);
          completion(nil);
          return;
      }
      NSString * (^value)(NSString *) = ^NSString *(NSString *key) {
        id v = ((NSDictionary *)json)[key];
        return [v isKindOfClass:[NSString class]] ? v : @"";
      };
      completion([[CredentialStore alloc] initWithEnvironment:value(@"Environment")
                                                   projectKey:value(@"ProjectKey")
                                                     orgTitle:value(@"Org-Title")
                                                     clientID:value(@"Client-ID")
                                                 clientSecret:value(@"Client-Secret")
                                                       config:nil
                                                  accessToken:nil]);
    }];
}

- (void)readConfigData:(void (^)(NSData *_Nullable))completion {
    NSURL *url = [NSURL URLWithString:Constant.CONFIG_JSON_PATH];
    if (url.scheme.length > 0) {
        if (url.isFileURL) {
            completion([NSData dataWithContentsOfURL:url]);
            return;
        }
        [[ARTHTTPClient.session
              dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response,
                                NSError *error) {
              NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                                     ? ((NSHTTPURLResponse *)response).statusCode
                                     : 0;
              completion((!error && status >= 200 && status < 300) ? data : nil);
            }] resume];
        return;
    }

    NSString *root = self.adkConfig.root;
    if (root.length > 0) {
        NSString *path =
            [root stringByAppendingPathComponent:Constant.CONFIG_FILE_NAME];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data) {
            completion(data);
            return;
        }
    }

    NSString *fileName = Constant.CONFIG_FILE_NAME;
    NSString *extension = fileName.pathExtension;
    NSURL *bundled = [[NSBundle mainBundle]
        URLForResource:fileName.stringByDeletingPathExtension
         withExtension:extension.length > 0 ? extension : nil];
    completion(bundled ? [NSData dataWithContentsOfURL:bundled] : nil);
}

#pragma mark - Key pairs

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
            NSString *body =
                [ARTJSON stringify:@{@"public_key" : keyPair.publicKey ?: @""}
                             error:&bodyErr];
            if (!body) {
                if (completion)
                    completion(bodyErr);
                return;
            }
            req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

            NSURLSessionDataTask *task = [ARTHTTPClient.session
                dataTaskWithRequest:req
                  completionHandler:^(NSData *data, NSURLResponse *response,
                                      NSError *netError) {
                    if (netError) {
                        if (completion)
                            completion(netError);
                        return;
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

#pragma mark - REST

- (void)callEndpoint:(NSString *)endpoint
             options:(CallApiProps *)options
          completion:(void (^)(id _Nullable, NSError *_Nullable))completion {
    [ARTHTTPClient call:endpoint
                options:options
             completion:^(id result, NSError *error) {
               if (error) {
                   completion(nil, error);
                   return;
               }
               // Kept for compatibility: an empty response is NSNull.
               completion(result ?: [NSNull null], nil);
             }];
}

@end
