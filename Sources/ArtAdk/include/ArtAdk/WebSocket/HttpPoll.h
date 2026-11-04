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

/// HTTP long-poll transport used when the WebSocket connection is
/// unavailable.
///
/// A failed poll is reported to `onError`, as an `ARTAuthHttpError` for an
/// HTTP error. The loop stops when the server rejects the credentials (HTTP
/// 401 or 403), whether while `getAuthHeaders` gets a token or on the poll
/// itself.
@interface LongPollClient : NSObject

@property (nonatomic, assign, readonly) BOOL isRunning;

- (instancetype)initWithOptions:(LongPollOptions *)opts NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start:(nullable NSString *)connectionId;

- (void)stop;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_HTTPPOLL_H */
