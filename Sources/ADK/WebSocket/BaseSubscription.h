//
//  BaseSubscription.h
//  ADK
//

#import "../Types/ChannelTypes.h"
#import "EventEmitter.h"
#import "../Types/SocketTypes.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PresenceUnsubscribe)(void (^_Nullable done)(void));

@interface BaseSubscription : NSObject

@property(nonatomic, copy, readonly) NSString *connectionID;
@property(nonatomic, assign) BOOL isSubscribed;
@property(nonatomic, assign) BOOL isListening;
@property(nonatomic, weak) id<WebsocketHandler> websocketHandler;
@property(nonatomic, strong) ChannelConfig *channelConfig;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *>
        *messageBuffer;
@property(nonatomic, strong) NSArray<NSString *> *presenceUsers;
@property(nonatomic, strong, readonly) EventEmitter *emitter;

- (instancetype)initWithConnectionID:(NSString *)connectionID
                       channelConfig:(ChannelConfig *)channelConfig
                    websocketHandler:(id<WebsocketHandler>)websocketHandler
                             process:(NSString *)process
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)validateSubscription:(NSString *)process;
- (void)subscribe:(nullable void (^)(void))completion;
- (void)unsubscribe:(nullable void (^)(void))completion;
- (void)reconnect;
- (void)fetchPresence:(BOOL)unique
             callback:(void (^)(NSArray<NSString *> *users))callback
           completion:(void (^)(PresenceUnsubscribe _Nullable unsubscribe,
                                NSError *_Nullable error))completion;

- (void)acknowledge:(NSDictionary<NSString *, id> *)request
         returnFlag:(NSString *)returnFlag;

- (void)handleMessageAcks:(NSString *)event
               returnFlag:(NSString *)returnFlag
                     data:(NSDictionary *)data;

- (void)push:(NSString *)event
          data:(NSDictionary<NSString *, id> *)data
       options:(nullable PushConfig *)options
    completion:(void (^)(NSError *_Nullable error))completion;

- (void)pushArray:(NSString *)event
             data:(NSArray<NSDictionary *> *)data
       completion:(void (^)(NSError *_Nullable error))completion;

- (void)handleMessage:(NSString *)event payload:(NSDictionary *)payload;

@end

NS_ASSUME_NONNULL_END
