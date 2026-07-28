//
//  HelperFunctions.m
//  ADK
//

#import "HelperFunctions.h"
#import "Utils.h"
#import "AuthTypes.h"

@implementation HelperFunctions

+ (void)subscribeToChannel:(NSString *)channel
                   process:(NSString *)process
          websocketHandler:(id<WebsocketHandler>)handler
                completion:(void (^)(ChannelConfig *_Nullable,
                                     NSError *_Nullable))completion {

    [handler wait:^{
      NSString *subscriptionChannelName = [process isEqualToString:@"subscribe"]
                                              ? @"channel-subscribe"
                                              : @"channel-presence";

      [handler
          pushForSecureLine:subscriptionChannelName
                       data:@{@"channel" : channel}
                     listen:YES
                 completion:^(id _Nullable result,
                              NSError *_Nullable pushError) {
                   if (pushError) {
                       completion(nil, pushError);
                       return;
                   }

                   if (!result) {
                       completion(nil,
                                  MakeError(ErrorCodeChannelNotFound, channel));
                       return;
                   }

                   NSDictionary *wrapper = nil;
                   if ([result isKindOfClass:[NSDictionary class]]) {
                       wrapper = (NSDictionary *)result;
                   }

                   NSDictionary *data = wrapper[@"data"];
                   if (![data isKindOfClass:[NSDictionary class]]) {
                       completion(
                           nil, MakeError(ErrorCodeServerError,
                                          @"Invalid subscribe response shape"));
                       return;
                   }

                   NSString *status = data[@"status"];
                   if ([status isKindOfClass:[NSString class]] &&
                       [status isEqualToString:@"not-OK"]) {
                       NSString *errMsg = data[@"error"];
                       if (![errMsg isKindOfClass:[NSString class]])
                           errMsg = @"Unknown error";
                       completion(nil, MakeError(ErrorCodeServerError, errMsg));
                       return;
                   }

                   NSDictionary *rawData = data[@"channelConfig"];
                   if (![rawData isKindOfClass:[NSDictionary class]]) {
                       completion(nil,
                                  MakeError(ErrorCodeChannelNotFound, channel));
                       return;
                   }

                   id snapshot = data[@"snapshot"];
                   NSArray *presenceUsers = data[@"presenceUsers"];
                   if (![presenceUsers isKindOfClass:[NSArray class]])
                       presenceUsers = @[];

                   NSString *channelName = data[@"channel"];
                   if (![channelName isKindOfClass:[NSString class]])
                       channelName = channel;

                   NSString *channelNamespace = data[@"channelNamespace"];
                   if (![channelNamespace isKindOfClass:[NSString class]])
                       channelNamespace = @"";

                   NSString *subscriptionID = data[@"subscriptionID"];
                   if (![subscriptionID isKindOfClass:[NSString class]])
                       subscriptionID = nil;

                   NSString *channelType = rawData[@"TypeofChannel"];
                   if (![channelType isKindOfClass:[NSString class]])
                       channelType = @"default";

                   ChannelConfig *config = [[ChannelConfig alloc]
                       initWithChannelName:channelName
                          channelNamespace:channelNamespace
                               channelType:channelType
                             presenceUsers:presenceUsers
                                  snapshot:snapshot
                            subscriptionID:subscriptionID];
                   completion(config, nil);
                 }];
    }];
}

+ (void)unsubscribeFromChannel:(NSString *)channel
                subscriptionID:(NSString *)subscriptionID
                       process:(NSString *)process
              websocketHandler:(id<WebsocketHandler>)handler
                    completion:(void (^)(BOOL, NSError *_Nullable))completion {

    [handler wait:^{
      NSString *channelName = [process isEqualToString:@"subscribe"]
                                  ? @"channel-unsubscribe"
                                  : @"presence-unsubscribe";

      [handler
          pushForSecureLine:channelName
                       data:@{
                           @"channel" : channel,
                           @"subscriptionID" : subscriptionID
                       }
                     listen:YES
                 completion:^(id _Nullable result,
                              NSError *_Nullable pushError) {
                   if (pushError) {
                       completion(NO, pushError);
                       return;
                   }

                   if (!result) {
                       completion(NO, nil);
                       return;
                   }

                   NSDictionary *wrapper = nil;
                   if ([result isKindOfClass:[NSDictionary class]]) {
                       wrapper = (NSDictionary *)result;
                   }

                   NSDictionary *data = wrapper[@"data"];
                   if (![data isKindOfClass:[NSDictionary class]]) {
                       completion(NO, nil);
                       return;
                   }

                   NSString *status = data[@"status"];
                   if ([status isKindOfClass:[NSString class]] &&
                       [status isEqualToString:@"not-OK"]) {
                       NSString *errMsg = data[@"error"];
                       if (![errMsg isKindOfClass:[NSString class]])
                           errMsg = @"Unknown error";
                       completion(NO, MakeError(ErrorCodeServerError, errMsg));
                       return;
                   }

                   completion(YES, nil);
                 }];
    }];
}

+ (void)getInterceptorConfig:(NSString *)interceptor
            websocketHandler:(id<WebsocketHandler>)handler
                  completion:
                      (void (^)(id _Nullable, NSError *_Nullable))completion {

    [handler wait:^{
      [handler
          pushForSecureLine:@"interceptor-subscribe"
                       data:@{@"interceptor" : interceptor}
                     listen:YES
                 completion:^(id _Nullable result,
                              NSError *_Nullable pushError) {
                   if (pushError) {
                       completion(nil, pushError);
                       return;
                   }

                   if (!result) {
                       completion(nil, nil);
                       return;
                   }

                   NSDictionary *wrapper = nil;
                   if ([result isKindOfClass:[NSDictionary class]]) {
                       wrapper = (NSDictionary *)result;
                   }

                   NSDictionary *data = wrapper[@"data"];
                   if (![data isKindOfClass:[NSDictionary class]]) {
                       completion(nil, nil);
                       return;
                   }

                   NSString *status = data[@"status"];
                   if ([status isKindOfClass:[NSString class]] &&
                       [status isEqualToString:@"not-OK"]) {
                       NSString *errMsg = data[@"error"];
                       if (![errMsg isKindOfClass:[NSString class]])
                           errMsg = @"Unknown error";
                       completion(nil, MakeError(ErrorCodeServerError, errMsg));
                       return;
                   }

                   completion(data[@"interceptorConfig"], nil);
                 }];
    }];
}

@end
