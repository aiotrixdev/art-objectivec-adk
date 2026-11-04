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

/// Callers waiting for the connection attempt in flight; nil when there is
/// none. Concurrent `connect:completion:` calls and reconnects join it.
@property(nonatomic, strong, nullable)
    NSMutableArray<void (^)(NSError *_Nullable)> *attemptWaiters;

/// `@[event, identifier]` pairs this instance registered on the shared
/// socket; `disconnect:` removes them and `connect:completion:` adds them
/// back.
@property(nonatomic, strong) NSMutableArray<NSArray *> *socketListeners;

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

        _socketListeners = [NSMutableArray array];
        [self attachSocketListeners];
    }
    return self;
}

- (void)dealloc {
    // Unregister our socket listeners so their blocks don't accumulate in
    // the long-lived Socket singleton's emitter.
    for (NSArray *listener in _socketListeners) {
        [_socket off:listener[0] identifier:listener[1]];
    }
    if (_reconnectWorkItem) {
        dispatch_block_cancel(_reconnectWorkItem);
        _reconnectWorkItem = nil;
    }
}

#pragma mark - Socket listeners

- (void)attachSocketListeners {
    @synchronized(self.lock) {
        if (self.socketListeners.count > 0) {
            return;
        }
        __weak typeof(self) weakSelf = self;
        NSDictionary<NSString *, void (^)(id)> *handlers = @{
            @"connection" : ^(id data) {
              if ([data isKindOfClass:[ConnectionDetail class]]) {
                  [weakSelf handleOnConnection:(ConnectionDetail *)data];
              }
            },
            @"close" : ^(id data) {
              [weakSelf handleOnClose];
            },
            @"limitExceeded" : ^(id data) {
              [weakSelf handleLimitExceeded:data];
            },
            @"authenticationFailed" : ^(id data) {
              [weakSelf handleAuthenticationFailed:data];
            },
            @"connectionFailed" : ^(id data) {
              [weakSelf handleConnectionFailed];
            },
        };
        for (NSString *event in handlers) {
            [self.socketListeners
                addObject:@[ event, [self.socket on:event handler:handlers[event]] ]];
        }
    }
}

- (void)detachSocketListeners {
    NSArray<NSArray *> *listeners;
    @synchronized(self.lock) {
        listeners = [self.socketListeners copy];
        [self.socketListeners removeAllObjects];
    }
    for (NSArray *listener in listeners) {
        [self.socket off:listener[0] identifier:listener[1]];
    }
}

- (void)handleLimitExceeded:(id)data {
    NSDictionary *info =
        [data isKindOfClass:[NSDictionary class]] ? (NSDictionary *)data : @{};
    NSString *code = info[@"code"] ?: @"";
    NSString *errText = info[@"error"] ?: @"";
    if ([code isEqualToString:ARTConnectionErrorCodeConcurrentLimitExceeded]) {
        ARTLogError(@"[ART] Concurrent connection limit reached: %@. All "
                    @"reconnection attempts stopped. Call connect() again "
                    @"to retry.",
                    errText);
    } else {
        ARTLogError(@"[ART] Billing limit reached: %@. All reconnection "
                    @"attempts permanently stopped.",
                    errText);
    }
    @synchronized(self.lock) {
        self.isLimitExceeded = YES;
        self.isConnectable = NO;
        self.state = AdkStateStopped;
    }
    [self cancelReconnect];
}

- (void)handleAuthenticationFailed:(id)data {
    ARTAuthenticationFailedDetail *detail =
        [data isKindOfClass:[ARTAuthenticationFailedDetail class]] ? data : nil;
    ARTLogError(@"[ART] Authentication rejected%@: %@. Automatic reconnection "
                @"has been stopped. Update the credentials and call connect() "
                @"again.",
                detail.status != 0
                    ? [NSString stringWithFormat:@" with HTTP %ld", (long)detail.status]
                    : @"",
                detail.error ?: data);
    @synchronized(self.lock) {
        self.isConnectable = NO;
        self.state = AdkStateStopped;
    }
    [self cancelReconnect];
    self.socket.isReConnecting = NO;
}

- (void)handleConnectionFailed {
    @synchronized(self.lock) {
        self.isConnectable = NO;
        self.state = AdkStateStopped;
    }
    [self cancelReconnect];
}

#pragma mark - Connect

- (void)connect:(nullable ConnectConfig *)config
     completion:(nullable void (^)(NSError *_Nullable))completion {
    void (^finish)(NSError *) = completion ?: ^(NSError *error) {
    };

    // A call made while an attempt is in flight joins it.
    BOOL joined = NO;
    @synchronized(self.lock) {
        if (self.attemptWaiters) {
            [self.attemptWaiters addObject:[finish copy]];
            joined = YES;
        }
    }
    if (joined) {
        return;
    }

    [self attachSocketListeners];
    if (self.socket.isConnectionActive) {
        @synchronized(self.lock) {
            self.isConnectable = YES;
            self.state = AdkStateConnected;
        }
        finish(nil);
        return;
    }

    [self cancelReconnect];
    @synchronized(self.lock) {
        self.isPaused = NO;
        self.isLimitExceeded = NO;
        self.reconnectAttempts = 0;
        self.reconnectDelay = 3000;
    }

    NSError *timeoutError = nil;
    if (![self.socket
            beginConnectionWithTimeoutMs:self.adkConfig ? self.adkConfig.connectionTimeoutMs
                                                        : 30000
                                   error:&timeoutError]) {
        finish(timeoutError);
        return;
    }

    void (^start)(void) = ^{
      @synchronized(self.lock) {
          self.isConnectable = YES;
          self.state = AdkStateConnecting;
      }
      [self attemptConnection:^(NSError *_Nullable error) {
        @synchronized(self.lock) {
            self.state = error ? AdkStateStopped : [self settledState];
        }
        finish(error);
      }];
    };

    if (!self.adkConfig.getCredentials) {
        BOOL hasCredentials;
        @synchronized(self.lock) {
            hasCredentials = self.credentialData != nil;
        }
        if (self.adkConfig.autoLoadCredsFromJSON || !hasCredentials) {
            [self loadConfig:^(CredentialStore *_Nullable loaded) {
              if (loaded) {
                  @synchronized(self.lock) {
                      self.credentialData = loaded;
                  }
              }
              start();
            }];
            return;
        }
    }
    start();
}

/// Opens the transport and waits until the connection is ready, sharing one
/// attempt between concurrent callers. The readiness wait starts together
/// with the attempt, so it bounds authentication too. The first failure ends
/// the attempt.
- (void)attemptConnection:(void (^)(NSError *_Nullable))completion {
    BOOL running = NO;
    @synchronized(self.lock) {
        if (self.attemptWaiters) {
            running = YES;
            [self.attemptWaiters addObject:[completion copy]];
        } else {
            self.attemptWaiters = [NSMutableArray arrayWithObject:[completion copy]];
        }
    }
    if (running) {
        return;
    }

    NSObject *gate = [[NSObject alloc] init];
    __block NSInteger remaining = 2;
    void (^stepFinished)(NSError *) = ^(NSError *error) {
      @synchronized(gate) {
          if (remaining == 0) {
              return;
          }
          remaining = error ? 0 : remaining - 1;
          if (remaining > 0) {
              return;
          }
      }
      NSArray<void (^)(NSError *_Nullable)> *waiters;
      @synchronized(self.lock) {
          waiters = [self.attemptWaiters copy];
          self.attemptWaiters = nil;
      }
      for (void (^waiter)(NSError *_Nullable) in waiters) {
          waiter(error);
      }
    };
    [self initiateSocketConnection:stepFinished];
    [self.socket wait:stepFinished];
}

/// `state` after a connection attempt succeeded. Call with `lock` held.
- (AdkState)settledState {
    if (self.socket.isConnectionActive) {
        return AdkStateConnected;
    }
    return self.isConnectable ? AdkStateConnecting : AdkStateStopped;
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
            self.isConnectable = NO;
            self.reconnectAttempts = self.maxReconnectAttempts;
        }
    }
    if (!shouldPause) {
        return;
    }
    [self cancelReconnect];
    [self.socket failConnection:[ARTConnectionError
                                    errorWithMessage:@"The connection is paused."
                                                code:ARTConnectionErrorCodePaused]];
    @synchronized(self.lock) {
        self.state = AdkStatePaused;
    }
}

- (void)resume:(nullable void (^)(NSError *_Nullable))completion {
    BOOL paused;
    @synchronized(self.lock) {
        paused = self.isPaused;
    }
    if (!paused) {
        if (completion) {
            completion(nil);
        }
        return;
    }
    [self connect:nil completion:completion];
}

- (void)disconnect:(nullable void (^)(void))completion {
    @synchronized(self.lock) {
        self.isConnectable = NO;
        self.reconnectAttempts = self.maxReconnectAttempts;
    }
    [self cancelReconnect];
    [self.socket failConnection:[ARTConnectionError
                                    errorWithMessage:@"The connection was closed."
                                                code:ARTConnectionErrorCodeClosed]];
    [self.socket closeWebSocket:YES
                     completion:^{
                       @synchronized(self.lock) {
                           self.state = AdkStateStopped;
                       }
                       self.socket.isConnectionActive = NO;
                       [self detachSocketListeners];
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

- (void)initiateSocketConnection:(void (^)(NSError *_Nullable))completion {
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
        ARTConnectionError *error = [ARTConnectionError
            errorWithMessage:@"Connection credentials are missing. Please sign in again."
                        code:ARTConnectionErrorCodeAuthenticationFailed];
        [self.socket failConnection:error];
        completion(error);
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
    [self.socket initiateSocket:authConfig completion:completion];
}

#pragma mark - Connection events

- (void)handleOnConnection:(ConnectionDetail *)connection {
    [self cancelReconnect];
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
        // The attempt in flight reports its own outcome.
        if (self.attemptWaiters) {
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

/// Schedules the next reconnect attempt; after `maxReconnectAttempts` the
/// connection fails with `ARTConnectionErrorCodeLost`.
- (void)handleReconnection {
    BOOL skip = NO;
    BOOL giveUp = NO;
    double delayMs = 0;
    NSInteger attempt = 0;
    dispatch_block_t work = nil;
    @synchronized(self.lock) {
        if (self.isLimitExceeded || !self.isConnectable || self.isPaused ||
            self.reconnectWorkItem) {
            skip = YES;
        } else if (self.reconnectAttempts >= self.maxReconnectAttempts) {
            giveUp = YES;
        } else {
            self.reconnectAttempts++;
            delayMs = self.reconnectDelay;
            attempt = self.reconnectAttempts;
            __weak typeof(self) weakSelf = self;
            work = dispatch_block_create(0, ^{
              [weakSelf runReconnectAttempt];
            });
            self.reconnectWorkItem = work;
        }
    }
    if (skip) {
        return;
    }
    if (giveUp) {
        [self.socket
            failConnection:[ARTConnectionError
                               errorWithMessage:@"The connection could not be restored. "
                                                @"Please reconnect to check your execution."
                                           code:ARTConnectionErrorCodeLost]];
        return;
    }
    ARTLogInfo(@"Attempting to reconnect in %g seconds... (Attempt %ld)",
               delayMs / 1000.0, (long)attempt);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delayMs * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                   work);
}

- (void)runReconnectAttempt {
    BOOL stillWanted = NO;
    @synchronized(self.lock) {
        self.reconnectWorkItem = nil;
        if (self.isConnectable && !self.isPaused && !self.isLimitExceeded) {
            stillWanted = YES;
            self.state = AdkStateConnecting;
            // Linear backoff, capped at maxDelay.
            self.reconnectDelay = MIN(self.reconnectDelay + 2000, self.maxDelay);
        }
    }
    if (!stillWanted) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self attemptConnection:^(NSError *_Nullable error) {
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf) {
          return;
      }
      BOOL retry = NO;
      @synchronized(strongSelf.lock) {
          if (!error) {
              strongSelf.state = [strongSelf settledState];
          } else {
              retry = strongSelf.isConnectable;
          }
      }
      if (retry) {
          [strongSelf handleReconnection];
      }
    }];
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

- (nullable Agent *)agent:(NSString *)agentId error:(NSError **)error {
    return [[Agent alloc] initWithAgentId:agentId socket:self.socket error:error];
}

- (nullable Orchestrator *)orchestrator:(NSString *)orchestratorId
                                  error:(NSError **)error {
    return [[Orchestrator alloc] initWithOrchestratorId:orchestratorId
                                                 socket:self.socket
                                                  error:error];
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
       threadId:(NSString *)threadId
      timeoutMs:(NSNumber *)timeoutMs
     completion:(void (^)(ARTStorageFile *_Nullable,
                          NSError *_Nullable))completion {
    [[[ARTStorage alloc] init] getFile:fileId
                              threadId:threadId
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
    @synchronized(self.lock) {
        self.isConnectable = NO;
    }
    [self cancelReconnect];
    [self.socket failConnection:[ARTConnectionError
                                    errorWithMessage:@"The connection was closed."
                                                code:ARTConnectionErrorCodeClosed]];
    [self.socket closeWebSocket:NO
                     completion:^{
                       @synchronized(self.lock) {
                           self.state = AdkStateStopped;
                       }
                       if (completion) {
                           completion();
                       }
                     }];
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
