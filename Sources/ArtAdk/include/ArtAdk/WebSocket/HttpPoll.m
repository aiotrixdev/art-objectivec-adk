//
//  LongPollClient.m
//  ADK
//

#import "HttpPoll.h"
#import "Auth.h"
#import "Utils.h"

@interface LongPollClient ()

@property(nonatomic, strong, readonly) LongPollOptions *opts;
// Guarded by @synchronized(self).
@property(nonatomic, copy, nullable) NSString *connectionId;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, strong, nullable) NSURLSessionDataTask *currentTask;
@property(nonatomic, assign) double currentEmptyBackoffMs;

@end

@implementation LongPollClient

- (instancetype)initWithOptions:(LongPollOptions *)opts {
    self = [super init];
    if (self) {
        _opts = opts;
        _connectionId = opts.initialConnectionId;
        _running = NO;
        _currentEmptyBackoffMs = (double)opts.emptyPollDelayMs;
    }
    return self;
}

- (BOOL)isRunning {
    @synchronized(self) {
        return _running;
    }
}

- (void)start:(nullable NSString *)connectionId {
    @synchronized(self) {
        if (_running) {
            return;
        }
        if (connectionId.length > 0) {
            _connectionId = [connectionId copy];
        }
        _running = YES;
        _currentEmptyBackoffMs = (double)_opts.emptyPollDelayMs;
    }
    [self scheduleNextPollAfterMs:0];
}

- (void)stop {
    NSURLSessionDataTask *task;
    @synchronized(self) {
        _running = NO;
        task = _currentTask;
        _currentTask = nil;
    }
    [task cancel];
}

// Non-blocking scheduler: uses dispatch_after instead of NSThread sleep,
// so no GCD worker thread is ever parked. The poll cycle runs entirely
// via completion callbacks; `stop` cancels the in-flight request and
// the `isRunning` check in each callback terminates the chain.
- (void)scheduleNextPollAfterMs:(double)ms {
    if (!self.isRunning)
        return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          typeof(self) strongSelf = weakSelf;
          if (!strongSelf || !strongSelf.isRunning)
              return;
          [strongSelf fireOnePoll];
        });
}

/// Reports a failed poll, then stops on rejected credentials (they cannot
/// succeed on retry) or schedules the next one.
- (void)pollFailed:(NSError *)error {
    if (self.opts.onError) {
        self.opts.onError(error);
    }
    if (ARTIsTerminalAuthError(error)) {
        @synchronized(self) {
            _running = NO;
        }
        return;
    }
    [self scheduleNextPollAfterMs:(double)self.opts.retryDelayMs];
}

- (void)fireOnePoll {
    if (!self.isRunning)
        return;

    // Build URL
    NSURLComponents *components =
        [NSURLComponents componentsWithString:_opts.endpoint];
    if (!components) {
        [self scheduleNextPollAfterMs:(double)_opts.retryDelayMs];
        return;
    }

    NSString *connectionId;
    @synchronized(self) {
        connectionId = _connectionId;
    }
    if (connectionId) {
        NSMutableArray<NSURLQueryItem *> *items =
            [NSMutableArray arrayWithArray:components.queryItems ?: @[]];
        [items addObject:[NSURLQueryItem queryItemWithName:@"connection_id"
                                                     value:connectionId]];
        components.queryItems = items;
    }

    NSURL *url = components.URL;
    if (!url) {
        [self scheduleNextPollAfterMs:(double)_opts.retryDelayMs];
        return;
    }

    // Fetch auth headers asynchronously, then fire the request.
    __weak typeof(self) weakSelf = self;
    _opts.getAuthHeaders(
        ^(NSDictionary<NSString *, NSString *> *headers, NSError *authError) {
          typeof(self) strongSelf = weakSelf;
          if (!strongSelf || !strongSelf.isRunning)
              return;

          if (authError) {
              [strongSelf pollFailed:authError];
              return;
          }

          NSMutableURLRequest *request =
              [NSMutableURLRequest requestWithURL:url];
          request.timeoutInterval = 35;
          [headers enumerateKeysAndObjectsUsingBlock:^(
                       NSString *key, NSString *value, BOOL *stop) {
            [request setValue:value forHTTPHeaderField:key];
          }];

          NSURLSessionDataTask *task = [[NSURLSession sharedSession]
              dataTaskWithRequest:request
                completionHandler:^(NSData *responseData,
                                    NSURLResponse *urlResponse,
                                    NSError *networkError) {
                  typeof(self) inner = weakSelf;
                  if (!inner || !inner.isRunning)
                      return;
                  [inner handleResponse:responseData
                            urlResponse:urlResponse
                                  error:networkError];
                }];
          BOOL stillRunning;
          @synchronized(strongSelf) {
              stillRunning = strongSelf->_running;
              if (stillRunning) {
                  strongSelf.currentTask = task;
              }
          }
          if (stillRunning) {
              [task resume];
          }
        });
}

- (void)handleResponse:(NSData *)responseData
           urlResponse:(NSURLResponse *)urlResponse
                 error:(NSError *)networkError {
    @synchronized(self) {
        _currentTask = nil;
    }

    if (networkError) {
        [self pollFailed:networkError];
        return;
    }

    NSHTTPURLResponse *http = nil;
    if ([urlResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        http = (NSHTTPURLResponse *)urlResponse;
    }
    if (!http) {
        [self scheduleNextPollAfterMs:(double)self.opts.retryDelayMs];
        return;
    }

    // 204 = empty — exponential backoff
    if (http.statusCode == 204) {
        if (self.opts.onResponse) {
            self.opts.onResponse();
        }
        double delay;
        @synchronized(self) {
            delay = _currentEmptyBackoffMs;
            _currentEmptyBackoffMs =
                MIN(_currentEmptyBackoffMs * 2.0, (double)self.opts.maxEmptyPollDelayMs);
        }
        [self scheduleNextPollAfterMs:delay];
        return;
    }

    // Non-200 error
    if (http.statusCode != 200) {
        id body = responseData.length > 0
                      ? [NSJSONSerialization JSONObjectWithData:responseData
                                                        options:NSJSONReadingFragmentsAllowed
                                                          error:nil]
                      : nil;
        id message = [body isKindOfClass:[NSDictionary class]]
                         ? ((NSDictionary *)body)[@"message"]
                         : nil;
        NSString *text =
            ([message isKindOfClass:[NSString class]] && [message length] > 0)
                ? message
                : [NSString stringWithFormat:@"Connection request failed (HTTP %ld).",
                                             (long)http.statusCode];
        [self pollFailed:[ARTAuthHttpError errorWithMessage:text
                                                     status:http.statusCode
                                                       body:body]];
        return;
    }

    // 200 OK — reset backoff, parse JSON
    @synchronized(self) {
        _currentEmptyBackoffMs = (double)self.opts.emptyPollDelayMs;
    }
    if (self.opts.onResponse) {
        self.opts.onResponse();
    }

    if (responseData) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseData
                                                             options:0
                                                               error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) {
            @synchronized(self) {
                if (!_connectionId) {
                    NSString *cid = json[@"connection_id"];
                    if ([cid isKindOfClass:[NSString class]]) {
                        _connectionId = cid;
                    }
                }
            }
            NSArray *messages = json[@"messages"];
            if ([messages isKindOfClass:[NSArray class]] && messages.count > 0) {
                self.opts.onMessages(messages);
            }
        }
    }

    // Immediately schedule the next poll
    [self scheduleNextPollAfterMs:0];
}

@end
