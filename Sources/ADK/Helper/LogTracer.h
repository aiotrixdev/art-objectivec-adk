//
//  LogTracer.h
//  ADK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TraceLevel) {
    TraceLevelInfo = 0,
    TraceLevelDebug,
    TraceLevelWarn,
    TraceLevelError
};

@interface Tracer : NSObject

+ (void)log:(TraceLevel)level
    message:(NSString *)message
       meta:(nullable NSDictionary<NSString *, id> *)meta;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface LogTracer : NSObject

+ (void)log:(NSString *)message;

+ (void)printJSONData:(NSData *)data title:(nullable NSString *)title;

+ (void)printJSONString:(NSString *)jsonString title:(nullable NSString *)title;

+ (void)prettyPrintData:(NSData *)data title:(nullable NSString *)title;

/// Redact sensitive values (access_token, refresh_token, passcode,
/// Bearer headers, JWTs, `?token=…` query params) from a string
/// before logging so that crash reporters and log aggregators never
/// receive them.
+ (NSString *)redactSensitive:(nullable NSString *)input;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
