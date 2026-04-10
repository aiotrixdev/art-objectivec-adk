//
//  LongPollClient.m
//  ADK
//

#import "HttpPoll.h"
#import "Utils.h"

@interface LongPollClient ()

@property(nonatomic, strong, readonly) LongPollOptions *opts;
@property(nonatomic, copy, nullable) NSString *connectionId;
@property(nonatomic, assign, readwrite) BOOL isRunning;
@property(nonatomic, strong, nullable) NSURLSessionDataTask *currentTask;
@property(nonatomic, assign) double currentEmptyBackoffMs;

@end

@implementation LongPollClient

- (instancetype)initWithOptions:(LongPollOptions *)opts {
    self = [super init];
    if (self) {
        _opts = opts;
        _connectionId = opts.initialConnectionId;
        _isRunning = NO;
        _currentEmptyBackoffMs = (double)opts.emptyPollDelayMs;
    }
    return self;
}

- (void)start:(nullable NSString *)connectionId {
    if (_isRunning)
        return;
    if (connectionId) {
        _connectionId = [connectionId copy];
    }
    _isRunning = YES;
    _currentEmptyBackoffMs = (double)_opts.emptyPollDelayMs;
    [self scheduleNextPollAfterMs:0];
}

- (void)stop {
    _isRunning = NO;
    [_currentTask cancel];
    _currentTask = nil;
}

// Non-blocking scheduler: uses dispatch_after instead of NSThread sleep,
// so no GCD worker thread is ever parked. The poll cycle runs entirely
// via completion callbacks; `stop` cancels the in-flight request and
// the `isRunning` check in each callback terminates the chain.
- (void)scheduleNextPollAfterMs:(double)ms {
    if (!_isRunning)
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

- (void)fireOnePoll {
    if (!_isRunning)
        return;

    // Build URL
    NSURLComponents *components =
        [NSURLComponents componentsWithString:_opts.endpoint];
    if (!components) {
        [self scheduleNextPollAfterMs:(double)_opts.retryDelayMs];
        return;
    }

    if (_connectionId) {
        NSMutableArray<NSURLQueryItem *> *items =
            [NSMutableArray arrayWithArray:components.queryItems ?: @[]];
        [items addObject:[NSURLQueryItem queryItemWithName:@"connection_id"
                                                     value:_connectionId]];
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
              if (strongSelf.opts.onError)
                  strongSelf.opts.onError(authError);
              [strongSelf scheduleNextPollAfterMs:
                              (double)strongSelf.opts.retryDelayMs];
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
                  inner.currentTask = nil;

                  if (networkError) {
                      if (inner.opts.onError)
                          inner.opts.onError(networkError);
                      [inner scheduleNextPollAfterMs:
                                 (double)inner.opts.retryDelayMs];
                      return;
                  }

                  NSHTTPURLResponse *http = nil;
                  if ([urlResponse isKindOfClass:[NSHTTPURLResponse class]]) {
                      http = (NSHTTPURLResponse *)urlResponse;
                  }
                  if (!http) {
                      [inner scheduleNextPollAfterMs:
                                 (double)inner.opts.retryDelayMs];
                      return;
                  }

                  // 204 = empty — exponential backoff
                  if (http.statusCode == 204) {
                      double delay = inner.currentEmptyBackoffMs;
                      inner.currentEmptyBackoffMs =
                          MIN(inner.currentEmptyBackoffMs * 2.0,
                              (double)inner.opts.maxEmptyPollDelayMs);
                      [inner scheduleNextPollAfterMs:delay];
                      return;
                  }

                  // Non-200 error
                  if (http.statusCode != 200) {
                      if (inner.opts.onError) {
                          NSString *msg = [NSString
                              stringWithFormat:@"LongPoll HTTP %ld",
                                               (long)http.statusCode];
                          inner.opts.onError(
                              MakeError(ErrorCodeServerError, msg));
                      }
                      [inner scheduleNextPollAfterMs:
                                 (double)inner.opts.retryDelayMs];
                      return;
                  }

                  // 200 OK — reset backoff, parse JSON
                  inner.currentEmptyBackoffMs =
                      (double)inner.opts.emptyPollDelayMs;

                  if (responseData) {
                      NSDictionary *json = [NSJSONSerialization
                          JSONObjectWithData:responseData
                                     options:0
                                       error:nil];
                      if ([json isKindOfClass:[NSDictionary class]]) {
                          if (!inner.connectionId) {
                              NSString *cid = json[@"connection_id"];
                              if ([cid isKindOfClass:[NSString class]]) {
                                  inner.connectionId = cid;
                              }
                          }
                          NSArray *messages = json[@"messages"];
                          if ([messages isKindOfClass:[NSArray class]] &&
                              messages.count > 0) {
                              inner.opts.onMessages(messages);
                          }
                      }
                  }

                  // Immediately schedule the next poll
                  [inner scheduleNextPollAfterMs:0];
                }];
          strongSelf.currentTask = task;
          [task resume];
        });
}

@end
