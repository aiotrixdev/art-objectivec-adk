//
//  HTTPCall.m
//  ADK
//

#import "HTTPCall+Internal.h"
#import "ARTSupport.h"
#import "Auth.h"
#import "AuthTypes.h"
#import "Constant.h"
#import "SocketTypes.h"
#import "Utils.h"

static NSURLSession *_ARTHTTPSession = nil;
static NSURLSessionConfiguration *_ARTUploadConfiguration = nil;

@implementation ARTHTTPClient

+ (NSURLSession *)session {
    @synchronized(self) {
        return _ARTHTTPSession ?: [NSURLSession sharedSession];
    }
}

+ (void)setSession:(NSURLSession *)session {
    @synchronized(self) {
        _ARTHTTPSession = session;
    }
}

+ (NSURLSessionConfiguration *)uploadConfiguration {
    @synchronized(self) {
        return _ARTUploadConfiguration
                   ?: [NSURLSessionConfiguration ephemeralSessionConfiguration];
    }
}

+ (void)setUploadConfiguration:(NSURLSessionConfiguration *)configuration {
    @synchronized(self) {
        _ARTUploadConfiguration = configuration;
    }
}

+ (void)call:(NSString *)endpoint
       options:(CallApiProps *)options
    completion:(void (^)(id _Nullable, NSError *_Nullable))completion {
    [self authorizedRequest:endpoint
                    options:options
                 completion:^(NSMutableURLRequest *request, NSError *error) {
                   if (!request) {
                       completion(nil, error);
                       return;
                   }
                   NSURLSessionDataTask *task = [self.session
                       dataTaskWithRequest:request
                         completionHandler:^(NSData *data, NSURLResponse *response,
                                             NSError *networkError) {
                           if (networkError) {
                               completion(nil, networkError);
                               return;
                           }
                           id result = nil;
                           NSError *decodeError = nil;
                           if ([self decodeData:data
                                       response:response
                                       endpoint:endpoint
                                         result:&result
                                          error:&decodeError]) {
                               completion(result, nil);
                           } else {
                               completion(nil, decodeError);
                           }
                         }];
                   [task resume];
                 }];
}

+ (void)authorizedRequest:(NSString *)endpoint
                  options:(CallApiProps *)options
               completion:(void (^)(NSMutableURLRequest *_Nullable,
                                    NSError *_Nullable))completion {
    CallApiProps *opts = options ?: [[CallApiProps alloc] init];

    NSError *authErr = nil;
    Auth *auth = [Auth getInstance:nil error:&authErr];
    if (!auth) {
        completion(nil, authErr);
        return;
    }

    [auth authenticate:NO
            completion:^(AuthData *authData, NSError *authError) {
              if (authError) {
                  completion(nil, authError);
                  return;
              }
              AuthenticationConfig *creds = [auth getCredentials];

              // URL (+ optional query). `baseUrl` overrides the gateway.
              NSMutableString *urlString = [NSMutableString
                  stringWithFormat:@"%@%@", opts.baseUrl ?: Constant.BASE_URL,
                                   endpoint];
              if (opts.queryParams.count > 0) {
                  [urlString
                      appendFormat:@"%@%@",
                                   [urlString containsString:@"?"] ? @"&" : @"?",
                                   [ARTEncoding formQueryWithDictionary:opts.queryParams]];
              }
              NSURL *url = [NSURL URLWithString:urlString];
              if (!url) {
                  completion(nil, MakeError(ErrorCodeInvalidPath,
                                            [NSString stringWithFormat:
                                                          @"Malformed API URL: %@",
                                                          urlString]));
                  return;
              }

              NSMutableURLRequest *request =
                  [NSMutableURLRequest requestWithURL:url];
              request.HTTPMethod = opts.method.uppercaseString ?: @"GET";
              [request setValue:[NSString stringWithFormat:@"Bearer %@",
                                                           authData.accessToken]
                  forHTTPHeaderField:@"Authorization"];
              [request setValue:@"application/json"
                  forHTTPHeaderField:@"Accept"];
              [request setValue:creds.orgTitle forHTTPHeaderField:@"X-Org"];
              [request setValue:creds.environment
                  forHTTPHeaderField:@"Environment"];
              [request setValue:creds.projectKey
                  forHTTPHeaderField:@"ProjectKey"];
              [opts.headers enumerateKeysAndObjectsUsingBlock:^(
                                NSString *key, NSString *value, BOOL *stop) {
                [request setValue:value forHTTPHeaderField:key];
              }];

              if ([opts.payload isKindOfClass:[ARTFormDataPayload class]]) {
                  ARTFormDataPayload *form = opts.payload;
                  NSMutableArray<NSArray<NSString *> *> *fields = [NSMutableArray array];
                  for (NSString *key in [form.fields.allKeys
                           sortedArrayUsingSelector:@selector(compare:)]) {
                      [fields addObject:@[ key, form.fields[key] ]];
                  }
                  ARTMultipartBody *body = [[ARTMultipartBody alloc] init];
                  [request setValue:body.contentType
                      forHTTPHeaderField:@"Content-Type"];
                  request.HTTPBody = [body encodeFields:fields files:form.files];
              } else if (opts.payload) {
                  NSError *jsonErr = nil;
                  NSString *body = [ARTJSON stringify:opts.payload
                                                error:&jsonErr];
                  if (!body) {
                      completion(nil, jsonErr);
                      return;
                  }
                  [request setValue:@"application/json"
                      forHTTPHeaderField:@"Content-Type"];
                  request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
              }

              if (opts.timeoutMs) {
                  request.timeoutInterval = opts.timeoutMs.doubleValue / 1000.0;
              }
              completion(request, nil);
            }];
}

+ (BOOL)decodeData:(NSData *)data
          response:(NSURLResponse *)response
          endpoint:(NSString *)endpoint
            result:(id _Nullable *)result
             error:(NSError **)error {
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                                  ? (NSHTTPURLResponse *)response
                                  : nil;
    if (!http) {
        if (error) {
            *error = MakeError(ErrorCodeServerError,
                               [NSString stringWithFormat:@"No HTTP response for %@",
                                                          endpoint]);
        }
        return NO;
    }

    if (http.statusCode < 200 || http.statusCode >= 300) {
        if (error) {
            *error = [self errorForEndpoint:endpoint
                                     status:http.statusCode
                                       data:data];
        }
        return NO;
    }

    // 204 No Content / empty body
    if (http.statusCode == 204 || data.length == 0) {
        return YES;
    }

    NSError *parseErr = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data
                                              options:NSJSONReadingFragmentsAllowed
                                                error:&parseErr];
    if (!json) {
        if (error) {
            *error = parseErr ?: MakeError(ErrorCodeServerError, @"Invalid JSON response");
        }
        return NO;
    }
    if (result) {
        *result = json;
    }
    return YES;
}

+ (void)sendRequest:(NSURLRequest *)request
          timeoutMs:(NSInteger)timeoutMs
       timeoutError:(NSError * (^)(void))timeoutError
         completion:(void (^)(NSData *_Nullable, NSURLResponse *_Nullable,
                              NSError *_Nullable))completion {
    NSMutableURLRequest *bounded = [request mutableCopy];
    bounded.timeoutInterval = MAX((NSTimeInterval)timeoutMs / 1000.0, 0.001);

    // The response and the timer race; the first one wins.
    NSObject *gate = [[NSObject alloc] init];
    __block BOOL finished = NO;
    __block dispatch_block_t timer = nil;
    void (^finish)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
          dispatch_block_t pendingTimer;
          @synchronized(gate) {
              if (finished) {
                  return;
              }
              finished = YES;
              pendingTimer = timer;
              timer = nil;
          }
          if (pendingTimer) {
              dispatch_block_cancel(pendingTimer);
          }
          completion(data, response, error);
        };

    NSURLSessionDataTask *task = [self.session
        dataTaskWithRequest:bounded
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if ([error.domain isEqualToString:NSURLErrorDomain] &&
                error.code == NSURLErrorTimedOut) {
                finish(nil, nil, timeoutError());
                return;
            }
            finish(data, response, error);
          }];

    dispatch_block_t expire = dispatch_block_create(0, ^{
      finish(nil, nil, timeoutError());
      [task cancel];
    });
    @synchronized(gate) {
        timer = expire;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(MAX(timeoutMs, 0) * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                   expire);
    [task resume];
}

+ (NSError *)errorForEndpoint:(NSString *)endpoint
                       status:(NSInteger)status
                         data:(NSData *)data {
    NSString *message = [NSHTTPURLResponse localizedStringForStatusCode:status];
    id body = [ARTJSON parseData:data];
    if (body) {
        id serverMessage = [body isKindOfClass:[NSDictionary class]]
                               ? ((NSDictionary *)body)[@"message"]
                               : nil;
        if ([serverMessage isKindOfClass:[NSString class]] &&
            [(NSString *)serverMessage length] > 0) {
            message = (NSString *)serverMessage;
        } else {
            NSString *text = [ARTJSON stringify:body error:nil];
            if (text.length > 0) {
                message = text;
            }
        }
    }

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] =
        [NSString stringWithFormat:@"API %@ failed: %@", endpoint, message];
    userInfo[ARTHTTPStatusCodeKey] = @(status);
    userInfo[ARTHTTPMessageKey] = message;
    userInfo[ARTHTTPEndpointKey] = endpoint;
    if (body) {
        userInfo[ARTHTTPResponseBodyKey] = body;
    }
    return [NSError errorWithDomain:ErrorDomain
                               code:ErrorCodeServerError
                           userInfo:userInfo];
}

@end

@implementation ARTGateway

+ (NSString *)restBase {
    NSString *base = Constant.BASE_URL;
    if ([base hasSuffix:@"/ws"]) {
        base = [base substringToIndex:base.length - 3];
    }
    return base;
}

+ (NSString *)origin {
    NSURLComponents *components =
        [NSURLComponents componentsWithString:Constant.BASE_URL];
    if (!components.scheme || !components.host) {
        return Constant.BASE_URL;
    }
    if (components.port) {
        return [NSString stringWithFormat:@"%@://%@:%@", components.scheme,
                                          components.host, components.port];
    }
    return [NSString
        stringWithFormat:@"%@://%@", components.scheme, components.host];
}

@end

@implementation ARTMultipartBody

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *unique = [NSUUID.UUID.UUIDString
            stringByReplacingOccurrencesOfString:@"-"
                                      withString:@""];
        _boundary = [NSString stringWithFormat:@"ArtAdkFormBoundary%@", unique];
    }
    return self;
}

- (NSString *)contentType {
    return [NSString stringWithFormat:@"multipart/form-data; boundary=%@", self.boundary];
}

- (NSData *)encodeFields:(NSArray<NSArray<NSString *> *> *)fields
                   files:(NSArray<ARTFormDataFile *> *)files {
    NSMutableData *body = [[self encodedFields:fields] mutableCopy];
    for (ARTFormDataFile *file in files) {
        [body appendData:[self fileHeaderForField:file.field
                                         filename:file.filename
                                      contentType:file.contentType]];
        [body appendData:file.data];
        [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [body appendData:[self closing]];
    return body;
}

- (BOOL)writeFields:(NSArray<NSArray<NSString *> *> *)fields
              field:(NSString *)field
           filename:(NSString *)filename
        contentType:(NSString *)contentType
             source:(NSURL *)source
                 to:(NSURL *)destination
              error:(NSError **)error {
    if (![[NSFileManager defaultManager] createFileAtPath:destination.path
                                                 contents:nil
                                               attributes:nil]) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileWriteUnknownError
                                     userInfo:nil];
        }
        return NO;
    }
    NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:destination
                                                             error:error];
    if (!output) {
        return NO;
    }
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:source
                                                              error:error];
    if (!input) {
        [output closeAndReturnError:nil];
        return NO;
    }

    NSMutableData *head = [[self encodedFields:fields] mutableCopy];
    [head appendData:[self fileHeaderForField:field
                                     filename:filename
                                  contentType:contentType]];
    BOOL ok = [output writeData:head error:error];
    while (ok) {
        NSData *chunk = nil;
        @autoreleasepool {
            chunk = [input readDataUpToLength:(1 << 20) error:error];
            if (!chunk) {
                ok = NO;
            } else if (chunk.length > 0) {
                ok = [output writeData:chunk error:error];
            }
        }
        if (chunk.length == 0) {
            break;
        }
    }
    if (ok) {
        NSMutableData *tail =
            [[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [tail appendData:[self closing]];
        ok = [output writeData:tail error:error];
    }
    [input closeAndReturnError:nil];
    [output closeAndReturnError:nil];
    return ok;
}

- (NSData *)closing {
    return [[NSString stringWithFormat:@"--%@--\r\n", self.boundary]
        dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)encodedFields:(NSArray<NSArray<NSString *> *> *)fields {
    NSMutableString *text = [NSMutableString string];
    for (NSArray<NSString *> *pair in fields) {
        [text appendFormat:@"--%@\r\nContent-Disposition: form-data; "
                           @"name=\"%@\"\r\n\r\n%@\r\n",
                           self.boundary, [ARTMultipartBody quoted:pair[0]], pair[1]];
    }
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)fileHeaderForField:(NSString *)field
                      filename:(NSString *)filename
                   contentType:(nullable NSString *)contentType {
    NSString *text = [NSString
        stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"; "
                         @"filename=\"%@\"\r\nContent-Type: %@\r\n\r\n",
                         self.boundary, [ARTMultipartBody quoted:field],
                         [ARTMultipartBody quoted:filename],
                         contentType ?: @"application/octet-stream"];
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

/// Escapes a quoted header parameter the way browsers do.
+ (NSString *)quoted:(NSString *)value {
    return [[[value stringByReplacingOccurrencesOfString:@"\"" withString:@"%22"]
        stringByReplacingOccurrencesOfString:@"\r"
                                  withString:@"%0D"]
        stringByReplacingOccurrencesOfString:@"\n"
                                  withString:@"%0A"];
}

@end
