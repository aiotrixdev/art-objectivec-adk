#ifndef ARTADK_WEBSOCKET_BASESUBSCRIPTION_H
#define ARTADK_WEBSOCKET_BASESUBSCRIPTION_H

#pragma once

//
//  BaseSubscription.h
//  ADK
//

#import <ArtAdk/Types/ChannelTypes.h>
#import "EventEmitter.h"
#import <ArtAdk/Types/SocketTypes.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PresenceUnsubscribe)(void (^_Nullable done)(void));

@interface BaseSubscription : NSObject

@property(nonatomic, copy, readonly) NSString *connectionID;
@property(atomic, assign) BOOL isSubscribed;
@property(atomic, assign) BOOL isListening;
@property(nonatomic, weak) id<WebsocketHandler> websocketHandler;
@property(atomic, strong) ChannelConfig *channelConfig;
/// Snapshot of the buffered events that carry no thread id, keyed by event
/// name. Buffered events are delivered when a listener attaches.
@property(nonatomic, copy)
    NSDictionary<NSString *, NSArray<NSDictionary *> *> *messageBuffer;
@property(atomic, strong) NSArray<NSString *> *presenceUsers;
@property(nonatomic, strong, readonly) EventEmitter *emitter;
/// How long `push` waits for the server's delivery confirmation on targeted
/// channels, in milliseconds. Defaults to 50 000.
@property(atomic, assign) double ackTimeoutMs;

- (instancetype)initWithConnectionID:(NSString *)connectionID
                       channelConfig:(ChannelConfig *)channelConfig
                    websocketHandler:(id<WebsocketHandler>)websocketHandler
                             process:(NSString *)process
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)validateSubscription:(NSString *)process;
/// Refreshes the channel configuration from the server for `process`
/// (`subscribe` or `presence`), then calls `completion`.
- (void)validateSubscription:(NSString *)process
                  completion:(nullable void (^)(void))completion;
- (void)subscribe:(nullable void (^)(void))completion;
- (void)unsubscribe:(nullable void (^)(void))completion;
- (void)reconnect;

/// Delivers the channel's online users to `callback`, now and whenever
/// someone joins or leaves. With `unique`, a user connected more than once
/// is listed once. `completion` returns a block that stops the updates.
- (void)fetchPresence:(BOOL)unique
             callback:(void (^)(NSArray<NSString *> *users))callback
           completion:(void (^)(PresenceUnsubscribe _Nullable unsubscribe,
                                NSError *_Nullable error))completion;

/// Sends a delivery acknowledgement (`MA` or `CA`) on targeted and secure
/// channels.
- (void)acknowledge:(NSDictionary<NSString *, id> *)request
         returnFlag:(NSString *)returnFlag;

/// Completes the pending `push` whose `ref_id` matches a server `SA`
/// acknowledgement.
- (void)handleMessageAcks:(NSString *)event
               returnFlag:(NSString *)returnFlag
                     data:(NSDictionary *)data;

/// Sends an event on this channel.
///
/// On targeted channels the call completes once the server confirms
/// delivery, or with an `ErrorCodeAckTimeout` error after `ackTimeoutMs`.
- (void)push:(NSString *)event
          data:(NSDictionary<NSString *, id> *)data
       options:(nullable PushConfig *)options
    completion:(void (^)(NSError *_Nullable error))completion;

/// Same as `push:data:options:completion:`, also returning the SDK-generated
/// `ref_id` (nil on control channels, which aren't ref-tracked).
- (void)pushEvent:(NSString *)event
             data:(NSDictionary<NSString *, id> *)data
          options:(nullable PushConfig *)options
       completion:(void (^)(NSString *_Nullable refId,
                            NSError *_Nullable error))completion;

/// Sends a JSON array payload (used for shared-object `merge` batches).
- (void)pushArray:(NSString *)event
             data:(NSArray<NSDictionary *> *)data
       completion:(void (^)(NSError *_Nullable error))completion;

/// Queues an inbound frame. Frames are handled one at a time, in arrival
/// order, by `handleMessage:payload:completion:`.
- (void)enqueueEvent:(NSString *)event payload:(NSDictionary *)payload;

/// Handles one inbound frame. Subclasses override this or
/// `handleMessage:payload:completion:`.
- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload;

/// Handles one inbound frame and calls `completion` when done, including
/// after any asynchronous work such as decryption. The next queued frame
/// waits until then. The default calls `handleMessage:payload:`.
- (void)handleMessage:(NSString *)event
              payload:(NSDictionary *)payload
           completion:(void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_BASESUBSCRIPTION_H */
