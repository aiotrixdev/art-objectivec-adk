#ifndef ARTADK_UTIL_ARTSUPPORT_H
#define ARTADK_UTIL_ARTSUPPORT_H

#pragma once

//
//  ARTSupport.h
//  ADK
//
//  Small helpers shared across the SDK: opt-in logging, JSON encoding
//  that never raises, and the URL encodings the server expects.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Logging

/// Severity of an SDK diagnostic message.
typedef NS_ENUM(NSInteger, ARTLogLevel) {
    ARTLogLevelDebug,
    ARTLogLevelInfo,
    ARTLogLevelWarning,
    ARTLogLevelError,
};

/// Receives SDK diagnostics.
typedef void (^ARTLogHandler)(ARTLogLevel level, NSString *message);

/// Opt-in sink for SDK diagnostics (unknown agent events, superseded runs,
/// failed subscriptions, missing configuration). Silent by default.
///
///     ARTLog.handler = ^(ARTLogLevel level, NSString *message) {
///         NSLog(@"[ART][%@] %@", ARTLogLevelName(level), message);
///     };
@interface ARTLog : NSObject

@property(class, nonatomic, copy, nullable) ARTLogHandler handler;

+ (void)debug:(NSString *)message;
+ (void)info:(NSString *)message;
+ (void)warn:(NSString *)message;
+ (void)error:(NSString *)message;

- (instancetype)init NS_UNAVAILABLE;

@end

/// `debug`, `info`, `warning` or `error`.
FOUNDATION_EXPORT NSString *ARTLogLevelName(ARTLogLevel level);

// Internal: format the message only when a handler is installed.
#define ARTLogDebug(...)                                                       \
    do {                                                                       \
        if (ARTLog.handler)                                                    \
            [ARTLog debug:[NSString stringWithFormat:__VA_ARGS__]];            \
    } while (0)
#define ARTLogInfo(...)                                                        \
    do {                                                                       \
        if (ARTLog.handler)                                                    \
            [ARTLog info:[NSString stringWithFormat:__VA_ARGS__]];             \
    } while (0)
#define ARTLogWarn(...)                                                        \
    do {                                                                       \
        if (ARTLog.handler)                                                    \
            [ARTLog warn:[NSString stringWithFormat:__VA_ARGS__]];             \
    } while (0)
#define ARTLogError(...)                                                       \
    do {                                                                       \
        if (ARTLog.handler)                                                    \
            [ARTLog error:[NSString stringWithFormat:__VA_ARGS__]];            \
    } while (0)

#pragma mark - JSON

/// Error domain for values that can't be encoded as JSON.
FOUNDATION_EXPORT NSErrorDomain const ARTJSONErrorDomain;

/// JSON helpers. `NSJSONSerialization` raises an Objective-C exception for
/// values it can't encode, so every value is validated first and a failure
/// is reported as an `NSError` instead.
@interface ARTJSON : NSObject

/// Compact JSON text for any JSON-compatible value, including top-level
/// strings, numbers and `NSNull`. Returns nil and sets `error` (domain
/// `ARTJSONErrorDomain`) when the value can't be encoded.
+ (nullable NSString *)stringify:(id)value error:(NSError **)error;

/// Decodes JSON text (top-level strings and numbers allowed); nil when the
/// text isn't JSON.
+ (nullable id)parse:(NSString *)text;

/// Decodes JSON data (top-level strings and numbers allowed); nil when the
/// data isn't JSON.
+ (nullable id)parseData:(NSData *)data;

/// JSON truthiness: nil, `NSNull`, empty strings and zero are false;
/// everything else is true.
+ (BOOL)isTruthy:(nullable id)value;

/// A number, or a string holding an integer, as an `NSNumber`; nil
/// otherwise.
+ (nullable NSNumber *)integerValue:(nullable id)value;

/// A non-empty string, or a number's string form; nil otherwise.
+ (nullable NSString *)stringValue:(nullable id)value;

- (instancetype)init NS_UNAVAILABLE;

@end

#pragma mark - HTTP error details

/// `userInfo` keys on errors from REST calls (`-[Adk callEndpoint:...]`,
/// storage, profile and plugin calls) that got a non-2xx response.
/// The HTTP status code, as an `NSNumber`.
FOUNDATION_EXPORT NSErrorUserInfoKey const ARTHTTPStatusCodeKey;
/// The decoded JSON error body, when there was one.
FOUNDATION_EXPORT NSErrorUserInfoKey const ARTHTTPResponseBodyKey;
/// The endpoint path that was called.
FOUNDATION_EXPORT NSErrorUserInfoKey const ARTHTTPEndpointKey;
/// The server's `message`, else the JSON error body, else the status text.
FOUNDATION_EXPORT NSErrorUserInfoKey const ARTHTTPMessageKey;

#pragma mark - Wire encoding

@interface ARTEncoding : NSObject

/// Percent-encodes everything except letters, digits and `-_.!~*'()`.
+ (NSString *)uriComponent:(NSString *)value;

/// Form-encodes a single query key or value (space becomes `+`).
+ (NSString *)formComponent:(NSString *)value;

/// Form-encoded query string (`a=1&b=2`) from `@[key, value]` pairs, in
/// the order given.
+ (NSString *)formQueryWithPairs:(NSArray<NSArray<NSString *> *> *)pairs;

/// Form-encoded query string with keys sorted, so URLs are deterministic.
+ (NSString *)formQueryWithDictionary:
    (NSDictionary<NSString *, NSString *> *)params;

/// ISO 8601 timestamp with milliseconds, e.g. `2026-09-25T10:02:31.220Z`.
+ (NSString *)isoTimestamp;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_UTIL_ARTSUPPORT_H */
