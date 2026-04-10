//
//  Constant.h
//  ADK
//

#import <Foundation/Foundation.h>

@interface Constant : NSObject

@property(class, nonatomic, copy) NSString *ROOT;
@property(class, nonatomic, copy) NSString *CONFIG_FILE_NAME;
@property(class, nonatomic, copy) NSString *BASE_URL;
@property(class, nonatomic, copy) NSString *WS_URL;
@property(class, nonatomic, copy) NSString *SSE_URL;
@property(class, nonatomic, copy) NSString *LPOLL;
@property(class, nonatomic, copy) NSString *CONFIG_JSON_PATH;

- (instancetype)init NS_UNAVAILABLE;

@end
