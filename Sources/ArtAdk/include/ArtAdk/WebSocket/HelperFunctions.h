#ifndef ARTADK_WEBSOCKET_HELPERFUNCTIONS_H
#define ARTADK_WEBSOCKET_HELPERFUNCTIONS_H

#pragma once

//
//  HelperFunctions.h
//  ADK
//

#import <ArtAdk/Types/ChannelTypes.h>
#import <ArtAdk/Types/SocketTypes.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HelperFunctions : NSObject

+ (void)subscribeToChannel:(NSString *)channel
                   process:(NSString *)process
          websocketHandler:(id<WebsocketHandler>)handler
                completion:(void (^)(ChannelConfig *_Nullable config,
                                     NSError *_Nullable error))completion;

+ (void)unsubscribeFromChannel:(NSString *)channel
                subscriptionID:(NSString *)subscriptionID
                       process:(NSString *)process
              websocketHandler:(id<WebsocketHandler>)handler
                    completion:(void (^)(BOOL success,
                                         NSError *_Nullable error))completion;

+ (void)getInterceptorConfig:(NSString *)interceptor
            websocketHandler:(id<WebsocketHandler>)handler
                  completion:(void (^)(id _Nullable config,
                                       NSError *_Nullable error))completion;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_HELPERFUNCTIONS_H */
