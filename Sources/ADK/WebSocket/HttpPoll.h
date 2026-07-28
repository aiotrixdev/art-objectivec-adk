#ifndef ARTADK_WEBSOCKET_HTTPPOLL_H
#define ARTADK_WEBSOCKET_HTTPPOLL_H

#pragma once

//
//  LongPollClient.h
//  ADK
//


#import <Foundation/Foundation.h>
#import <ArtAdk/Types/SocketTypes.h>
NS_ASSUME_NONNULL_BEGIN

@interface LongPollClient : NSObject

@property (nonatomic, assign, readonly) BOOL isRunning;

- (instancetype)initWithOptions:(LongPollOptions *)opts NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start:(nullable NSString *)connectionId;

- (void)stop;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_HTTPPOLL_H */
