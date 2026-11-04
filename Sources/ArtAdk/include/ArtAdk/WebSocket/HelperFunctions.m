//
//  HelperFunctions.m
//  ADK
//

#import "HelperFunctions.h"
#import "ARTSupport.h"
#import "Utils.h"
#import "AuthTypes.h"

/// The server's `error` text, else `fallback`.
static NSString *ARTRejection(NSDictionary *data, NSString *fallback) {
    id error = data[@"error"];
    return ([error isKindOfClass:[NSString class]] && [(NSString *)error length] > 0)
               ? error
               : fallback;
}

@implementation HelperFunctions

+ (void)subscribeToChannel:(NSString *)channel
                   process:(NSString *)process
          websocketHandler:(id<WebsocketHandler>)handler
                completion:(void (^)(ChannelConfig *_Nullable,
                                     NSError *_Nullable))completion {
    if (!handler) {
        completion(nil, MakeError(ErrorCodeNotConnected, @"Not connected"));
        return;
    }

    [handler wait:^(NSError *_Nullable waitError) {
      if (waitError) {
          completion(nil, waitError);
          return;
      }
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
                       completion(
                           nil,
                           MakeError(ErrorCodeServerError,
                                     ARTRejection(data, @"The channel subscription "
                                                        @"was rejected.")));
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
                   // Orchestrator-enabled channels report it as
                   // `IsInterceptorEnabled`.
                   id orchestrator = rawData[@"IsInterceptorEnabled"];
                   config.orchestratorEnabled =
                       [orchestrator isKindOfClass:[NSNumber class]] &&
                       [(NSNumber *)orchestrator boolValue];
                   config.configurationID =
                       [ARTJSON stringValue:data[@"configurationID"]];
                   completion(config, nil);
                 }];
    }];
}

+ (void)unsubscribeFromChannel:(NSString *)channel
                subscriptionID:(NSString *)subscriptionID
                       process:(NSString *)process
              websocketHandler:(id<WebsocketHandler>)handler
                    completion:(void (^)(BOOL, NSError *_Nullable))completion {
    if (!handler) {
        completion(NO, MakeError(ErrorCodeNotConnected, @"Not connected"));
        return;
    }

    [handler wait:^(NSError *_Nullable waitError) {
      if (waitError) {
          completion(NO, waitError);
          return;
      }
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
                       completion(NO,
                                  MakeError(ErrorCodeServerError,
                                            ARTRejection(data, @"The channel request "
                                                               @"was rejected.")));
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
    if (!handler) {
        completion(nil, MakeError(ErrorCodeNotConnected, @"Not connected"));
        return;
    }

    [handler wait:^(NSError *_Nullable waitError) {
      if (waitError) {
          completion(nil, waitError);
          return;
      }
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
                       completion(
                           nil,
                           MakeError(ErrorCodeServerError,
                                     ARTRejection(data, @"The interceptor subscription "
                                                        @"was rejected.")));
                       return;
                   }

                   completion(data[@"interceptorConfig"], nil);
                 }];
    }];
}

@end
