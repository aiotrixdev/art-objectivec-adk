//
//  Socket.m
//  ADK
//

#import "Socket.h"
#import "ARTSupport.h"
#import "Auth.h"
#import "AuthTypes.h"
#import "BaseSubscription.h"
#import "ChannelTypes.h"
#import "Constant.h"
#import "CryptoTypes.h"
#import "EventEmitter.h"
#import "HTTPCall+Internal.h"
#import "HelperFunctions.h"
#import "HttpPoll.h"
#import "Interception.h"
#import "LiveObjSubscription.h"
#import "Subscription.h"
#import "Utils.h"

typedef void (^ARTSocketCompletion)(NSError *_Nullable error);
typedef void (^ARTSecureCompletion)(id _Nullable result, NSError *_Nullable error);

/// A `wait:` call waiting for the connection.
@interface ARTConnectionWaiter : NSObject
@property(nonatomic, copy) ARTSocketCompletion completion;
@property(nonatomic, strong) dispatch_block_t timer;
@end

@implementation ARTConnectionWaiter
@end

/// A control request on the `art_secure` line waiting for its reply.
@interface ARTSecureRequest : NSObject
@property(nonatomic, copy) ARTSecureCompletion completion;
@property(nonatomic, strong) dispatch_block_t timer;
@end

@implementation ARTSecureRequest
@end

/// The live transport, detached from the socket's state.
@interface ARTSocketTeardown : NSObject
@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *websocket;
@property(nonatomic, strong, nullable) NSURLSessionDataTask *sseTask;
@property(nonatomic, strong, nullable) NSURLSession *sseSession;
@property(nonatomic, strong, nullable) dispatch_source_t heartbeat;
@end

@implementation ARTSocketTeardown
@end

@interface Socket () <NSURLSessionWebSocketDelegate, NSURLSessionDataDelegate>

@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *websocket;
/// `connectionGeneration` at the time `websocket` was opened.
@property(nonatomic, assign) NSInteger websocketGeneration;
@property(nonatomic, strong) AuthenticationConfig *credentials;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, BaseSubscription *> *subscriptions;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, Interception *> *interceptors;
@property(nonatomic, strong, nullable) ConnectionDetail *connection;

// Heartbeat
@property(nonatomic, strong, nullable) dispatch_source_t heartbeatSource;

// Pending requests
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, ARTSecureRequest *> *secureRequests;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableArray *> *pendingIncomingMessages;

// Transport selection
@property(nonatomic, copy) NSString *pullSource; // "socket", "sse", "http"
@property(nonatomic, copy) NSString *pushSource; // "socket", "http"
@property(nonatomic, strong) LongPollClient *lpClient;

// Connection flags
@property(nonatomic, assign) BOOL isConnecting;
@property(nonatomic, assign) BOOL autoReconnect;
/// YES once the server has confirmed the connection (`art_ready`); NO while
/// only the long-poll fallback's local connection exists.
@property(nonatomic, assign) BOOL connectionBound;
/// Access token the server currently authorises this connection with.
@property(nonatomic, copy) NSString *authorizedAccessToken;
/// Callers waiting for the authorisation renewal in flight; nil when there
/// is none.
@property(nonatomic, strong, nullable)
    NSMutableArray<ARTSocketCompletion> *authorizationWaiters;
/// Why the connection failed; set until `beginConnection` starts over.
@property(nonatomic, strong, nullable) ARTConnectionError *connectionFailure;
/// Bumped on every new attempt and failure, so callbacks of an older
/// transport are ignored.
@property(nonatomic, assign) NSInteger connectionGeneration;
@property(nonatomic, assign) NSInteger connectionTimeoutMs;

// SSE state
@property(nonatomic, strong, nullable) NSURLSessionDataTask *sseTask;
@property(nonatomic, strong, nullable) NSURLSession *sseSession;
/// `connectionGeneration` at the time `sseTask` was started.
@property(nonatomic, assign) NSInteger sseGeneration;
@property(nonatomic, strong) NSMutableData *sseBuffer;

// URL sessions
@property(nonatomic, strong) NSURLSession *wsSession;

// Event emitter
@property(nonatomic, strong) EventEmitter *emitter;

// Connection waiters
@property(nonatomic, strong)
    NSMutableDictionary<NSUUID *, ARTConnectionWaiter *> *connectionWaiters;
@property(nonatomic, strong) NSRecursiveLock *socketLock;

@end

// Singleton. dispatch_once-based lock init so `_singletonLock` can
// never be nil, even under a race with early-launch code paths.
static Socket *_instance = nil;

static NSLock *SocketSingletonLock(void) {
    static NSLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      lock = [[NSLock alloc] init];
    });
    return lock;
}

@implementation Socket

@synthesize isConnectionActive = _isConnectionActive;
@synthesize isReConnecting = _isReConnecting;

+ (void)reset {
    NSLock *lock = SocketSingletonLock();
    [lock lock];
    _instance = nil;
    [lock unlock];
}

- (instancetype)initWithEncrypt:(EncryptBlock)encrypt
                        decrypt:(DecryptBlock)decrypt {
    self = [super init];
    if (self) {
        _encryptBlock = [encrypt copy];
        _decryptBlock = [decrypt copy];
        _credentials = [[AuthenticationConfig alloc] init];
        _subscriptions = [NSMutableDictionary dictionary];
        _interceptors = [NSMutableDictionary dictionary];
        _secureRequests = [NSMutableDictionary dictionary];
        _pendingIncomingMessages = [NSMutableDictionary dictionary];
        _pullSource = @"socket";
        _pushSource = @"socket";
        _isConnecting = NO;
        _isReConnecting = NO;
        _isConnectionActive = NO;
        _autoReconnect = NO;
        _authorizedAccessToken = @"";
        _connectionTimeoutMs = 30000;
        _emitter = [[EventEmitter alloc] init];
        _connectionWaiters = [NSMutableDictionary dictionary];
        _socketLock = [[NSRecursiveLock alloc] init];
        _sseBuffer = [NSMutableData data];

        // Create the URL session for WebSocket with self as delegate
        NSURLSessionConfiguration *config =
            [NSURLSessionConfiguration defaultSessionConfiguration];
        _wsSession = [NSURLSession sessionWithConfiguration:config
                                                   delegate:self
                                              delegateQueue:nil];

        // Create the LongPollClient
        __weak typeof(self) weakSelf = self;
        LongPollOptions *lpOpts = [[LongPollOptions alloc]
            initWithEndpoint:Constant.LPOLL
            getAuthHeaders:^(void (^authCompletion)(
                NSDictionary<NSString *, NSString *> *_Nullable,
                NSError *_Nullable)) {
              typeof(self) strongSelf = weakSelf;
              if (!strongSelf) {
                  authCompletion(nil, MakeError(ErrorCodeNotConnected,
                                                @"Socket deallocated"));
                  return;
              }
              NSError *authErr = nil;
              Auth *auth = [strongSelf sessionAuth:&authErr];
              if (!auth) {
                  authCompletion(nil, authErr);
                  return;
              }
              [auth
                  authenticate:NO
                    completion:^(AuthData *data, NSError *error) {
                      if (error) {
                          authCompletion(nil, error);
                          return;
                      }
                      AuthenticationConfig *creds = [auth getCredentials];
                      authCompletion(@{
                          @"Authorization" : [NSString
                              stringWithFormat:@"Bearer %@", data.accessToken],
                          @"X-Org" : creds.orgTitle,
                          @"Environment" : creds.environment,
                          @"ProjectKey" : creds.projectKey,
                      },
                                     nil);
                    }];
            }
            onMessages:^(NSArray *messages) {
              [weakSelf processIncomingMessages:messages];
            }];
        lpOpts.onError = ^(NSError *error) {
          // The poll loop stops itself on rejected credentials.
          if (ARTIsTerminalAuthError(error)) {
              [weakSelf stopAfterAuthenticationFailure:error];
          }
        };
        lpOpts.onResponse = ^{
          [weakSelf openLocalFallbackConnection];
        };

        _lpClient = [[LongPollClient alloc] initWithOptions:lpOpts];
    }
    return self;
}

- (void)withSocketLock:(void (^)(void))block {
    [_socketLock lock];
    block();
    [_socketLock unlock];
}

- (BOOL)isConnectionActive {
    [_socketLock lock];
    BOOL value = _isConnectionActive;
    [_socketLock unlock];
    return value;
}

- (void)setIsConnectionActive:(BOOL)isConnectionActive {
    [_socketLock lock];
    _isConnectionActive = isConnectionActive;
    [_socketLock unlock];
}

- (BOOL)isReConnecting {
    [_socketLock lock];
    BOOL value = _isReConnecting;
    [_socketLock unlock];
    return value;
}

- (void)setIsReConnecting:(BOOL)isReConnecting {
    [_socketLock lock];
    _isReConnecting = isReConnecting;
    [_socketLock unlock];
}

+ (Socket *)getInstance:(EncryptBlock)encrypt decrypt:(DecryptBlock)decrypt {
    NSLock *lock = SocketSingletonLock();
    [lock lock];
    if (_instance == nil) {
        _instance = [[Socket alloc] initWithEncrypt:encrypt decrypt:decrypt];
    }
    Socket *result = _instance;
    [lock unlock];
    return result;
}

#pragma mark - Connection lifecycle

- (BOOL)beginConnectionWithTimeoutMs:(NSInteger)timeoutMs error:(NSError **)error {
    if (timeoutMs <= 0) {
        if (error) {
            *error = MakeError(ErrorCodeInvalidArgument,
                               @"connectionTimeoutMs must be positive");
        }
        return NO;
    }
    [self withSocketLock:^{
      self.connectionTimeoutMs = timeoutMs;
      self.connectionFailure = nil;
      self.connectionGeneration += 1;
      // An attempt still in flight belongs to the old generation and will
      // be cancelled; it must not block this one.
      self.isConnecting = NO;
    }];
    return YES;
}

- (void)failConnection:(ARTConnectionError *)error {
    __block ARTSocketTeardown *transport = nil;
    __block NSArray<ARTConnectionWaiter *> *waiters = nil;
    __block NSArray<ARTSecureRequest *> *requests = nil;
    [self withSocketLock:^{
      if (self.connectionFailure) {
          return;
      }
      self.connectionFailure = error;
      self.connectionGeneration += 1;
      self->_isReConnecting = NO;
      self->_autoReconnect = NO;
      self.connection = nil;
      waiters = self.connectionWaiters.allValues;
      requests = self.secureRequests.allValues;
      [self.connectionWaiters removeAllObjects];
      [self.secureRequests removeAllObjects];
      transport = [self takeTransportLocked];
    }];
    if (!transport) {
        return;
    }
    [self stopTransport:transport];
    for (ARTConnectionWaiter *waiter in waiters) {
        dispatch_block_cancel(waiter.timer);
        waiter.completion(error);
    }
    for (ARTSecureRequest *request in requests) {
        dispatch_block_cancel(request.timer);
        request.completion(nil, error);
    }
    [self.emitter emit:@"connectionFailed" data:error];
}

- (NSUUID *)onConnectionFailure:(void (^)(ARTConnectionError *))listener {
    return [self.emitter on:@"connectionFailed"
                    handler:^(id data) {
                      if ([data isKindOfClass:[ARTConnectionError class]]) {
                          listener((ARTConnectionError *)data);
                      }
                    }];
}

- (void)offConnectionFailure:(NSUUID *)identifier {
    [self.emitter off:@"connectionFailed" identifier:identifier];
}

/// Resets the connection flags and detaches the transport. Must be called
/// with the socket lock held; stop the result with `stopTransport:`.
- (ARTSocketTeardown *)takeTransportLocked {
    ARTSocketTeardown *teardown = [[ARTSocketTeardown alloc] init];
    teardown.websocket = self.websocket;
    teardown.sseTask = self.sseTask;
    teardown.sseSession = self.sseSession;
    teardown.heartbeat = self.heartbeatSource;
    self.websocket = nil;
    self.sseTask = nil;
    self.sseSession = nil;
    self.heartbeatSource = nil;
    _isConnectionActive = NO;
    self.isConnecting = NO;
    self.connectionBound = NO;
    return teardown;
}

- (void)stopTransport:(ARTSocketTeardown *)teardown {
    [self.lpClient stop];
    [teardown.sseSession invalidateAndCancel];
    if (teardown.heartbeat) {
        dispatch_source_cancel(teardown.heartbeat);
    }
    [teardown.websocket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                                     reason:nil];
}

/// The error ending an attempt started at `generation`, when a failure or a
/// newer attempt replaced it.
- (nullable NSError *)replacementOf:(NSInteger)generation {
    __block NSError *replacement = nil;
    [self withSocketLock:^{
      if (self.connectionGeneration == generation) {
          return;
      }
      replacement = self.connectionFailure
                        ?: [ARTConnectionError
                               errorWithMessage:@"Connection attempt cancelled."
                                           code:ARTConnectionErrorCodeCancelled];
    }];
    return replacement;
}

/// `error` (or the failure that replaced the attempt) unless the attempt
/// started at `generation` is still current.
- (nullable NSError *)errorIfReplaced:(NSInteger)generation error:(NSError *)error {
    __block NSError *result = nil;
    [self withSocketLock:^{
      if (self.connectionGeneration != generation) {
          result = self.connectionFailure ?: error;
      } else {
          result = self.connectionFailure;
      }
    }];
    return result;
}

#pragma mark - initiateSocket

- (void)initiateSocket:(AuthenticationConfig *)credentials
            completion:(nullable void (^)(NSError *_Nullable))completion {
    __block NSInteger generation = 0;
    __block NSError *failure = nil;
    __block BOOL isOpen = NO;
    [self withSocketLock:^{
      generation = self.connectionGeneration;
      failure = self.connectionFailure;
      isOpen = self.websocket != nil && self->_isConnectionActive;
      if (!failure && !isOpen) {
          self.credentials = credentials;
      }
    }];
    if (failure || isOpen) {
        if (completion) {
            completion(failure);
        }
        return;
    }

    // 1. Try WebSocket
    [self connectWebSocket:^(NSError *_Nullable wsError) {
      if (!wsError) {
          [self withSocketLock:^{
            self.pullSource = @"socket";
            self.pushSource = @"socket";
          }];
          if (completion) {
              completion(nil);
          }
          return;
      }
      // A failure, or a newer attempt, replaced this one: no fallback.
      NSError *replaced = [self errorIfReplaced:generation error:wsError];
      if (replaced) {
          if (completion) {
              completion(replaced);
          }
          return;
      }

      // 2. Try SSE
      [self connectSSE:^(NSError *_Nullable sseError) {
        if (!sseError) {
            [self withSocketLock:^{
              self.pullSource = @"sse";
              self.pushSource = @"http";
            }];
            if (completion) {
                completion(nil);
            }
            return;
        }
        NSError *replacedSSE = [self errorIfReplaced:generation error:sseError];
        if (replacedSSE) {
            if (completion) {
                completion(replacedSSE);
            }
            return;
        }

        // 3. LongPoll. It has no `art_ready` handshake to bind a connection,
        // so a local one is opened once a poll is answered; until then
        // `wait:` keeps waiting, and times out when the server can't be
        // reached.
        __block NSString *connectionId = nil;
        [self withSocketLock:^{
          self.pullSource = @"http";
          self.pushSource = @"http";
          connectionId = self.connection.connectionId;
        }];
        [self.lpClient start:connectionId];
        if (completion) {
            completion(nil);
        }
      }];
    }];
}

#pragma mark - connectWebSocket

- (void)connectWebSocket:(void (^)(NSError *_Nullable))callback {
    void (^completion)(NSError *) = callback ?: ^(NSError *error) {
    };
    __block NSError *failure = nil;
    __block BOOL alreadyConnecting = NO;
    __block NSInteger generation = 0;
    __block AuthenticationConfig *credentials = nil;
    __block BOOL reconnecting = NO;
    [self withSocketLock:^{
      failure = self.connectionFailure;
      if (failure) {
          return;
      }
      if (self.isConnecting) {
          alreadyConnecting = YES;
          return;
      }
      self.isConnecting = YES;
      generation = self.connectionGeneration;
      credentials = self.credentials;
      reconnecting = self->_isReConnecting;
    }];
    if (failure || alreadyConnecting) {
        completion(failure);
        return;
    }

    void (^finish)(void) = ^{
      [self withSocketLock:^{
        if (self.connectionGeneration == generation) {
            self.isConnecting = NO;
        }
      }];
    };

    void (^authFailed)(NSError *) = ^(NSError *error) {
      finish();
      NSError *replaced = [self errorIfReplaced:generation error:error];
      if (replaced) {
          completion(replaced);
          return;
      }
      // Authentication is not a transport outage: rejected credentials, or
      // a forced renewal that fails while reconnecting, end the reconnect
      // cycle instead of retrying forever.
      if (reconnecting || ARTIsTerminalAuthError(error)) {
          completion([self stopAfterAuthenticationFailure:error]);
          return;
      }
      completion(error);
    };

    NSError *authInstanceErr = nil;
    Auth *auth = [Auth getInstance:credentials error:&authInstanceErr];
    if (!auth) {
        authFailed(authInstanceErr);
        return;
    }

    [auth
        authenticate:reconnecting
          completion:^(AuthData *authData, NSError *authError) {
            if (authError) {
                authFailed(authError);
                return;
            }
            NSError *replaced = [self replacementOf:generation];
            if (replaced) {
                finish();
                completion(replaced);
                return;
            }

            __block NSString *connectionId = nil;
            [self withSocketLock:^{
              connectionId = self.connection.connectionId;
            }];

            // Build WebSocket URL
            NSURLComponents *components =
                [NSURLComponents componentsWithString:Constant.WS_URL];
            components.queryItems = @[
                [NSURLQueryItem queryItemWithName:@"connection_id"
                                            value:connectionId ?: @""],
                [NSURLQueryItem queryItemWithName:@"Org-Title"
                                            value:credentials.orgTitle],
                [NSURLQueryItem queryItemWithName:@"token"
                                            value:authData.accessToken],
                [NSURLQueryItem queryItemWithName:@"environment"
                                            value:credentials.environment],
                [NSURLQueryItem queryItemWithName:@"project-key"
                                            value:credentials.projectKey],
            ];

            NSURL *wsURL = components.URL;
            if (!wsURL) {
                finish();
                completion(MakeError(ErrorCodeInvalidPath,
                                     @"Could not build WebSocket URL"));
                return;
            }

            // Close any existing socket
            [self safeClose:^{
              NSError *replacedAfterClose = [self replacementOf:generation];
              if (replacedAfterClose) {
                  finish();
                  completion(replacedAfterClose);
                  return;
              }

              NSURLSessionWebSocketTask *task =
                  [self.wsSession webSocketTaskWithURL:wsURL];
              __block BOOL opened = NO;
              [self withSocketLock:^{
                if (self.connectionGeneration != generation || self.connectionFailure) {
                    return;
                }
                self.websocket = task;
                self.websocketGeneration = generation;
                self.authorizedAccessToken = authData.accessToken;
                self.isConnecting = NO;
                opened = YES;
              }];
              if (!opened) {
                  completion([self replacementOf:generation]
                                 ?: [ARTConnectionError
                                        errorWithMessage:@"Connection attempt cancelled."
                                                    code:ARTConnectionErrorCodeCancelled]);
                  return;
              }
              [task resume];
              [self.emitter emit:@"open" data:[NSNull null]];
              [self startReceiveLoop:task generation:generation];
              completion(nil);
            }];
          }];
}

/// Detaches the current WebSocket first, so its closure is not reported as a
/// dropped connection, then closes it.
- (void)safeClose:(void (^)(void))completion {
    __block NSURLSessionWebSocketTask *task = nil;
    [self withSocketLock:^{
      task = self.websocket;
      self.websocket = nil;
    }];
    [self close:task completion:completion];
}

- (void)close:(nullable NSURLSessionWebSocketTask *)task
    completion:(void (^)(void))completion {
    if (!task || task.state == NSURLSessionTaskStateCompleted) {
        completion();
        return;
    }
    [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                       reason:nil];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          completion();
        });
}

#pragma mark - connectSSE

- (void)connectSSE:(void (^)(NSError *_Nullable))completion {
    __block NSInteger generation = 0;
    __block AuthenticationConfig *credentials = nil;
    [self withSocketLock:^{
      generation = self.connectionGeneration;
      credentials = self.credentials;
    }];

    void (^authFailed)(NSError *) = ^(NSError *error) {
      NSError *replaced = [self errorIfReplaced:generation error:error];
      if (replaced) {
          completion(replaced);
          return;
      }
      if (ARTIsTerminalAuthError(error)) {
          completion([self stopAfterAuthenticationFailure:error]);
          return;
      }
      completion(error);
    };

    NSError *authInstanceErr = nil;
    Auth *auth = [Auth getInstance:credentials error:&authInstanceErr];
    if (!auth) {
        authFailed(authInstanceErr);
        return;
    }

    [auth
        authenticate:NO
          completion:^(AuthData *authData, NSError *authError) {
            if (authError) {
                authFailed(authError);
                return;
            }
            NSError *replaced = [self replacementOf:generation];
            if (replaced) {
                completion(replaced);
                return;
            }

            NSURLComponents *components =
                [NSURLComponents componentsWithString:Constant.SSE_URL];
            components.queryItems = @[
                [NSURLQueryItem queryItemWithName:@"Org-Title"
                                            value:credentials.orgTitle],
                [NSURLQueryItem queryItemWithName:@"token"
                                            value:authData.accessToken],
                [NSURLQueryItem queryItemWithName:@"environment"
                                            value:credentials.environment],
                [NSURLQueryItem queryItemWithName:@"project-key"
                                            value:credentials.projectKey],
            ];

            NSURL *sseURL = components.URL;
            if (!sseURL) {
                completion(MakeError(ErrorCodeInvalidPath, @"Bad SSE URL"));
                return;
            }

            NSMutableURLRequest *req =
                [NSMutableURLRequest requestWithURL:sseURL];
            [req setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];

            // A dedicated session for SSE streaming. It keeps its delegate
            // alive until it is invalidated in `stopTransport:`.
            NSURLSession *session = [NSURLSession
                sessionWithConfiguration:[NSURLSessionConfiguration
                                             defaultSessionConfiguration]
                                delegate:self
                           delegateQueue:nil];
            NSURLSessionDataTask *task = [session dataTaskWithRequest:req];
            __block NSURLSession *previous = nil;
            [self withSocketLock:^{
              previous = self.sseSession;
              self.sseSession = session;
              self.sseTask = task;
              self.sseGeneration = generation;
              self.sseBuffer = [NSMutableData data];
            }];
            [previous invalidateAndCancel];
            [task resume];
            completion(nil);
          }];
}

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                                  ? (NSHTTPURLResponse *)response
                                  : nil;
    if (http.statusCode != 200 || ![self isLiveSSETask:dataTask]) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    [self.emitter emit:@"open" data:[NSNull null]];
    completionHandler(NSURLSessionResponseAllow);
}

- (BOOL)isLiveSSETask:(NSURLSessionTask *)task {
    __block BOOL live = NO;
    [self withSocketLock:^{
      live = task == self.sseTask && self.sseGeneration == self.connectionGeneration;
    }];
    return live;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {

    if (![self isLiveSSETask:dataTask])
        return;

    __block NSArray<NSString *> *lines = nil;
    [self withSocketLock:^{
      [self.sseBuffer appendData:data];

      // Process complete lines from buffer
      NSString *bufferStr = [[NSString alloc] initWithData:self.sseBuffer
                                                  encoding:NSUTF8StringEncoding];
      if (!bufferStr)
          return;

      lines = [bufferStr componentsSeparatedByString:@"\n"];

      // Keep the last incomplete line in buffer
      NSData *remainingData = [lines.lastObject dataUsingEncoding:NSUTF8StringEncoding];
      self.sseBuffer =
          remainingData ? [remainingData mutableCopy] : [NSMutableData data];
    }];

    for (NSUInteger i = 0; i + 1 < lines.count; i++) {
        NSString *line =
            [lines[i] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if ([line hasPrefix:@"data:"]) {
            NSString *payload = [[line substringFromIndex:5]
                stringByTrimmingCharactersInSet:[NSCharacterSet
                                                    whitespaceCharacterSet]];
            [self parseIncomingMessage:payload];
        }
    }
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(nullable NSError *)error {
    __block BOOL wasActive = NO;
    [self withSocketLock:^{
      if (task != self.sseTask) {
          return;
      }
      BOOL live = self.sseGeneration == self.connectionGeneration;
      self.sseTask = nil;
      if (live && self->_isConnectionActive && !self.websocket) {
          wasActive = YES;
          self->_isConnectionActive = NO;
          self.connectionBound = NO;
      }
    }];
    // A live stream that ends is a dropped connection, like a closed socket.
    if (wasActive) {
        [self.emitter emit:@"close" data:error ?: [NSNull null]];
    }
}

#pragma mark - Local fallback connection (long-poll bootstrap)

/// Synthesizes a local `ConnectionDetail` once the long-poll transport gets
/// an answer, since there is no WebSocket `art_ready` handshake to bind a
/// connection. Without this, `wait:` never resolves once the transport falls
/// back to polling.
///
/// A no-op once a real (or prior local) connection is active. If a later
/// `art_ready` arrives, `handleConnectionBinding:` upgrades the connection
/// to the server-issued id.
- (void)openLocalFallbackConnection {
    __block ConnectionDetail *local = nil;
    [self withSocketLock:^{
      if (self.connectionFailure ||
          (self->_isConnectionActive && self.connection != nil)) {
          return;
      }
      long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
      local = [[ConnectionDetail alloc]
          initWithConnectionId:[NSString stringWithFormat:@"local_%lld", now]
                    instanceId:@"instance_local"
                    tenantName:self.credentials.orgTitle
                   environment:self.credentials.environment
                    projectKey:self.credentials.projectKey];
      self.connection = local;
      self.connectionBound = NO;
      self->_isConnectionActive = YES;
    }];
    if (!local) {
        return;
    }
    [self.emitter emit:@"connection" data:local];
    [self resolveWaiters];
    [self startHeartbeat];
}

#pragma mark - Connection binding (art_ready / ready)

- (void)handleConnectionBinding:(NSString *)rawData {
    NSData *jsonData = [rawData dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData)
        return;
    NSDictionary *data = [NSJSONSerialization JSONObjectWithData:jsonData
                                                         options:0
                                                           error:nil];
    if (![data isKindOfClass:[NSDictionary class]])
        return;

    __block ConnectionDetail *detail = nil;
    __block NSArray<BaseSubscription *> *subs = nil;
    __block NSArray<Interception *> *intercepts = nil;
    [self withSocketLock:^{
      if (self.connectionFailure) {
          return;
      }
      self->_autoReconnect = YES;
      id connectionId = data[@"connection_id"];
      id instanceId = data[@"instance_id"];
      detail = [[ConnectionDetail alloc]
          initWithConnectionId:[connectionId isKindOfClass:[NSString class]]
                                   ? connectionId
                                   : @""
                    instanceId:[instanceId isKindOfClass:[NSString class]]
                                   ? instanceId
                                   : @""
                    tenantName:self.credentials.orgTitle
                   environment:self.credentials.environment
                    projectKey:self.credentials.projectKey];
      self.connection = detail;
      self->_isConnectionActive = YES;
      self.connectionBound = YES;
      self->_isReConnecting = NO;
      subs = self.subscriptions.allValues;
      intercepts = self.interceptors.allValues;
    }];
    if (!detail) {
        return;
    }

    [self.emitter emit:@"connection" data:detail];
    [self resolveWaiters];
    [self startHeartbeat];

    for (BaseSubscription *sub in subs) {
        [sub reconnect];
    }
    for (Interception *interception in intercepts) {
        [interception reconnect];
    }
}

#pragma mark - WebsocketHandler: pushForSecureLine

- (void)pushForSecureLine:(NSString *)event
                     data:(id)data
                   listen:(BOOL)listen
               completion:
                   (void (^)(id _Nullable, NSError *_Nullable))completion {
    [self wait:^(NSError *_Nullable waitError) {
      if (waitError) {
          if (completion) {
              completion(nil, waitError);
          }
          return;
      }

      __block NSString *connId = nil;
      __block NSInteger timeoutMs = 0;
      [self withSocketLock:^{
        connId = self.connection.connectionId ?: @"";
        timeoutMs = self.connectionTimeoutMs;
      }];
      NSString *rand = [NSString stringWithFormat:@"%x", arc4random()];
      NSTimeInterval ts = [[NSDate date] timeIntervalSince1970] * 1000.0;
      NSString *refId = [NSString
          stringWithFormat:@"%@_secure_%lld_%@", connId, (long long)ts, rand];

      NSError *jsonError = nil;
      NSString *content = [ARTJSON stringify:data ?: @{} error:&jsonError];
      NSString *msgStr =
          content ? [ARTJSON stringify:@{
              @"from" : connId,
              @"channel" : @"art_secure",
              @"event" : event,
              @"content" : content,
              @"ref_id" : refId
          }
                                 error:&jsonError]
                  : nil;
      if (!msgStr) {
          if (completion) {
              completion(nil, jsonError);
          }
          return;
      }

      if (!listen) {
          NSError *sendError = nil;
          BOOL sent = [self sendOrFail:msgStr error:&sendError];
          if (completion) {
              completion(nil, sent ? nil : sendError);
          }
          return;
      }

      NSString *key = [NSString stringWithFormat:@"secure-%@", refId];
      __weak typeof(self) weakSelf = self;
      dispatch_block_t timer = dispatch_block_create(0, ^{
        [weakSelf completeSecureRequest:key
                                 result:nil
                                  error:[ARTConnectionError
                                            errorWithMessage:@"The connection did not "
                                                             @"respond in time. Please "
                                                             @"reconnect and try again."
                                                        code:ARTConnectionErrorCodeTimeout]];
      });
      ARTSecureRequest *request = [[ARTSecureRequest alloc] init];
      request.completion = completion ?: ^(id result, NSError *error) {
      };
      request.timer = timer;

      // Registered before sending so a fast reply can't be missed.
      __block NSError *failure = nil;
      [self withSocketLock:^{
        failure = self.connectionFailure;
        if (!failure) {
            self.secureRequests[key] = request;
        }
      }];
      if (failure) {
          request.completion(nil, failure);
          return;
      }
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutMs * NSEC_PER_MSEC)),
          dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), timer);

      NSError *sendError = nil;
      if (![self sendOrFail:msgStr error:&sendError]) {
          [self completeSecureRequest:key result:nil error:sendError];
      }
    }];
}

- (void)completeSecureRequest:(NSString *)key
                       result:(nullable id)result
                        error:(nullable NSError *)error {
    __block ARTSecureRequest *request = nil;
    [self withSocketLock:^{
      request = self.secureRequests[key];
      [self.secureRequests removeObjectForKey:key];
    }];
    if (!request) {
        return;
    }
    dispatch_block_cancel(request.timer);
    request.completion(result, error);
}

/// Sends `message`; a failed send ends the connection.
- (BOOL)sendOrFail:(NSString *)message error:(NSError **)error {
    NSError *sendError = nil;
    if ([self sendMessage:message error:&sendError]) {
        return YES;
    }
    [self failConnection:[sendError isKindOfClass:[ARTConnectionError class]]
                             ? (ARTConnectionError *)sendError
                             : [ARTConnectionError
                                   errorWithMessage:@"The connection was lost."
                                               code:ARTConnectionErrorCodeLost]];
    if (error) {
        *error = sendError;
    }
    return NO;
}

#pragma mark - WebsocketHandler: ensureAuthorization

- (void)ensureAuthorization:(void (^)(NSError *_Nullable))completion {
    [self wait:^(NSError *_Nullable waitError) {
      if (waitError) {
          completion(waitError);
          return;
      }

      // Before the server confirms the connection there is nothing to renew:
      // the socket was just opened with the current token. The first call
      // after `art_ready` renews the authorisation if the token changed
      // since.
      __block BOOL bound = NO;
      __block BOOL joined = NO;
      [self withSocketLock:^{
        bound = self.connectionBound;
        if (bound && self.authorizationWaiters) {
            [self.authorizationWaiters addObject:[completion copy]];
            joined = YES;
        }
      }];
      if (!bound) {
          completion(nil);
          return;
      }
      if (joined) {
          return;
      }

      NSError *authInstanceErr = nil;
      Auth *auth = [self sessionAuth:&authInstanceErr];
      if (!auth) {
          completion([self stopAfterAuthenticationFailure:authInstanceErr]);
          return;
      }

      [auth authenticate:NO
              completion:^(AuthData *authData, NSError *authError) {
                if (authError) {
                    completion([self stopAfterAuthenticationFailure:authError]);
                    return;
                }
                NSString *accessToken = authData.accessToken;
                __block NSError *failure = nil;
                __block BOOL current = NO;
                __block BOOL joinedRenewal = NO;
                [self withSocketLock:^{
                  failure = self.connectionFailure;
                  if (failure) {
                      return;
                  }
                  current = [accessToken isEqualToString:self.authorizedAccessToken];
                  if (current) {
                      return;
                  }
                  if (self.authorizationWaiters) {
                      joinedRenewal = YES;
                      [self.authorizationWaiters addObject:[completion copy]];
                  } else {
                      self.authorizationWaiters =
                          [NSMutableArray arrayWithObject:[completion copy]];
                  }
                }];
                if (failure || current) {
                    completion(failure);
                    return;
                }
                if (joinedRenewal) {
                    return;
                }
                [self refreshAuthorizationLease:accessToken
                                    credentials:[auth getCredentials]
                                     completion:^(NSError *leaseError) {
                                       __block NSArray<ARTSocketCompletion> *waiters = nil;
                                       [self withSocketLock:^{
                                         waiters = [self.authorizationWaiters copy];
                                         self.authorizationWaiters = nil;
                                       }];
                                       for (ARTSocketCompletion waiter in waiters) {
                                           waiter(leaseError);
                                       }
                                     }];
              }];
    }];
}

/// Tells the server to authorise this connection with `accessToken`.
- (void)refreshAuthorizationLease:(NSString *)accessToken
                      credentials:(AuthenticationConfig *)creds
                       completion:(void (^)(NSError *_Nullable))completion {
    __block NSString *connectionId = nil;
    __block NSInteger timeoutMs = 0;
    [self withSocketLock:^{
      connectionId = self.connection.connectionId;
      timeoutMs = self.connectionTimeoutMs;
    }];
    if (connectionId.length == 0) {
        completion(MakeError(ErrorCodeNotConnected, @"Not connected"));
        return;
    }
    NSURL *url = [NSURL
        URLWithString:[NSString stringWithFormat:@"%@/v1/push-message", Constant.BASE_URL]];
    if (!url) {
        completion(MakeError(ErrorCodeInvalidPath, @"Malformed authorization URL"));
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[NSString stringWithFormat:@"Bearer %@", accessToken]
        forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:creds.orgTitle forHTTPHeaderField:@"X-Org"];
    [request setValue:creds.environment forHTTPHeaderField:@"Environment"];
    [request setValue:creds.projectKey forHTTPHeaderField:@"ProjectKey"];
    request.HTTPBody = [[ARTJSON stringify:@{
        @"channel" : @"art_secure",
        @"event" : @"authorization-refresh",
        @"content" : @"{}",
        @"connection_id" : connectionId,
        @"to" : @[],
    }
                                     error:nil]
        dataUsingEncoding:NSUTF8StringEncoding];

    [ARTHTTPClient
        sendRequest:request
          timeoutMs:timeoutMs
       timeoutError:^NSError * {
         return [ARTConnectionError
             errorWithMessage:@"Connection authorization timed out. Please reconnect."
                         code:ARTConnectionErrorCodeAuthorizationFailed];
       }
         completion:^(NSData *data, NSURLResponse *response, NSError *error) {
           if ([error isKindOfClass:[ARTConnectionError class]]) {
               completion(error);
               return;
           }
           if (error) {
               completion([ARTConnectionError
                   errorWithMessage:[NSString
                                        stringWithFormat:@"Connection authorization failed: %@",
                                                         error.localizedDescription]
                               code:ARTConnectionErrorCodeAuthorizationFailed]);
               return;
           }

           NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                                         ? (NSHTTPURLResponse *)response
                                         : nil;
           if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
               id body = [ARTJSON parseData:data];
               id message = [body isKindOfClass:[NSDictionary class]]
                                ? ((NSDictionary *)body)[@"message"]
                                : nil;
               NSString *text =
                   ([message isKindOfClass:[NSString class]] && [message length] > 0)
                       ? message
                       : [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
               ARTAuthHttpError *rejection =
                   [ARTAuthHttpError errorWithMessage:text
                                               status:http.statusCode
                                                 body:body];
               if (rejection.isTerminal) {
                   [self stopAfterAuthenticationFailure:rejection];
               }
               completion(rejection);
               return;
           }
           [self withSocketLock:^{
             self.authorizedAccessToken = accessToken;
           }];
           completion(nil);
         }];
}

/// Stops the connection after the credentials were rejected or could not be
/// renewed: fails it with `AUTHENTICATION_FAILED` and emits
/// `authenticationFailed`. Returns the `ARTConnectionError` to report.
- (ARTConnectionError *)stopAfterAuthenticationFailure:(NSError *)error {
    BOOL knownMessage = [error isKindOfClass:[ARTConnectionError class]] ||
                        [error isKindOfClass:[ARTAuthHttpError class]] ||
                        [error.domain isEqualToString:ErrorDomain];
    NSNumber *status = nil;
    NSInteger rejectedStatus = 0;
    if ([error isKindOfClass:[ARTAuthHttpError class]]) {
        ARTAuthHttpError *rejection = (ARTAuthHttpError *)error;
        status = @(rejection.status);
        rejectedStatus = rejection.isTerminal ? rejection.status : 0;
    }
    ARTConnectionError *failure = [ARTConnectionError
        errorWithMessage:knownMessage ? error.localizedDescription
                                      : @"Authentication failed. Please sign in again."
                    code:ARTConnectionErrorCodeAuthenticationFailed
                  status:status];
    [self failConnection:failure];
    [self.emitter emit:@"authenticationFailed"
                  data:[[ARTAuthenticationFailedDetail alloc]
                           initWithStatus:rejectedStatus
                                    error:error.localizedDescription ?: @""]];
    __block ARTConnectionError *current = nil;
    [self withSocketLock:^{
      current = self.connectionFailure;
    }];
    return current ?: failure;
}

/// The token manager of the running session, recreated from the socket's
/// credentials if the app reset it.
- (nullable Auth *)sessionAuth:(NSError **)error {
    Auth *auth = [Auth getInstance:nil error:nil];
    if (auth) {
        return auth;
    }
    __block AuthenticationConfig *credentials = nil;
    [self withSocketLock:^{
      credentials = self.credentials;
    }];
    return [Auth getInstance:credentials error:error];
}

- (void)removeSubscription:(NSString *)channel {
    [self withSocketLock:^{
      [self.subscriptions removeObjectForKey:channel];
    }];
}

#pragma mark - Subscribe

- (void)subscribe:(NSString *)channel
       completion:(void (^)(BaseSubscription *_Nullable,
                            NSError *_Nullable))completion {
    [self handleSubscription:channel completion:completion];
}

- (void)handleSubscription:(NSString *)channel
                completion:(void (^)(BaseSubscription *_Nullable,
                                     NSError *_Nullable))completion {

    [self ensureAuthorization:^(NSError *_Nullable authorizationError) {
      if (authorizationError) {
          completion(nil, authorizationError);
          return;
      }

      // Check for existing subscription
      __block NSString *connectionId = nil;
      __block BaseSubscription *existing = nil;
      [self withSocketLock:^{
        connectionId = self.connection.connectionId ?: @"";
        existing = self.subscriptions[channel];
      }];

      if (existing) {
          [existing subscribe:^(NSError *_Nullable subscribeError) {
            completion(subscribeError ? nil : existing, subscribeError);
          }];
          return;
      }

      // Validate and create subscription
      [self
          validateSubscription:channel
                       process:@"subscribe"
                    completion:^(ChannelConfig *config, NSError *valError) {
                      if (valError) {
                          completion(nil, valError);
                          return;
                      }
                      if (!config) {
                          completion(nil, MakeError(ErrorCodeChannelNotFound,
                                                    channel));
                          return;
                      }

                      BaseSubscription *subscription;
                      if ([config.channelType
                              isEqualToString:@"shared-object"]) {
                          subscription = [[LiveObjSubscription alloc]
                              initWithConnectionID:connectionId
                                     channelConfig:config
                                  websocketHandler:self
                                           process:@"subscribe"];
                      } else {
                          subscription = [[Subscription alloc]
                              initWithConnectionID:connectionId
                                     channelConfig:config
                                  websocketHandler:self
                                           process:@"subscribe"];
                      }

                      // Register the subscription and queue the frames that
                      // arrived before it, under the lock, so they stay ahead
                      // of any frame received meanwhile.
                      [self withSocketLock:^{
                        self.subscriptions[channel] = subscription;
                        NSArray *buffered = self.pendingIncomingMessages[channel];
                        [self.pendingIncomingMessages removeObjectForKey:channel];
                        for (NSDictionary *item in buffered) {
                            [subscription
                                enqueueEvent:item[@"event"] ?: @""
                                     payload:item[@"payload"] ?: @{}];
                        }
                      }];

                      completion(subscription, nil);
                    }];
    }];
}

- (void)validateSubscription:(NSString *)channelName
                     process:(NSString *)process
                  completion:(void (^)(ChannelConfig *_Nullable,
                                       NSError *_Nullable))completion {
    if ([channelName isEqualToString:@"art_config"] ||
        [channelName isEqualToString:@"art_secure"]) {
        ChannelConfig *config =
            [[ChannelConfig alloc] initWithChannelName:channelName
                                      channelNamespace:@""
                                           channelType:@"default"
                                         presenceUsers:@[]
                                              snapshot:nil
                                        subscriptionID:@""];
        completion(config, nil);
        return;
    }

   [HelperFunctions subscribeToChannel:channelName
                               process:process
                      websocketHandler:self
                            completion:completion];
}

- (nullable ConnectionDetail *)getConnection {
    __block ConnectionDetail *connection = nil;
    [self withSocketLock:^{
      connection = self.connection;
    }];
    return connection;
}

- (void)intercept:(NSString *)interceptor
               fn:(void (^)(NSDictionary *, void (^)(id),
                            void (^)(NSString *)))fn
       completion:
           (void (^)(Interception *_Nullable, NSError *_Nullable))completion {

    [self wait:^(NSError *_Nullable waitError) {
      if (waitError) {
          completion(nil, waitError);
          return;
      }

      // Check existing
      __block Interception *existing = nil;
      [self withSocketLock:^{
        existing = self.interceptors[interceptor];
      }];

      if (existing) {
          completion(existing, nil);
          return;
      }

      Interception *interception =
          [[Interception alloc] initWithInterceptor:interceptor
                                                 fn:fn
                                   websocketHandler:self];
      [interception validateInterception:^(NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        [self withSocketLock:^{
          self.interceptors[interceptor] = interception;
        }];

        completion(interception, nil);
      }];
    }];
}

#pragma mark - Message parsing

- (void)parseIncomingMessage:(NSString *)message {
    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
    if (!data)
        return;

    id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:nil];
    if (!parsed)
        return;

    if ([parsed isKindOfClass:[NSArray class]]) {
        [self processIncomingMessages:(NSArray *)parsed];
    } else if ([parsed isKindOfClass:[NSDictionary class]]) {
        [self handleIncomingMessage:(NSDictionary *)parsed];
    }
}

- (void)processIncomingMessages:(NSArray *)messages {
    for (id msg in messages) {
        if ([msg isKindOfClass:[NSDictionary class]]) {
            [self handleIncomingMessage:(NSDictionary *)msg];
        }
    }
}

- (void)handleIncomingMessage:(NSDictionary *)parsed {
    // A channel-less frame is normally dropped by the empty-channel check
    // below; the limit block there must inspect it first for a billing /
    // concurrency rejection, so coerce a missing/non-string channel to "".
    id rawChannel = parsed[@"channel"];
    NSString *channel = [rawChannel isKindOfClass:[NSString class]]
                            ? (NSString *)rawChannel
                            : @"";

    // Fields that aren't strings (e.g. JSON null) count as empty.
    NSString * (^stringField)(NSString *) = ^NSString *(NSString *key) {
      id value = parsed[key];
      return [value isKindOfClass:[NSString class]] ? (NSString *)value : @"";
    };
    NSString *event = stringField(@"event");
    NSString *refId = stringField(@"ref_id");
    NSString *returnFlag = stringField(@"return_flag");
    NSString *interceptorName = stringField(@"interceptor_name");
    NSString *namespace_ = stringField(@"namespace");
    id rawData = parsed[@"content"];

    if ([channel isEqualToString:@"art_ready"] &&
        [event isEqualToString:@"ready"]) {
        NSString *rawStr = [rawData isKindOfClass:[NSString class]]
                               ? (NSString *)rawData
                               : @"";
        [self handleConnectionBinding:rawStr];
        return;
    }

    // art_secure → reply to a control request
    if ([channel isEqualToString:@"art_secure"]) {
        id inner = nil;
        if ([rawData isKindOfClass:[NSDictionary class]]) {
            inner = rawData;
        } else if ([rawData isKindOfClass:[NSString class]]) {
            id parsedInner = [ARTJSON parse:(NSString *)rawData];
            inner = [parsedInner isKindOfClass:[NSDictionary class]] ? parsedInner : nil;
        }
        [self completeSecureRequest:[NSString stringWithFormat:@"secure-%@", refId]
                             result:@{
                                 @"data" : inner ?: [NSNull null],
                                 @"channel" : channel,
                                 @"namespace" : namespace_,
                                 @"ref_id" : refId,
                                 @"event" : event
                             }
                              error:nil];
        return;
    }

    // Drop only frames without a channel. Agentic replies (orchestrator and
    // agent) carry their type inside `content` (e.g.
    // `agent_general_response`, `human_input_request`) and can leave the
    // wire-level `event` empty, yet they must still reach the thread's
    // "<threadId>-all" listener. Dropping on an empty `event` would make the
    // orchestrator "connect, but never reply".
    if (channel.length == 0) {
        // Limit block — a billing / concurrency-limit rejection arrives with no
        // channel, carrying only `code` + `error`. Surface it as `limitExceeded`
        // and end the connection, so the Adk layer stops reconnecting and active
        // runs end, then drop the frame.
        id codeVal = parsed[@"code"];
        NSString *code = [codeVal isKindOfClass:[NSString class]]
                             ? (NSString *)codeVal
                             : @"";
        if ([code isEqualToString:@"CONNECTION_MINUTES_LIMIT_EXCEEDED"] ||
            [code isEqualToString:@"CONCURRENT_LIMIT_EXCEEDED"]) {
            id errVal = parsed[@"error"];
            NSString *errText = [errVal isKindOfClass:[NSString class]]
                                    ? (NSString *)errVal
                                    : @"";
            NSString *label =
                [code isEqualToString:@"CONCURRENT_LIMIT_EXCEEDED"]
                    ? @"Concurrent connection limit reached"
                    : @"Connection minutes limit exceeded";
            ARTLogError(@"[ART] %@. Reconnection blocked.", label);
            [self.emitter emit:@"limitExceeded"
                          data:@{@"code" : code, @"error" : errText}];
            [self failConnection:[ARTConnectionError
                                     errorWithMessage:errText.length > 0
                                                          ? errText
                                                          : @"Your connection limit "
                                                            @"has been reached."
                                                 code:code]];
        }
        return;
    }

    // shift_to_http
    if ([event isEqualToString:@"shift_to_http"]) {
        [self switchToHttpPoll];
        return;
    }

    // Build payload with data field
    NSMutableDictionary *payload = [parsed mutableCopy];
    [payload removeObjectForKey:@"content"];
    payload[@"data"] = rawData;

    if ([event isEqualToString:@"error"]) {
        ARTLogError(@"Received error message: %@", parsed);
    }

    // Interceptor routing
    if ([interceptorName isKindOfClass:[NSString class]] &&
        interceptorName.length > 0) {
        __block Interception *interception = nil;
        [self withSocketLock:^{
          interception = self.interceptors[interceptorName];
        }];

        if (interception) {
            [interception handleMessage:channel data:payload];
        } else {
            ARTLogWarn(@"No Interception found for channel: %@", channel);
        }
        return;
    }

    // Subscription routing. Each subscription handles its frames in arrival
    // order; frames for a channel that isn't subscribed yet are kept until
    // it is (bare server acknowledgements are dropped).
    NSString *subKey = channel;
    if (namespace_.length > 0) {
        subKey = [NSString stringWithFormat:@"%@:%@", channel, namespace_];
    }

    [self withSocketLock:^{
      BaseSubscription *sub = self.subscriptions[subKey];
      if (sub) {
          [sub enqueueEvent:event payload:payload];
      } else if (![returnFlag isEqualToString:@"SA"]) {
          NSMutableArray *buffer = self.pendingIncomingMessages[subKey];
          if (!buffer) {
              buffer = [NSMutableArray array];
              self.pendingIncomingMessages[subKey] = buffer;
          }
          [buffer addObject:@{@"event" : event, @"payload" : payload}];
      }
    }];
}

- (void)switchToHttpPoll {
    __block BOOL shouldStart = NO;
    __block NSString *connectionId = nil;
    [self withSocketLock:^{
      if ([self.pullSource isEqualToString:@"http"]) {
          return;
      }
      self.pullSource = @"http";
      self.pushSource = @"http";
      connectionId = self.connection.connectionId;
      shouldStart = YES;
    }];
    if (shouldStart) {
        [self.lpClient start:connectionId ?: @""];
    }
}

#pragma mark - WebsocketHandler: sendMessage

- (BOOL)sendMessage:(NSString *)message error:(NSError **)error {
    __block NSError *failure = nil;
    __block NSURLSessionWebSocketTask *task = nil;
    [self withSocketLock:^{
      failure = self.connectionFailure;
      task = self.websocket;
    }];
    if (failure) {
        if (error) {
            *error = failure;
        }
        return NO;
    }
    // Never queue a message for silent replay after a reconnect: it may
    // start an execution twice.
    if (!task || task.state != NSURLSessionTaskStateRunning) {
        if (error) {
            *error = [ARTConnectionError
                errorWithMessage:@"The connection was lost before the message "
                                 @"could be sent. Please reconnect."
                            code:ARTConnectionErrorCodeLost];
        }
        return NO;
    }

    NSURLSessionWebSocketMessage *wsMessage =
        [[NSURLSessionWebSocketMessage alloc] initWithString:message];
    __weak typeof(self) weakSelf = self;
    [task sendMessage:wsMessage
        completionHandler:^(NSError *_Nullable sendError) {
          if (sendError) {
              [weakSelf.emitter emit:@"error" data:sendError];
          }
        }];
    return YES;
}

- (void)setAutoReconnect:(BOOL)flag {
    [_socketLock lock];
    _autoReconnect = flag;
    [_socketLock unlock];
}

#pragma mark - closeWebSocket

- (void)closeWebSocket:(BOOL)clearConnection
            completion:(nullable void (^)(void))completion {
    __block ARTSocketTeardown *teardown = nil;
    [self withSocketLock:^{
      self.connection = nil;
      if (clearConnection) {
          [self.pendingIncomingMessages removeAllObjects];
          [self.subscriptions removeAllObjects];
          [self.interceptors removeAllObjects];
      }
      teardown = [self takeTransportLocked];
    }];
    NSURLSessionWebSocketTask *websocket = teardown.websocket;
    teardown.websocket = nil;
    [self stopTransport:teardown];
    [self close:websocket
        completion:^{
          if (completion) {
              completion();
          }
        }];
}

#pragma mark - WebsocketHandler: wait

- (void)wait:(void (^)(NSError *_Nullable))completion {
    NSUUID *identifier = [NSUUID UUID];
    __weak typeof(self) weakSelf = self;
    __block NSInteger generation = 0;
    __block NSInteger timeoutMs = 0;
    dispatch_block_t timer = dispatch_block_create(0, ^{
      [weakSelf waitTimedOut:identifier generation:generation];
    });

    __block NSError *failure = nil;
    __block BOOL active = NO;
    [self withSocketLock:^{
      failure = self.connectionFailure;
      active = self->_isConnectionActive;
      if (failure || active) {
          return;
      }
      ARTConnectionWaiter *waiter = [[ARTConnectionWaiter alloc] init];
      waiter.completion = completion;
      waiter.timer = timer;
      self.connectionWaiters[identifier] = waiter;
      generation = self.connectionGeneration;
      timeoutMs = self.connectionTimeoutMs;
    }];
    if (failure || active) {
        completion(failure);
        return;
    }
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutMs * NSEC_PER_MSEC)),
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), timer);
}

- (void)waitTimedOut:(NSUUID *)identifier generation:(NSInteger)generation {
    ARTConnectionError *error = [ARTConnectionError
        errorWithMessage:@"Unable to establish a connection. Please check your "
                         @"connection and try again."
                    code:ARTConnectionErrorCodeTimeout];
    __block BOOL current = NO;
    __block ARTConnectionWaiter *waiter = nil;
    [self withSocketLock:^{
      current = self.connectionGeneration == generation;
      if (!current) {
          // A newer attempt started meanwhile: give up on this wait only.
          waiter = self.connectionWaiters[identifier];
          [self.connectionWaiters removeObjectForKey:identifier];
      }
    }];
    if (current) {
        [self failConnection:error];
    } else if (waiter) {
        waiter.completion(error);
    }
}

- (NSDictionary *)runHeartbeatPayload {
    // Copy under the socket lock, read subscription state outside it (lock
    // order is subscription → socket, never the reverse).
    __block NSDictionary<NSString *, BaseSubscription *> *snapshot = nil;
    __block NSString *connectionId = nil;
    [self withSocketLock:^{
      snapshot = [self.subscriptions copy];
      connectionId = self.connection.connectionId;
    }];

    NSMutableArray *subsInfo = [NSMutableArray array];
    [snapshot enumerateKeysAndObjectsUsingBlock:^(
                  NSString *key, BaseSubscription *sub, BOOL *stop) {
      [subsInfo addObject:@{
          @"name" : key,
          @"presenceTracking" : @(sub.isListening)
      }];
    }];

    return @{
        @"connectionId" : connectionId ?: [NSNull null],
        @"timestamp" : @([[NSDate date] timeIntervalSince1970] * 1000.0),
        @"subscriptions" : subsInfo
    };
}

- (void)startHeartbeat {
    __block BOOL running = NO;
    [self withSocketLock:^{
      running = self.heartbeatSource != nil;
    }];
    if (running)
        return;

    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    dispatch_source_set_timer(
        timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
        (uint64_t)(30.0 * NSEC_PER_SEC), (uint64_t)(1.0 * NSEC_PER_SEC));

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf || !strongSelf.isConnectionActive)
          return;

      // A failed heartbeat surfaces through `connectionFailed`.
      NSDictionary *payload = [strongSelf runHeartbeatPayload];
      [strongSelf
          pushForSecureLine:@"heartbeat"
                       data:payload
                     listen:NO
                 completion:^(id _Nullable result, NSError *_Nullable error){
                 }];
    });

    __block BOOL installed = NO;
    [self withSocketLock:^{
      if (!self.heartbeatSource) {
          self.heartbeatSource = timer;
          installed = YES;
      }
    }];
    if (installed) {
        dispatch_resume(timer);
    } else {
        // A timer must be resumed before it can be cancelled and released.
        dispatch_resume(timer);
        dispatch_source_cancel(timer);
    }
}

- (void)resolveWaiters {
    __block NSArray<ARTConnectionWaiter *> *waiters = nil;
    [self withSocketLock:^{
      waiters = self.connectionWaiters.allValues;
      [self.connectionWaiters removeAllObjects];
    }];

    for (ARTConnectionWaiter *waiter in waiters) {
        dispatch_block_cancel(waiter.timer);
        waiter.completion(nil);
    }
}

- (void)encryptData:(NSString *)data
    recipientPublicKey:(NSString *)key
            completion:
                (void (^)(NSString *_Nullable, NSError *_Nullable))completion {
    if (self.encryptBlock) {
        self.encryptBlock(data, key, completion);
    } else {
        completion(
            nil, MakeError(ErrorCodeEncryptionError, @"Encrypt block not set"));
    }
}

- (void)decryptData:(NSString *)data
    senderPublicKey:(NSString *)key
         completion:
             (void (^)(NSString *_Nullable, NSError *_Nullable))completion {
    if (self.decryptBlock) {
        self.decryptBlock(data, key, completion);
    } else {
        completion(
            nil, MakeError(ErrorCodeDecryptionError, @"Decrypt block not set"));
    }
}

#pragma mark - Receive loop

/// Reads `task` until it closes. Once `task` is no longer the live transport
/// of `generation` (replaced, closed or failed), its frames and its closure
/// are ignored.
- (void)startReceiveLoop:(NSURLSessionWebSocketTask *)task
              generation:(NSInteger)generation {
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(
              NSURLSessionWebSocketMessage *message, NSError *error) {
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf)
          return;

      if (error) {
          [strongSelf handleTransportClosed:task reason:error];
          return;
      }

      if (![strongSelf isLiveTransport:task generation:generation]) {
          return;
      }

      if (message) {
          switch (message.type) {
          case NSURLSessionWebSocketMessageTypeString:
              [strongSelf parseIncomingMessage:message.string];
              break;
          case NSURLSessionWebSocketMessageTypeData:
              if (message.data) {
                  NSString *s =
                      [[NSString alloc] initWithData:message.data
                                            encoding:NSUTF8StringEncoding];
                  if (s)
                      [strongSelf parseIncomingMessage:s];
              }
              break;
          }
      }

      // Continue the receive loop
      [strongSelf startReceiveLoop:task generation:generation];
    }];
}

- (BOOL)isLiveTransport:(NSURLSessionWebSocketTask *)task
             generation:(NSInteger)generation {
    __block BOOL live = NO;
    [self withSocketLock:^{
      live = self.websocket == task && self.connectionGeneration == generation;
    }];
    return live;
}

/// Marks the connection closed when `task` is still the live transport and
/// emits `close`, from which `Adk` may reconnect.
- (void)handleTransportClosed:(NSURLSessionWebSocketTask *)task reason:(id)reason {
    __block BOOL live = NO;
    [self withSocketLock:^{
      if (self.websocket != task ||
          self.websocketGeneration != self.connectionGeneration) {
          return;
      }
      self.websocket = nil;
      self->_isConnectionActive = NO;
      self.isConnecting = NO;
      self.connectionBound = NO;
      live = YES;
    }];
    if (live) {
        [self.emitter emit:@"close" data:reason];
    }
}

- (NSUUID *)on:(NSString *)event handler:(void (^)(id))handler {
    return [self.emitter on:event handler:handler];
}

- (void)off:(NSString *)event identifier:(NSUUID *)identifier {
    [self.emitter off:event identifier:identifier];
}

- (void)URLSession:(NSURLSession *)session
       webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
              reason:(nullable NSData *)reason {
    [self handleTransportClosed:webSocketTask reason:@(closeCode)];
}

@end
