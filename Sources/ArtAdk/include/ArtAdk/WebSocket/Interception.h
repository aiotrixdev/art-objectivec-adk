#ifndef ARTADK_WEBSOCKET_INTERCEPTION_H
#define ARTADK_WEBSOCKET_INTERCEPTION_H

#pragma once

//
//  Interception.h
//  ADK
//

#import "EventEmitter.h"
#import <ArtAdk/Types/SocketTypes.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^InterceptorResolve)(id data);

typedef void (^InterceptorReject)(NSString *error);

typedef void (^InterceptorFn)(NSDictionary *request, InterceptorResolve resolve,
                              InterceptorReject reject);

@interface Interception : NSObject

@property(nonatomic, strong, readonly) EventEmitter *emitter;

- (instancetype)initWithInterceptor:(NSString *)interceptor
                                 fn:(InterceptorFn)fn
                   websocketHandler:(id<WebsocketHandler>)websocketHandler
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)validateInterception:
    (void (^)(NSError *_Nullable error))completion;

- (void)reconnect;

- (void)handleMessage:(NSString *)channel data:(NSDictionary *)data;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_INTERCEPTION_H */
