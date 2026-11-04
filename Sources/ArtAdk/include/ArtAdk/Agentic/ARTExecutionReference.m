//
//  ARTExecutionReference.m
//  ADK
//

#import "ARTExecutionReference.h"
#import "Utils.h"

NSString *ARTValidateExecutionReference(NSString *reference, NSError **error) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      // `\A` / `\z`: `$` would also accept a trailing newline.
      pattern = [NSRegularExpression
          regularExpressionWithPattern:@"\\A[a-z0-9]+(?:-[a-z0-9]+)*(?:@[a-z0-9]{1,64})?\\z"
                               options:0
                                 error:nil];
    });
    NSString *value = [reference isKindOfClass:[NSString class]] ? reference : @"";
    NSRange range = NSMakeRange(0, value.length);
    if ([pattern firstMatchInString:value options:0 range:range] != nil) {
        return reference;
    }
    if (error) {
        *error = MakeError(
            ErrorCodeInvalidArgument,
            [NSString stringWithFormat:@"Expected a lowercase slug or slug@buildname, got \"%@\"",
                                       value]);
    }
    return nil;
}
