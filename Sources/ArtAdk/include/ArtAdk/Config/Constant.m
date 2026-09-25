//
//  Constant.m
//  ADK
//

#import "Constant.h"

static NSString *_ROOT = @"/";
static NSString *_CONFIG_FILE_NAME = @"adk-services.json";
static NSString *_BASE_URL = @"";
static NSString *_WS_URL = @"/v1/connect";
static NSString *_SSE_URL = @"/v1/connect/sse";
static NSString *_LPOLL = @"/v1/longpoll";
static NSString *_CONFIG_JSON_PATH = @"/adk-services.json";

@implementation Constant

+ (NSString *)ROOT {
    return [_ROOT copy];
}

+ (void)setROOT:(NSString *)ROOT {
    _ROOT = [ROOT copy];
}

+ (NSString *)CONFIG_FILE_NAME {
    return [_CONFIG_FILE_NAME copy];
}

+ (void)setCONFIG_FILE_NAME:(NSString *)CONFIG_FILE_NAME {
    _CONFIG_FILE_NAME = [CONFIG_FILE_NAME copy];
}

+ (NSString *)BASE_URL {
    return [_BASE_URL copy];
}

+ (void)setBASE_URL:(NSString *)BASE_URL {
    _BASE_URL = [BASE_URL copy];
}

+ (NSString *)WS_URL {
    return [_WS_URL copy];
}

+ (void)setWS_URL:(NSString *)WS_URL {
    _WS_URL = [WS_URL copy];
}

+ (NSString *)SSE_URL {
    return [_SSE_URL copy];
}

+ (void)setSSE_URL:(NSString *)SSE_URL {
    _SSE_URL = [SSE_URL copy];
}

+ (NSString *)LPOLL {
    return [_LPOLL copy];
}

+ (void)setLPOLL:(NSString *)LPOLL {
    _LPOLL = [LPOLL copy];
}

+ (NSString *)CONFIG_JSON_PATH {
    return [_CONFIG_JSON_PATH copy];
}

+ (void)setCONFIG_JSON_PATH:(NSString *)CONFIG_JSON_PATH {
    _CONFIG_JSON_PATH = [CONFIG_JSON_PATH copy];
}

@end
