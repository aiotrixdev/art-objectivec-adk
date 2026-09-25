//
//  ARTSupport.m
//  ADK
//

#import "ARTSupport.h"

#pragma mark - Logging

static ARTLogHandler _ARTLogHandler = nil;

NSString *ARTLogLevelName(ARTLogLevel level) {
    switch (level) {
    case ARTLogLevelDebug:
        return @"debug";
    case ARTLogLevelInfo:
        return @"info";
    case ARTLogLevelWarning:
        return @"warning";
    case ARTLogLevelError:
        return @"error";
    }
    return @"info";
}

@implementation ARTLog

+ (ARTLogHandler)handler {
    @synchronized(self) {
        return _ARTLogHandler;
    }
}

+ (void)setHandler:(ARTLogHandler)handler {
    @synchronized(self) {
        _ARTLogHandler = [handler copy];
    }
}

+ (void)log:(ARTLogLevel)level message:(NSString *)message {
    ARTLogHandler handler = self.handler;
    if (handler) {
        handler(level, message ?: @"");
    }
}

+ (void)debug:(NSString *)message {
    [self log:ARTLogLevelDebug message:message];
}

+ (void)info:(NSString *)message {
    [self log:ARTLogLevelInfo message:message];
}

+ (void)warn:(NSString *)message {
    [self log:ARTLogLevelWarning message:message];
}

+ (void)error:(NSString *)message {
    [self log:ARTLogLevelError message:message];
}

@end

#pragma mark - JSON

NSErrorDomain const ARTJSONErrorDomain = @"com.art.adk.json";

@implementation ARTJSON

+ (NSString *)stringify:(id)value error:(NSError **)error {
    // Wrapping in an array lets top-level strings, numbers and NSNull
    // pass validation, which would otherwise reject them.
    if (value == nil || ![NSJSONSerialization isValidJSONObject:@[ value ]]) {
        if (error) {
            NSString *message = [NSString
                stringWithFormat:@"Value is not JSON-serializable: %@",
                                 value ? NSStringFromClass([value class])
                                       : @"nil"];
            *error = [NSError errorWithDomain:ARTJSONErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : message
                                     }];
        }
        return nil;
    }

    NSData *data = [NSJSONSerialization
        dataWithJSONObject:value
                   options:NSJSONWritingFragmentsAllowed |
                           NSJSONWritingWithoutEscapingSlashes
                     error:error];
    if (!data) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
               ?: @"";
}

+ (id)parse:(NSString *)text {
    if (![text isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return data ? [self parseData:data] : nil;
}

+ (id)parseData:(NSData *)data {
    if (data.length == 0) {
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:data
                                           options:NSJSONReadingFragmentsAllowed
                                             error:nil];
}

+ (BOOL)isTruthy:(id)value {
    if (!value || value == [NSNull null]) {
        return NO;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value length] > 0;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value doubleValue] != 0;
    }
    return YES;
}

+ (NSNumber *)integerValue:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) {
        return @([(NSNumber *)value integerValue]);
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
        scanner.charactersToBeSkipped = nil;
        NSInteger parsed = 0;
        if ([scanner scanInteger:&parsed] && scanner.isAtEnd) {
            return @(parsed);
        }
    }
    return nil;
}

+ (NSString *)stringValue:(id)value {
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value length] > 0 ? (NSString *)value : nil;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return nil;
}

@end

#pragma mark - HTTP error details

NSErrorUserInfoKey const ARTHTTPStatusCodeKey = @"ARTHTTPStatusCode";
NSErrorUserInfoKey const ARTHTTPResponseBodyKey = @"ARTHTTPResponseBody";
NSErrorUserInfoKey const ARTHTTPEndpointKey = @"ARTHTTPEndpoint";
NSErrorUserInfoKey const ARTHTTPMessageKey = @"ARTHTTPMessage";

#pragma mark - Wire encoding

static NSString *const ARTAlphanumerics =
    @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

@implementation ARTEncoding

+ (NSCharacterSet *)uriComponentAllowed {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      set = [NSCharacterSet
          characterSetWithCharactersInString:
              [ARTAlphanumerics stringByAppendingString:@"-_.!~*'()"]];
    });
    return set;
}

+ (NSCharacterSet *)formAllowed {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      set = [NSCharacterSet
          characterSetWithCharactersInString:
              [ARTAlphanumerics stringByAppendingString:@"*-._ "]];
    });
    return set;
}

+ (NSString *)uriComponent:(NSString *)value {
    return [value stringByAddingPercentEncodingWithAllowedCharacters:
                      [self uriComponentAllowed]]
               ?: value;
}

+ (NSString *)formComponent:(NSString *)value {
    NSString *encoded = [value stringByAddingPercentEncodingWithAllowedCharacters:
                                   [self formAllowed]]
                            ?: value;
    return [encoded stringByReplacingOccurrencesOfString:@" " withString:@"+"];
}

+ (NSString *)formQueryWithPairs:(NSArray<NSArray<NSString *> *> *)pairs {
    NSMutableArray<NSString *> *parts =
        [NSMutableArray arrayWithCapacity:pairs.count];
    for (NSArray<NSString *> *pair in pairs) {
        if (pair.count < 2) {
            continue;
        }
        [parts addObject:[NSString stringWithFormat:@"%@=%@",
                                                    [self formComponent:pair[0]],
                                                    [self formComponent:pair[1]]]];
    }
    return [parts componentsJoinedByString:@"&"];
}

+ (NSString *)formQueryWithDictionary:
    (NSDictionary<NSString *, NSString *> *)params {
    NSMutableArray<NSArray<NSString *> *> *pairs = [NSMutableArray array];
    for (NSString *key in
         [params.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id value = params[key];
        NSString *text = [value isKindOfClass:[NSString class]]
                             ? (NSString *)value
                             : [value description];
        [pairs addObject:@[ key, text ?: @"" ]];
    }
    return [self formQueryWithPairs:pairs];
}

+ (NSString *)isoTimestamp {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                              NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:[NSDate date]];
}

@end
