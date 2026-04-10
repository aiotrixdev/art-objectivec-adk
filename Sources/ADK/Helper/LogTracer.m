//
//  LogTracer.m
//  ADK
//

#import "LogTracer.h"

static NSString *TraceLevelString(TraceLevel level) {
    switch (level) {
    case TraceLevelInfo:
        return @"INFO";
    case TraceLevelDebug:
        return @"DEBUG";
    case TraceLevelWarn:
        return @"WARN";
    case TraceLevelError:
        return @"ERROR";
    }
    return @"INFO";
}

@implementation Tracer

+ (void)log:(TraceLevel)level
    message:(NSString *)message
       meta:(NSDictionary<NSString *, id> *)meta {

    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      formatter = [[NSISO8601DateFormatter alloc] init];
    });

    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *metaString =
        (meta.count > 0) ? [NSString stringWithFormat:@" | %@", meta] : @"";

    NSLog(@"[%@] [%@] %@%@", timestamp, TraceLevelString(level), message,
          metaString);
}

@end

@implementation LogTracer

// Lazy compiled redaction patterns. Any of these matching inside a log
// message will be replaced with "<REDACTED>" before the message is
// written to NSLog. This protects against JWTs, access tokens,
// refresh tokens, passcodes, Bearer headers, and client secrets ever
// landing in a crash reporter or log aggregator.
+ (NSArray<NSRegularExpression *> *)redactionPatterns {
    static NSArray<NSRegularExpression *> *patterns = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      NSMutableArray *arr = [NSMutableArray array];
      // Build the JSON-key pattern in a local to avoid the
      // -Wobjc-string-concatenation warning inside an NSArray literal.
      NSString *jsonKeyPattern =
          @"\"(access_token|refresh_token|passcode|token|public_key|private_key|Client-Secret|ClientSecret|X-pass|T-pass|Authorization|Bearer)\"\\s*:\\s*\"[^\"]*\"";
      NSArray<NSString *> *raw = @[
          jsonKeyPattern,
          // Query parameter: ?token=... or &access_token=...
          @"([?&])(token|access_token|refresh_token|passcode)=[^&\\s\"]*",
          // HTTP Authorization header: Bearer <value>
          @"(?i)Bearer\\s+[A-Za-z0-9._~+/=\\-]+",
          // Bare JWT pattern (header.payload.signature, each base64url)
          @"\\beyJ[A-Za-z0-9_\\-]+\\.[A-Za-z0-9_\\-]+\\.[A-Za-z0-9_\\-]+\\b",
      ];
      for (NSString *pat in raw) {
          NSError *err = nil;
          NSRegularExpression *re =
              [NSRegularExpression regularExpressionWithPattern:pat
                                                        options:0
                                                          error:&err];
          if (re) {
              [arr addObject:re];
          }
      }
      patterns = [arr copy];
    });
    return patterns;
}

+ (NSString *)redactSensitive:(nullable NSString *)input {
    if (input.length == 0) {
        return input ?: @"";
    }
    NSMutableString *result = [input mutableCopy];
    for (NSRegularExpression *re in [self redactionPatterns]) {
        NSString *template;
        if ([re.pattern hasPrefix:@"([?&])"]) {
            // Preserve the separator and key so URLs remain parseable.
            template = @"$1$2=<REDACTED>";
        } else {
            template = @"<REDACTED>";
        }
        [re replaceMatchesInString:result
                           options:0
                             range:NSMakeRange(0, result.length)
                      withTemplate:template];
    }
    return [result copy];
}

+ (void)log:(NSString *)message {
#ifdef DEBUG
    NSLog(@"%@", [self redactSensitive:message]);
#endif
}

+ (void)printJSONData:(NSData *)data title:(NSString *)title {
#ifdef DEBUG
    if (title) {
        NSLog(@"%@", title);
    }

    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:&error];
    if (error) {
        NSLog(@"Failed to pretty print JSON: %@", error.localizedDescription);
        return;
    }

    NSData *prettyData =
        [NSJSONSerialization dataWithJSONObject:object
                                        options:NSJSONWritingPrettyPrinted
                                          error:&error];
    if (error) {
        NSLog(@"Failed to serialize JSON: %@", error.localizedDescription);
        return;
    }

    NSString *prettyString =
        [[NSString alloc] initWithData:prettyData
                              encoding:NSUTF8StringEncoding];
    if (prettyString) {
        NSLog(@"%@", [self redactSensitive:prettyString]);
    }
    NSLog(@" ");
#endif
}

+ (void)printJSONString:(NSString *)jsonString title:(NSString *)title {
#ifdef DEBUG
    if (title) {
        NSLog(@"%@:", title);
    }

    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        NSLog(@"Invalid JSON String");
        return;
    }

    [self prettyPrintData:data title:nil];
    NSLog(@" ");
#endif
}

+ (void)prettyPrintData:(NSData *)data title:(NSString *)title {
#ifdef DEBUG
    if (title) {
        NSLog(@"%@", title);
    }

    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:&error];
    if (error) {
        NSLog(@" Failed to pretty print Data: %@", error.localizedDescription);
        return;
    }

    NSData *prettyData =
        [NSJSONSerialization dataWithJSONObject:object
                                        options:NSJSONWritingPrettyPrinted
                                          error:&error];
    if (error) {
        NSLog(@" Failed to serialize Data: %@", error.localizedDescription);
        return;
    }

    NSString *prettyString =
        [[NSString alloc] initWithData:prettyData
                              encoding:NSUTF8StringEncoding];
    if (prettyString) {
        NSLog(@"%@", [self redactSensitive:prettyString]);
    }
    NSLog(@" ");
#endif
}

@end
