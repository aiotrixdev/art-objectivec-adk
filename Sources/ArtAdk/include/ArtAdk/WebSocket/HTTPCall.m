//
//  HTTPCall.m
//  ADK
//

#import "HTTPCall.h"
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
                      appendFormat:@"?%@", [ARTEncoding formQueryWithDictionary:
                                                            opts.queryParams]];
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

              if (opts.payload) {
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

              NSURLSessionDataTask *task = [self.session
                  dataTaskWithRequest:request
                    completionHandler:^(NSData *data, NSURLResponse *response,
                                        NSError *networkError) {
                      if (networkError) {
                          completion(nil, networkError);
                          return;
                      }
                      NSHTTPURLResponse *http =
                          [response isKindOfClass:[NSHTTPURLResponse class]]
                              ? (NSHTTPURLResponse *)response
                              : nil;
                      if (!http) {
                          completion(nil,
                                     MakeError(ErrorCodeServerError,
                                               [NSString stringWithFormat:
                                                             @"No HTTP response "
                                                             @"for %@",
                                                             endpoint]));
                          return;
                      }

                      if (http.statusCode < 200 || http.statusCode >= 300) {
                          completion(nil, [self errorForEndpoint:endpoint
                                                          status:http.statusCode
                                                            data:data]);
                          return;
                      }

                      // 204 No Content / empty body
                      if (http.statusCode == 204 || data.length == 0) {
                          completion(nil, nil);
                          return;
                      }

                      NSError *parseErr = nil;
                      id json = [NSJSONSerialization
                          JSONObjectWithData:data
                                     options:NSJSONReadingFragmentsAllowed
                                       error:&parseErr];
                      if (!json) {
                          completion(nil, parseErr
                                              ?: MakeError(ErrorCodeServerError,
                                                           @"Invalid JSON "
                                                           @"response"));
                          return;
                      }
                      completion(json, nil);
                    }];
              [task resume];
            }];
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
