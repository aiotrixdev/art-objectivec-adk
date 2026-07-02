//
//  Socket.m
//  ADK
//

#import "Socket.h"
#import "Auth.h"
#import "AuthTypes.h"
#import "BaseSubscription.h"
#import "ChannelTypes.h"
#import "Constant.h"
#import "CryptoTypes.h"
#import "EventEmitter.h"
#import "HelperFunctions.h"
#import "HttpPoll.h"
#import "Interception.h"
#import "LiveObjSubscription.h"
#import "Subscription.h"
#import "Utils.h"

@interface Socket () <NSURLSessionWebSocketDelegate, NSURLSessionDataDelegate>

@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *websocket;
@property(nonatomic, strong) AuthenticationConfig *credentials;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, BaseSubscription *> *subscriptions;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, Interception *> *interceptors;
@property(nonatomic, strong, nullable) ConnectionDetail *connection;

// Heartbeat
@property(nonatomic, strong, nullable) NSTimer *heartbeatTimer;
@property(nonatomic, strong, nullable) dispatch_source_t heartbeatSource;

// Pending messages
@property(nonatomic, strong) NSMutableArray<NSString *> *pendingSendMessages;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, void (^)(id)> *secureCallbacks;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableArray *> *pendingIncomingMessages;

// Transport selection
@property(nonatomic, copy) NSString *pullSource; // "socket", "sse", "http"
@property(nonatomic, copy) NSString *pushSource; // "socket", "http"
@property(nonatomic, strong) LongPollClient *lpClient;

// Connection flags
@property(nonatomic, assign) BOOL isConnecting;
@property(nonatomic, assign) BOOL autoReconnect;

// SSE state
@property(nonatomic, strong, nullable) NSURLSessionDataTask *sseTask;
@property(nonatomic, strong) NSMutableData *sseBuffer;

// URL sessions
@property(nonatomic, strong) NSURLSession *wsSession;
@property(nonatomic, strong, nullable) NSURLSession *sseSession;

// Event emitter
@property(nonatomic, strong) EventEmitter *emitter;

// Connection waiters
@property(nonatomic, strong) NSMutableArray<void (^)(void)> *connectionWaiters;
@property(nonatomic, strong) NSLock *continuationLock;
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
        _pendingSendMessages = [NSMutableArray array];
        _secureCallbacks = [NSMutableDictionary dictionary];
        _pendingIncomingMessages = [NSMutableDictionary dictionary];
        _pullSource = @"socket";
        _pushSource = @"socket";
        _isConnecting = NO;
        _isReConnecting = NO;
        _isConnectionActive = NO;
        _autoReconnect = NO;
        _emitter = [[EventEmitter alloc] init];
        _connectionWaiters = [NSMutableArray array];
        _continuationLock = [[NSLock alloc] init];
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
              Auth *auth = [Auth getInstance:strongSelf.credentials
                                       error:&authErr];
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

        _lpClient = [[LongPollClient alloc] initWithOptions:lpOpts];
    }
    return self;
}

- (void)withSocketLock:(void (^)(void))block {
    [_socketLock lock];
    block();
    [_socketLock unlock];
}

- (id)withSocketLockReturning:(id (^)(void))block {
    [_socketLock lock];
    id result = block();
    [_socketLock unlock];
    return result;
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

- (void)initiateSocket:(AuthenticationConfig *)credentials
            completion:(nullable void (^)(NSError *_Nullable))completion {
    if (self.websocket != nil && self.isConnectionActive) {
        if (completion)
            completion(nil);
        return;
    }

    self.credentials = credentials;

    // 1. Try WebSocket
    __weak typeof(self) weakSelf = self;
    [self connectWebSocket:^(NSError *_Nullable wsError) {
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf)
          return;

      if (!wsError) {
          strongSelf.pullSource = @"socket";
          strongSelf.pushSource = @"socket";
          if (completion)
              completion(nil);
          return;
      }

      // 2. Try SSE
      [strongSelf connectSSE:^(NSError *_Nullable sseError) {
        typeof(self) strongSelf2 = weakSelf;
        if (!strongSelf2)
            return;

        if (!sseError) {
            strongSelf2.pullSource = @"sse";
            strongSelf2.pushSource = @"http";
            if (completion)
                completion(nil);
            return;
        }

        // 3. LongPoll
        strongSelf2.pullSource = @"http";
        strongSelf2.pushSource = @"http";
        [strongSelf2.lpClient start:strongSelf2.connection.connectionId];
        if (completion)
            completion(nil);
      }];
    }];
}

- (void)connectWebSocket:(void (^)(NSError *_Nullable))completion {
    if (self.isConnecting) {
        if (completion)
            completion(nil);
        return;
    }
    self.isConnecting = YES;

    NSError *authInstanceErr = nil;
    Auth *auth = [Auth getInstance:self.credentials error:&authInstanceErr];
    if (!auth) {
        self.isConnecting = NO;
        [self.emitter emit:@"close" data:authInstanceErr];
        if (completion)
            completion(authInstanceErr);
        return;
    }

    __weak typeof(self) weakSelf = self;
    [auth
        authenticate:self.isReConnecting
          completion:^(AuthData *authData, NSError *authError) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf)
                return;

            if (authError) {
                strongSelf.isConnecting = NO;
                [strongSelf.emitter emit:@"close" data:authError];
                if (completion)
                    completion(authError);
                return;
            }

            // Build WebSocket URL
            NSURLComponents *components =
                [NSURLComponents componentsWithString:Constant.WS_URL];
            components.queryItems = @[
                [NSURLQueryItem
                    queryItemWithName:@"connection_id"
                                value:strongSelf.connection.connectionId
                                          ?: @""],
                [NSURLQueryItem
                    queryItemWithName:@"Org-Title"
                                value:strongSelf.credentials.orgTitle],
                [NSURLQueryItem queryItemWithName:@"token"
                                            value:authData.accessToken],
                [NSURLQueryItem
                    queryItemWithName:@"environment"
                                value:strongSelf.credentials.environment],
                [NSURLQueryItem
                    queryItemWithName:@"project-key"
                                value:strongSelf.credentials.projectKey],
            ];

            NSURL *wsURL = components.URL;
            if (!wsURL) {
                strongSelf.isConnecting = NO;
                NSError *urlErr = MakeError(ErrorCodeInvalidPath,
                                            @"Could not build WebSocket URL");
                if (completion)
                    completion(urlErr);
                return;
            }

            // Close any existing socket
            [strongSelf safeClose:^{
              typeof(self) strongSelf2 = weakSelf;
              if (!strongSelf2)
                  return;

              // Create and resume the WebSocket task
              NSURLSessionWebSocketTask *task =
                  [strongSelf2.wsSession webSocketTaskWithURL:wsURL];
              [task resume];
              strongSelf2.websocket = task;
              strongSelf2.isConnecting = NO;
              [strongSelf2.emitter emit:@"open" data:[NSNull null]];
              [strongSelf2 startReceiveLoop];

              // Single-shot completion guard. The success path and the
              // timeout path race against each other; whichever fires
              // first wins, and the other is a no-op.
              __block BOOL completionFired = NO;
              void (^fireCompletionOnce)(NSError *_Nullable) =
                  ^(NSError *_Nullable err) {
                    @synchronized(strongSelf2) {
                        if (completionFired) return;
                        completionFired = YES;
                    }
                    if (completion) completion(err);
                  };

              // Success path: wait for the real connection-ready signal
              // (`art_ready` event) via the existing waiter mechanism.
              [strongSelf2 wait:^{
                fireCompletionOnce(nil);
              }];

              // 5-second handshake timeout runs in parallel.
              dispatch_after(
                  dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(5.0 * NSEC_PER_SEC)),
                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                  ^{
                    typeof(self) strongSelf3 = weakSelf;
                    if (!strongSelf3)
                        return;
                    if (!strongSelf3.isConnectionActive) {
                        [strongSelf3.websocket
                            cancelWithCloseCode:
                                NSURLSessionWebSocketCloseCodeGoingAway
                                         reason:nil];
                        NSError *timeoutErr = MakeError(
                            ErrorCodeTimeout, @"WebSocket handshake timeout");
                        fireCompletionOnce(timeoutErr);
                    }
                  });
            }];
          }];
}

- (void)safeClose:(void (^)(void))completion {
    NSURLSessionWebSocketTask *task = self.websocket;
    if (!task) {
        if (completion)
            completion();
        return;
    }
    if (task.state == NSURLSessionTaskStateCompleted) {
        self.websocket = nil;
        if (completion)
            completion();
        return;
    }

    [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                       reason:nil];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          self.websocket = nil;
          if (completion)
              completion();
        });
}

- (void)connectSSE:(void (^)(NSError *_Nullable))completion {

    NSError *authInstanceErr = nil;
    Auth *auth = [Auth getInstance:self.credentials error:&authInstanceErr];
    if (!auth) {
        if (completion)
            completion(authInstanceErr);
        return;
    }

    __weak typeof(self) weakSelf = self;
    [auth
        authenticate:NO
          completion:^(AuthData *authData, NSError *authError) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf)
                return;

            if (authError) {
                if (completion)
                    completion(authError);
                return;
            }

            NSURLComponents *components =
                [NSURLComponents componentsWithString:Constant.SSE_URL];
            components.queryItems = @[
                [NSURLQueryItem
                    queryItemWithName:@"Org-Title"
                                value:strongSelf.credentials.orgTitle],
                [NSURLQueryItem queryItemWithName:@"token"
                                            value:authData.accessToken],
                [NSURLQueryItem
                    queryItemWithName:@"environment"
                                value:strongSelf.credentials.environment],
                [NSURLQueryItem
                    queryItemWithName:@"project-key"
                                value:strongSelf.credentials.projectKey],
            ];

            NSURL *sseURL = components.URL;
            if (!sseURL) {
                if (completion)
                    completion(MakeError(ErrorCodeInvalidPath, @"Bad SSE URL"));
                return;
            }

            NSMutableURLRequest *req =
                [NSMutableURLRequest requestWithURL:sseURL];
            [req setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];

            // Create a dedicated session for SSE streaming
            NSURLSessionConfiguration *sseConfig =
                [NSURLSessionConfiguration defaultSessionConfiguration];
            strongSelf.sseSession =
                [NSURLSession sessionWithConfiguration:sseConfig
                                              delegate:strongSelf
                                         delegateQueue:nil];
            strongSelf.sseBuffer = [NSMutableData data];
            strongSelf.sseTask =
                [strongSelf.sseSession dataTaskWithRequest:req];
            [strongSelf.sseTask resume];

            strongSelf.isConnectionActive = YES;
            [strongSelf.emitter emit:@"open" data:[NSNull null]];

            if (completion)
                completion(nil);
          }];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {

    if (dataTask != self.sseTask)
        return;

    [self.sseBuffer appendData:data];

    // Process complete lines from buffer
    NSString *bufferStr = [[NSString alloc] initWithData:self.sseBuffer
                                                encoding:NSUTF8StringEncoding];
    if (!bufferStr)
        return;

    NSArray<NSString *> *lines = [bufferStr componentsSeparatedByString:@"\n"];

    // Keep the last incomplete line in buffer
    NSString *lastLine = [lines lastObject];
    NSData *remainingData = [lastLine dataUsingEncoding:NSUTF8StringEncoding];
    self.sseBuffer =
        remainingData ? [remainingData mutableCopy] : [NSMutableData data];

    for (NSUInteger i = 0; i < lines.count - 1; i++) {
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
    if (task == self.sseTask) {
        self.isConnectionActive = NO;
        self.sseTask = nil;
    }
}

- (void)handleConnectionBinding:(NSString *)rawData {
    [self setAutoReconnect:YES];

    NSData *jsonData = [rawData dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData)
        return;
    NSDictionary *data = [NSJSONSerialization JSONObjectWithData:jsonData
                                                         options:0
                                                           error:nil];
    if (![data isKindOfClass:[NSDictionary class]])
        return;

    self.connection = [[ConnectionDetail alloc]
        initWithConnectionId:data[@"connection_id"] ?: @""
                  instanceId:data[@"instance_id"] ?: @""
                  tenantName:self.credentials.orgTitle
                 environment:self.credentials.environment
                  projectKey:self.credentials.projectKey];
    [self.emitter emit:@"connection" data:self.connection];
    self.isConnectionActive = YES;
    [self startHeartbeat];
    [self resolveWaiters];

    // Flush pending messages
    __block NSArray<NSString *> *queued;
    __block NSArray<BaseSubscription *> *subs;
    __block NSArray<Interception *> *intercepts;

    [self withSocketLock:^{
      queued = [self.pendingSendMessages copy];
      [self.pendingSendMessages removeAllObjects];
      subs = [self.subscriptions.allValues copy];
      intercepts = [self.interceptors.allValues copy];
    }];

    for (NSString *msg in queued) {
        [self sendMessage:msg];
    }

    if (self.autoReconnect) {
        for (BaseSubscription *sub in subs) {
            [sub reconnect];
        }
        for (Interception *interception in intercepts) {
            [interception reconnect];
        }
    }
}

- (void)pushForSecureLine:(NSString *)event
                     data:(id)data
                   listen:(BOOL)listen
               completion:
                   (void (^)(id _Nullable, NSError *_Nullable))completion {

    NSString *connId = self.connection.connectionId ?: @"";
    NSString *rand = [NSString stringWithFormat:@"%x", arc4random()];
    NSTimeInterval ts = [[NSDate date] timeIntervalSince1970] * 1000.0;
    NSString *refId = [NSString
        stringWithFormat:@"%@_secure_%lld_%@", connId, (long long)ts, rand];

    // Build JSON content
    id jsonObject = data;
    if (![NSJSONSerialization isValidJSONObject:data]) {
        jsonObject = @{@"value" : data};
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonObject
                                                       options:0
                                                         error:nil];
    NSString *content =
        jsonData ? [[NSString alloc] initWithData:jsonData
                                         encoding:NSUTF8StringEncoding]
                 : @"{}";

    NSDictionary *payload = @{
        @"from" : connId,
        @"channel" : @"art_secure",
        @"event" : event,
        @"content" : content,
        @"ref_id" : refId
    };

    NSData *msgData = [NSJSONSerialization dataWithJSONObject:payload
                                                      options:0
                                                        error:nil];
    NSString *msgStr =
        msgData ? [[NSString alloc] initWithData:msgData
                                        encoding:NSUTF8StringEncoding]
                : nil;

    if (!msgStr) {
        if (completion)
            completion(nil, nil);
        return;
    }

    if (!listen) {
        [self sendMessage:msgStr];
        if (completion)
            completion(nil, nil);
        return;
    }

    // Store callback and send
    NSString *callbackKey = [NSString stringWithFormat:@"secure-%@", refId];

    __weak typeof(self) weakSelf = self;
    [self withSocketLock:^{
      self.secureCallbacks[callbackKey] = ^(id result) {
        if (completion)
            completion(result, nil);
      };
    }];

    [self sendMessage:msgStr];

    // 30-second timeout to prevent hanging. If the callback is still
    // registered when the timeout fires, remove it and invoke the caller's
    // completion with an explicit timeout error. Without this, callers
    // awaiting `pushForSecureLine` would hang forever if the server never
    // responds.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          typeof(self) strongSelf = weakSelf;
          if (!strongSelf)
              return;

          __block void (^cb)(id) = nil;
          [strongSelf withSocketLock:^{
            cb = strongSelf.secureCallbacks[callbackKey];
            [strongSelf.secureCallbacks removeObjectForKey:callbackKey];
          }];

          if (cb && completion) {
              completion(nil,
                         MakeError(ErrorCodeTimeout,
                                   @"Secure line response timeout"));
          }
        });
}

- (void)removeSubscription:(NSString *)channel {
    [self withSocketLock:^{
      [self.subscriptions removeObjectForKey:channel];
    }];
}

- (void)subscribe:(NSString *)channel
       completion:(void (^)(BaseSubscription *_Nullable,
                            NSError *_Nullable))completion {
    [self handleSubscription:channel completion:completion];
}

- (void)handleSubscription:(NSString *)channel
                completion:(void (^)(BaseSubscription *_Nullable,
                                     NSError *_Nullable))completion {

    __weak typeof(self) weakSelf = self;
    [self wait:^{
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf)
          return;

      NSString *connectionId = strongSelf.connection.connectionId ?: @"";

      // Check for existing subscription
      __block BaseSubscription *existing = nil;
      [strongSelf withSocketLock:^{
        existing = strongSelf.subscriptions[channel];
      }];

      if (existing) {
          [existing subscribe:^{
            completion(existing, nil);
          }];
          return;
      }

      // Validate and create subscription
      [strongSelf
          validateSubscription:channel
                       process:@"subscribe"
                    completion:^(ChannelConfig *config, NSError *valError) {
                      typeof(self) strongSelf2 = weakSelf;
                      if (!strongSelf2)
                          return;

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
                                  websocketHandler:strongSelf2
                                           process:@"subscribe"];
                      } else {
                          subscription = [[Subscription alloc]
                              initWithConnectionID:connectionId
                                     channelConfig:config
                                  websocketHandler:strongSelf2
                                           process:@"subscribe"];
                      }

                      // Store subscription and grab any buffered messages
                      __block NSMutableArray *buffered = nil;
                      [strongSelf2 withSocketLock:^{
                        strongSelf2.subscriptions[channel] = subscription;
                        buffered = strongSelf2.pendingIncomingMessages[channel];
                        [strongSelf2.pendingIncomingMessages
                            removeObjectForKey:channel];
                      }];

                      // Replay buffered messages
                      if (buffered) {
                          for (NSDictionary *item in buffered) {
                              NSString *evt = item[@"event"] ?: @"";
                              NSDictionary *payload = item[@"payload"] ?: @{};
                              [subscription handleMessage:evt payload:payload];
                          }
                      }

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
    return self.connection;
}

- (void)intercept:(NSString *)interceptor
               fn:(void (^)(NSDictionary *, void (^)(id),
                            void (^)(NSString *)))fn
       completion:
           (void (^)(Interception *_Nullable, NSError *_Nullable))completion {

    __weak typeof(self) weakSelf = self;
    [self wait:^{
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf)
          return;

      // Check existing
      __block Interception *existing = nil;
      [strongSelf withSocketLock:^{
        existing = strongSelf.interceptors[interceptor];
      }];

      if (existing) {
          completion(existing, nil);
          return;
      }

      Interception *interception =
          [[Interception alloc] initWithInterceptor:interceptor
                                                 fn:fn
                                   websocketHandler:strongSelf];
      [interception validateInterception:^(NSError *error) {
        typeof(self) strongSelf2 = weakSelf;
        if (!strongSelf2)
            return;

        if (error) {
            completion(nil, error);
            return;
        }

        [strongSelf2 withSocketLock:^{
          strongSelf2.interceptors[interceptor] = interception;
        }];

        completion(interception, nil);
      }];
    }];
}

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
    NSString *channel = parsed[@"channel"];
    if (![channel isKindOfClass:[NSString class]]) {
        return;
    }

    NSString *event = parsed[@"event"] ?: @"";
    NSString *refId = parsed[@"ref_id"] ?: @"";
    NSString *returnFlag = parsed[@"return_flag"] ?: @"";
    NSString *interceptorName = parsed[@"interceptor_name"];
    NSString *namespace_ = parsed[@"namespace"] ?: @"";
    id rawData = parsed[@"content"];

    if ([channel isEqualToString:@"art_ready"] &&
        [event isEqualToString:@"ready"]) {
        NSString *rawStr = [rawData isKindOfClass:[NSString class]]
                               ? (NSString *)rawData
                               : @"";
        [self handleConnectionBinding:rawStr];
        return;
    }

    //  secure callback
    if ([channel isEqualToString:@"art_secure"]) {
        NSString *key = [NSString stringWithFormat:@"secure-%@", refId];
        __block void (^cb)(id) = nil;
        [self withSocketLock:^{
          cb = self.secureCallbacks[key];
          [self.secureCallbacks removeObjectForKey:key];
        }];

        if (cb) {
            NSMutableDictionary *dataDict =
                [NSMutableDictionary dictionaryWithDictionary:@{
                    @"channel" : channel,
                    @"namespace" : namespace_,
                    @"ref_id" : refId,
                    @"event" : event
                }];
            if ([rawData isKindOfClass:[NSString class]]) {
                NSData *jsonData = [(NSString *)rawData
                    dataUsingEncoding:NSUTF8StringEncoding];
                if (jsonData) {
                    NSDictionary *innerParsed =
                        [NSJSONSerialization JSONObjectWithData:jsonData
                                                        options:0
                                                          error:nil];
                    if ([innerParsed isKindOfClass:[NSDictionary class]]) {
                        dataDict[@"data"] = innerParsed;
                    }
                }
            }

            NSDictionary *result = @{
                @"data" : dataDict[@"data"] ?: [NSNull null],
                @"channel" : channel,
                @"namespace" : namespace_,
                @"ref_id" : refId,
                @"event" : event
            };
            cb(result);
        }
        return;
    }

    // Drop ONLY when the channel is empty (mirrors js-adk-common / Flutter
    // socket). Agentic replies (orchestrator & agent) carry their semantic
    // type inside `content` (e.g. `agent_general_response`,
    // `human_input_request`) and leave the wire-level `event` empty — yet they
    // must still route to the thread's event-agnostic "<threadId>-all"
    // listener. Dropping on an empty `event` here would make the orchestrator
    // "connect, but never reply".
    if (channel.length == 0) {
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

    // Interceptor routing
    if ([interceptorName isKindOfClass:[NSString class]] &&
        interceptorName.length > 0) {
        __block Interception *interception = nil;
        [self withSocketLock:^{
          interception = self.interceptors[interceptorName];
        }];

        if (interception) {
            [interception handleMessage:channel data:payload];
        }
        return;
    }

    // Subscription routing
    NSString *subKey = channel;
    if (namespace_.length > 0) {
        subKey = [NSString stringWithFormat:@"%@:%@", channel, namespace_];
    }

    __block BaseSubscription *sub = nil;
    [self withSocketLock:^{
      sub = self.subscriptions[subKey];
    }];

    if (sub) {
        [sub handleMessage:event payload:payload];
    } else if (![returnFlag isEqualToString:@"SA"]) {
        // Don't buffer bare server acks that have no subscription yet
        // (mirrors Flutter socket's `else if returnFlag != 'SA'`).
        [self withSocketLock:^{
          NSMutableArray *buffer = self.pendingIncomingMessages[subKey];
          if (!buffer) {
              buffer = [NSMutableArray array];
              self.pendingIncomingMessages[subKey] = buffer;
          }
          [buffer addObject:@{@"event" : event, @"payload" : payload}];
        }];
    }
}

- (void)switchToHttpPoll {
    if ([self.pullSource isEqualToString:@"http"])
        return;
    self.pullSource = @"http";
    self.pushSource = @"http";
    [self.lpClient start:self.connection.connectionId ?: @""];
}

- (BOOL)sendMessage:(NSString *)message {

    NSURLSessionWebSocketTask *task = self.websocket;
    if (!task || task.state != NSURLSessionTaskStateRunning) {
        [self withSocketLock:^{
          [self.pendingSendMessages addObject:message];
        }];
        return NO;
    }

    NSURLSessionWebSocketMessage *wsMessage =
        [[NSURLSessionWebSocketMessage alloc] initWithString:message];
    __weak typeof(self) weakSelf = self;
    [task sendMessage:wsMessage
        completionHandler:^(NSError *_Nullable error) {
          if (error) {
              [weakSelf.emitter emit:@"error" data:error];
          }
        }];
    return YES;
}

- (void)setAutoReconnect:(BOOL)flag {
    _autoReconnect = flag;
}

- (void)closeWebSocket:(BOOL)clearConnection
            completion:(nullable void (^)(void))completion {

    __weak typeof(self) weakSelf = self;
    [self safeClose:^{
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf)
          return;

      strongSelf.isConnectionActive = NO;
      strongSelf.connection = nil;
      strongSelf.isConnecting = NO;

      // Cancel SSE
      [strongSelf.sseTask cancel];
      strongSelf.sseTask = nil;

      if (clearConnection) {
          [strongSelf withSocketLock:^{
            [strongSelf.pendingIncomingMessages removeAllObjects];
            [strongSelf.pendingSendMessages removeAllObjects];
            [strongSelf.subscriptions removeAllObjects];
            [strongSelf.interceptors removeAllObjects];
          }];
      }

      [strongSelf stopHeartbeat];

      if (completion)
          completion();
    }];
}

- (void)wait:(void (^)(void))completion {
    if (self.isConnectionActive) {
        completion();
        return;
    }

    [self.continuationLock lock];
    [self.connectionWaiters addObject:[completion copy]];
    [self.continuationLock unlock];
}

- (NSDictionary *)runHeartbeatPayload {
    __block NSArray *subsInfo;
    [self withSocketLock:^{
      NSMutableArray *arr = [NSMutableArray array];
      [self.subscriptions
          enumerateKeysAndObjectsUsingBlock:^(
              NSString *key, BaseSubscription *sub, BOOL *stop) {
            [arr addObject:@{
                @"name" : key,
                @"presenceTracking" : @(sub.isListening)
            }];
          }];
      subsInfo = [arr copy];
    }];

    return @{
        @"connectionId" : self.connection.connectionId ?: [NSNull null],
        @"timestamp" : @([[NSDate date] timeIntervalSince1970] * 1000.0),
        @"subscriptions" : subsInfo
    };
}

- (void)startHeartbeat {
    if (self.heartbeatSource)
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

      NSDictionary *payload = [strongSelf runHeartbeatPayload];
      [strongSelf
          pushForSecureLine:@"heartbeat"
                       data:payload
                     listen:NO
                 completion:^(id _Nullable result, NSError *_Nullable error){
                 }];
    });

    dispatch_resume(timer);
    self.heartbeatSource = timer;
}

- (void)stopHeartbeat {
    if (self.heartbeatSource) {
        dispatch_source_cancel(self.heartbeatSource);
        self.heartbeatSource = nil;
    }
}

- (void)resolveWaiters {
    [self.continuationLock lock];
    NSArray<void (^)(void)> *waiters = [self.connectionWaiters copy];
    [self.connectionWaiters removeAllObjects];
    [self.continuationLock unlock];

    for (void (^waiter)(void) in waiters) {
        waiter();
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

- (void)startReceiveLoop {
    __weak typeof(self) weakSelf = self;
    NSURLSessionWebSocketTask *task = self.websocket;
    if (!task || task.state != NSURLSessionTaskStateRunning)
        return;

    [task receiveMessageWithCompletionHandler:^(
              NSURLSessionWebSocketMessage *message, NSError *error) {
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf)
          return;

      if (error) {
          strongSelf.isConnectionActive = NO;
          strongSelf.isConnecting = NO;
          [strongSelf.emitter emit:@"close" data:error];
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
      [strongSelf startReceiveLoop];
    }];
}

- (NSUUID *)on:(NSString *)event handler:(void (^)(id))handler {
    return [self.emitter on:event handler:handler];
}

- (void)off:(NSString *)event identifier:(NSUUID *)identifier {
    [self.emitter off:event identifier:identifier];
}

- (void)URLSession:(NSURLSession *)session
          webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
    didOpenWithProtocol:(nullable NSString *)protocol_ {
    self.isConnectionActive = NO;
}

- (void)URLSession:(NSURLSession *)session
       webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
              reason:(nullable NSData *)reason {
    self.isConnectionActive = NO;
    self.isConnecting = NO;

    NSString *reasonStr = nil;
    if (reason) {
        reasonStr = [[NSString alloc] initWithData:reason
                                          encoding:NSUTF8StringEncoding];
    }

    [self.emitter emit:@"close" data:@(closeCode)];
}

@end
