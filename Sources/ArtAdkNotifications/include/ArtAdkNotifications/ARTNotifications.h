#ifndef ARTADK_NOTIFICATIONS_ARTNOTIFICATIONS_H
#define ARTADK_NOTIFICATIONS_ARTNOTIFICATIONS_H

#pragma once

//
//  ARTNotifications.h
//  ADK
//
//  Optional notifications add-on (CocoaPods: `pod 'ArtAdk/Notifications'`).
//
//      ARTNotificationsApi *inbox =
//          [adk use:[ARTNotificationsPlugin pluginWithOptions:nil]];
//      [inbox onNew:^(ARTNotification *n) { ... }             // live
//        completion:^(void (^stop)(void), NSError *error) { ... }];
//      [inbox list:nil completion:^(ARTNotificationPage *page,
//                                   NSError *error) { ... }]; // history
//      [inbox markRead:@[ notificationId ] completion:nil];
//
//  The add-on has no connection of its own: it uses the host Adk's
//  connection, REST client and credentials.
//

#import <ArtAdk/WebSocket/ARTPlugin.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Models

/// Read state of a notification.
typedef NSString *ARTNotificationStatus NS_TYPED_EXTENSIBLE_ENUM;
FOUNDATION_EXPORT ARTNotificationStatus const ARTNotificationStatusUnread;
FOUNDATION_EXPORT ARTNotificationStatus const ARTNotificationStatusRead;
FOUNDATION_EXPORT ARTNotificationStatus const ARTNotificationStatusArchived;

/// How a notification is delivered.
typedef NSString *ARTNotificationChannel NS_TYPED_ENUM;
FOUNDATION_EXPORT ARTNotificationChannel const ARTNotificationChannelInApp;
FOUNDATION_EXPORT ARTNotificationChannel const ARTNotificationChannelEmail;

/// A notification delivered live or listed from history.
@interface ARTNotification : NSObject

@property(nonatomic, copy, readonly) NSString *notificationId;
@property(nonatomic, copy, readonly) NSString *type;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly) NSString *body;
@property(nonatomic, copy, readonly, nullable) NSDictionary<NSString *, id> *data;
/// `unread`, `read` or `archived` (the raw server value).
@property(nonatomic, copy, readonly) ARTNotificationStatus status;
@property(nonatomic, copy, readonly) NSString *createdAt;

- (instancetype)initWithNotificationId:(NSString *)notificationId
                                  type:(NSString *)type
                                 title:(NSString *)title
                                  body:(NSString *)body
                                  data:(nullable NSDictionary<NSString *, id> *)data
                                status:(ARTNotificationStatus)status
                             createdAt:(NSString *)createdAt
    NS_DESIGNATED_INITIALIZER;
/// Parses a notification from its server fields.
- (instancetype)initWithMap:(NSDictionary *)map;
- (instancetype)init NS_UNAVAILABLE;

@end

/// Add-on options.
@interface ARTNotificationsOptions : NSObject
/// Gateway origin for the REST API. Defaults to the ADK gateway origin
/// (where `/api/<tenant>/...` lives).
@property(nonatomic, copy, nullable) NSString *apiBaseUrl;
@end

/// Filters for `list:completion:`.
@interface ARTNotificationListParams : NSObject
@property(nonatomic, copy, nullable) ARTNotificationStatus status;
@property(nonatomic, strong, nullable) NSNumber *page;
@property(nonatomic, strong, nullable) NSNumber *limit;
@end

/// One page of notifications.
@interface ARTNotificationPage : NSObject
@property(nonatomic, copy, readonly) NSArray<ARTNotification *> *notifications;
@property(nonatomic, assign, readonly) NSInteger total;
- (instancetype)initWithNotifications:(NSArray<ARTNotification *> *)notifications
                                total:(NSInteger)total NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Input for `send:completion:`.
@interface ARTSendNotificationInput : NSObject
@property(nonatomic, copy) NSArray<NSString *> *recipients;
@property(nonatomic, copy) NSString *type;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *body;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *data;
/// Delivery channels (sent as `notify_channels`); nil means in-app only.
@property(nonatomic, copy, nullable) NSArray<ARTNotificationChannel> *channels;
@property(nonatomic, copy, nullable) NSString *dedupKey;

- (instancetype)initWithRecipients:(NSArray<NSString *> *)recipients
                              type:(NSString *)type
                             title:(NSString *)title
                              body:(NSString *)body NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Result of `send:completion:`.
@interface ARTSendNotificationResult : NSObject
@property(nonatomic, assign, readonly) NSInteger created;
@property(nonatomic, assign, readonly) NSInteger skipped;
- (instancetype)initWithCreated:(NSInteger)created
                        skipped:(NSInteger)skipped NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

#pragma mark - API

/// Notifications API returned by `-[Adk use:]`.
@interface ARTNotificationsApi : NSObject

- (instancetype)initWithContext:(ARTAdkPluginContext *)context
                        options:(nullable ARTNotificationsOptions *)options
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Subscribes to live notifications (`notification.new` on the
/// `art_notifications` channel). `completion` returns a block that stops
/// them.
- (void)onNew:(void (^)(ARTNotification *notification))callback
    completion:(void (^)(void (^_Nullable stop)(void),
                         NSError *_Nullable error))completion;

/// Lists notifications (history).
- (void)list:(nullable ARTNotificationListParams *)params
    completion:(void (^)(ARTNotificationPage *_Nullable page,
                         NSError *_Nullable error))completion;

/// Number of unread notifications.
- (void)unreadCount:(void (^)(NSInteger count, NSError *_Nullable error))completion;

/// Marks the given notifications read, or every unread one when `ids` is
/// nil or empty. Completes with the number changed.
- (void)markRead:(nullable NSArray<NSString *> *)ids
      completion:(nullable void (^)(NSInteger modified,
                                    NSError *_Nullable error))completion;

/// Sends a notification to one or more recipients (checked on the server).
- (void)send:(ARTSendNotificationInput *)input
    completion:(nullable void (^)(ARTSendNotificationResult *_Nullable result,
                                  NSError *_Nullable error))completion;

@end

#pragma mark - Plugin

/// Installs the notifications add-on with `-[Adk use:]`. Its name is
/// `notifications`.
@interface ARTNotificationsPlugin : NSObject <ARTAdkPlugin>

@property(nonatomic, strong, readonly, nullable) ARTNotificationsOptions *options;

+ (instancetype)pluginWithOptions:(nullable ARTNotificationsOptions *)options;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_NOTIFICATIONS_ARTNOTIFICATIONS_H */
