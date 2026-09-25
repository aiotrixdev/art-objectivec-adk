//
//  ARTNotifications.m
//  ADK
//

#import "ARTNotifications.h"
#import <ArtAdk/CRDT/Utils.h>
#import <ArtAdk/Types/AuthTypes.h>
#import <ArtAdk/Types/SocketTypes.h>
#import <ArtAdk/Util/ARTSupport.h>
#import <ArtAdk/WebSocket/Subscription.h>

static NSString *const ARTNotificationsChannel = @"art_notifications";
static NSString *const ARTNewNotificationEvent = @"notification.new";

ARTNotificationStatus const ARTNotificationStatusUnread = @"unread";
ARTNotificationStatus const ARTNotificationStatusRead = @"read";
ARTNotificationStatus const ARTNotificationStatusArchived = @"archived";

ARTDevicePlatform const ARTDevicePlatformAndroid = @"android";
ARTDevicePlatform const ARTDevicePlatformIOS = @"ios";
ARTDevicePlatform const ARTDevicePlatformWeb = @"web";

static NSString *_Nullable ARTNotificationString(id value) {
    return [ARTJSON stringValue:value];
}

static NSInteger ARTNotificationInt(id value) {
    return [ARTJSON integerValue:value].integerValue;
}

#pragma mark - Models

@implementation ARTNotification

- (instancetype)initWithNotificationId:(NSString *)notificationId
                                  type:(NSString *)type
                                 title:(NSString *)title
                                  body:(NSString *)body
                                  data:(NSDictionary<NSString *, id> *)data
                                status:(ARTNotificationStatus)status
                             createdAt:(NSString *)createdAt {
    self = [super init];
    if (self) {
        _notificationId = [notificationId copy] ?: @"";
        _type = [type copy] ?: @"";
        _title = [title copy] ?: @"";
        _body = [body copy] ?: @"";
        _data = [data copy];
        _status = [status copy] ?: ARTNotificationStatusUnread;
        _createdAt = [createdAt copy] ?: @"";
    }
    return self;
}

- (instancetype)initWithMap:(NSDictionary *)map {
    id data = map[@"data"];
    return [self
        initWithNotificationId:ARTNotificationString(map[@"id"]) ?: @""
                          type:ARTNotificationString(map[@"type"]) ?: @""
                         title:ARTNotificationString(map[@"title"]) ?: @""
                          body:ARTNotificationString(map[@"body"]) ?: @""
                          data:[data isKindOfClass:[NSDictionary class]] ? data : nil
                        status:ARTNotificationString(map[@"status"])
                                   ?: ARTNotificationStatusUnread
                     createdAt:ARTNotificationString(map[@"created_at"])
                                   ?: ARTNotificationString(map[@"createdAt"])
                                   ?: @""];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<ARTNotification %@ %@ \"%@\" %@>",
                                      self.notificationId, self.type, self.title,
                                      self.status];
}

@end

@implementation ARTNotificationsOptions
@end

@implementation ARTNotificationListParams
@end

@implementation ARTNotificationPage

- (instancetype)initWithNotifications:(NSArray<ARTNotification *> *)notifications
                                total:(NSInteger)total {
    self = [super init];
    if (self) {
        _notifications = [notifications copy] ?: @[];
        _total = total;
    }
    return self;
}

@end

@implementation ARTSendNotificationInput

- (instancetype)initWithRecipients:(NSArray<NSString *> *)recipients
                              type:(NSString *)type
                             title:(NSString *)title
                              body:(NSString *)body {
    self = [super init];
    if (self) {
        _recipients = [recipients copy] ?: @[];
        _type = [type copy] ?: @"";
        _title = [title copy] ?: @"";
        _body = [body copy] ?: @"";
    }
    return self;
}

@end

@implementation ARTSendNotificationResult

- (instancetype)initWithCreated:(NSInteger)created skipped:(NSInteger)skipped {
    self = [super init];
    if (self) {
        _created = created;
        _skipped = skipped;
    }
    return self;
}

@end

@implementation ARTRegisterDeviceInput

- (instancetype)initWithToken:(NSString *)token platform:(ARTDevicePlatform)platform {
    self = [super init];
    if (self) {
        _token = [token copy] ?: @"";
        _platform = [platform copy] ?: ARTDevicePlatformIOS;
    }
    return self;
}

@end

@implementation ARTPushDevice

- (instancetype)initWithMap:(NSDictionary *)map {
    self = [super init];
    if (self) {
        NSString * (^string)(NSString *) = ^NSString *(NSString *key) {
          id value = map[key];
          return [value isKindOfClass:[NSString class]] ? value : nil;
        };
        _deviceId = [ARTNotificationString(map[@"id"]) copy];
        _username = [string(@"username") copy] ?: @"";
        _token = [string(@"token") copy] ?: @"";
        _platform = [string(@"platform") copy] ?: @"";
        _provider = [string(@"provider") copy];
        _createdAt = [string(@"created_at") copy];
        _lastSeenAt = [string(@"last_seen_at") copy];
        _updatedAt = [string(@"updated_at") copy];
    }
    return self;
}

@end

@implementation ARTPushDeviceList

- (instancetype)initWithDevices:(NSArray<ARTPushDevice *> *)devices
                          total:(NSInteger)total {
    self = [super init];
    if (self) {
        _devices = [devices copy] ?: @[];
        _total = total;
    }
    return self;
}

@end

#pragma mark - API

/// `bind:` delivers the parsed `content`; a wrapped `{ content }` or
/// `{ data }` shape is accepted too.
static ARTNotification *_Nullable ARTNormalizeNotification(id payload) {
    if (![payload isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *dict = payload;
    NSDictionary *content = nil;
    if (ARTNotificationString(dict[@"id"]) || ARTNotificationString(dict[@"title"])) {
        content = dict;
    } else if ([dict[@"content"] isKindOfClass:[NSDictionary class]]) {
        content = dict[@"content"];
    } else if ([dict[@"data"] isKindOfClass:[NSDictionary class]]) {
        content = dict[@"data"];
    }
    if (!content || !ARTNotificationString(content[@"id"])) {
        return nil;
    }
    return [[ARTNotification alloc] initWithMap:content];
}

@interface ARTNotificationsApi ()
@property(nonatomic, strong) ARTAdkPluginContext *context;
@property(nonatomic, strong, nullable) ARTNotificationsOptions *options;
/// Cached live subscription. Guarded by @synchronized(self).
@property(nonatomic, strong, nullable) Subscription *subscription;
@end

@implementation ARTNotificationsApi

- (instancetype)initWithContext:(ARTAdkPluginContext *)context
                        options:(ARTNotificationsOptions *)options {
    self = [super init];
    if (self) {
        _context = context;
        _options = options;
    }
    return self;
}

#pragma mark Live

- (void)onNew:(void (^)(ARTNotification *))callback
    completion:(void (^)(void (^_Nullable)(void), NSError *_Nullable))completion {
    [self liveSubscription:^(Subscription *sub, NSError *error) {
      if (!sub) {
          completion(nil, error);
          return;
      }
      NSUUID *token = [sub bind:ARTNewNotificationEvent
                       callback:^(id payload) {
                         ARTNotification *notification =
                             ARTNormalizeNotification(payload);
                         if (notification) {
                             callback(notification);
                         }
                       }];
      __weak Subscription *weakSub = sub;
      completion(
          ^{
            [weakSub remove:ARTNewNotificationEvent identifier:token];
          },
          nil);
    }];
}

- (void)liveSubscription:(void (^)(Subscription *_Nullable,
                                   NSError *_Nullable))completion {
    Subscription *cached;
    @synchronized(self) {
        cached = self.subscription;
    }
    if (cached) {
        completion(cached, nil);
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self.context subscribe:ARTNotificationsChannel
                 completion:^(BaseSubscription *raw, NSError *error) {
                   if (error) {
                       completion(nil, error);
                       return;
                   }
                   if (![raw isKindOfClass:[Subscription class]]) {
                       completion(nil,
                                  MakeError(ErrorCodeServerError,
                                            [NSString stringWithFormat:
                                                          @"Channel %@ did not "
                                                          @"yield a Subscription",
                                                          ARTNotificationsChannel]));
                       return;
                   }
                   Subscription *sub = (Subscription *)raw;
                   typeof(self) strongSelf = weakSelf;
                   if (strongSelf) {
                       @synchronized(strongSelf) {
                           strongSelf.subscription = sub;
                       }
                   }
                   completion(sub, nil);
                 }];
}

#pragma mark History (REST)

- (void)list:(ARTNotificationListParams *)params
    completion:(void (^)(ARTNotificationPage *_Nullable,
                         NSError *_Nullable))completion {
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    if (params.status) {
        query[@"status"] = params.status;
    }
    if (params.page) {
        query[@"page"] = params.page.stringValue;
    }
    if (params.limit) {
        query[@"limit"] = params.limit.stringValue;
    }
    [self call:@"" devices:NO method:@"GET" query:query payload:nil
        completion:^(NSDictionary *data, NSError *error) {
          if (!data) {
              completion(nil, error);
              return;
          }
          NSMutableArray<ARTNotification *> *items = [NSMutableArray array];
          id raw = data[@"notifications"];
          if ([raw isKindOfClass:[NSArray class]]) {
              for (id item in (NSArray *)raw) {
                  if ([item isKindOfClass:[NSDictionary class]]) {
                      [items addObject:[[ARTNotification alloc] initWithMap:item]];
                  }
              }
          }
          completion([[ARTNotificationPage alloc]
                         initWithNotifications:items
                                         total:ARTNotificationInt(data[@"total"])],
                     nil);
        }];
}

- (void)unreadCount:(void (^)(NSInteger, NSError *_Nullable))completion {
    [self call:@"/unread-count" devices:NO method:@"GET" query:nil payload:nil
        completion:^(NSDictionary *data, NSError *error) {
          completion(data ? ARTNotificationInt(data[@"unread_count"]) : 0,
                     data ? nil : error);
        }];
}

- (void)markRead:(NSArray<NSString *> *)ids
      completion:(void (^)(NSInteger, NSError *_Nullable))completion {
    NSArray<NSString *> *list = ids ?: @[];
    [self call:@"/mark-read"
           devices:NO
            method:@"POST"
             query:nil
           payload:@{@"ids" : list, @"all" : @(list.count == 0)}
        completion:^(NSDictionary *data, NSError *error) {
          if (completion) {
              completion(data ? ARTNotificationInt(data[@"modified"]) : 0,
                         data ? nil : error);
          }
        }];
}

- (void)send:(ARTSendNotificationInput *)input
    completion:(void (^)(ARTSendNotificationResult *_Nullable,
                         NSError *_Nullable))completion {
    NSError *tenantError = nil;
    NSString *tenant = [self tenant:&tenantError];
    if (!tenant) {
        if (completion) {
            completion(nil, tenantError);
        }
        return;
    }
    NSMutableDictionary *payload = [@{
        @"tenant" : tenant,
        @"type" : input.type ?: @"",
        @"recipients" : input.recipients ?: @[],
        @"title" : input.title ?: @"",
        @"body" : input.body ?: @"",
    } mutableCopy];
    if (input.data) {
        payload[@"data"] = input.data;
    }
    // The service reads `notify_channels`; a `channels` key would be
    // ignored (in-app only).
    if (input.channels) {
        payload[@"notify_channels"] = input.channels;
    }
    if (input.dedupKey) {
        payload[@"dedup_key"] = input.dedupKey;
    }
    [self call:@"/notify" devices:NO method:@"POST" query:nil payload:payload
        completion:^(NSDictionary *data, NSError *error) {
          if (!completion) {
              return;
          }
          if (!data) {
              completion(nil, error);
              return;
          }
          completion([[ARTSendNotificationResult alloc]
                         initWithCreated:ARTNotificationInt(data[@"created"])
                                 skipped:ARTNotificationInt(data[@"skipped"])],
                     nil);
        }];
}

#pragma mark Push devices (REST)

- (void)registerDevice:(ARTRegisterDeviceInput *)input
            completion:(void (^)(ARTPushDevice *_Nullable,
                                 NSError *_Nullable))completion {
    NSMutableDictionary *payload = [@{
        @"token" : input.token ?: @"",
        @"platform" : input.platform ?: ARTDevicePlatformIOS,
    } mutableCopy];
    if (input.username.length > 0) {
        payload[@"username"] = input.username;
    }
    [self call:@"/register" devices:YES method:@"POST" query:nil payload:payload
        completion:^(NSDictionary *data, NSError *error) {
          if (!completion) {
              return;
          }
          if (!data) {
              completion(nil, error);
              return;
          }
          id device = data[@"device"];
          completion([device isKindOfClass:[NSDictionary class]]
                         ? [[ARTPushDevice alloc] initWithMap:device]
                         : nil,
                     nil);
        }];
}

- (void)unregisterDeviceToken:(NSString *)token
                   completion:(void (^)(NSInteger, NSError *_Nullable))completion {
    [self call:@"/unregister"
           devices:YES
            method:@"POST"
             query:nil
           payload:@{@"token" : token ?: @""}
        completion:^(NSDictionary *data, NSError *error) {
          if (completion) {
              completion(data ? ARTNotificationInt(data[@"deleted"]) : 0,
                         data ? nil : error);
          }
        }];
}

- (void)listDevices:(void (^)(ARTPushDeviceList *_Nullable,
                              NSError *_Nullable))completion {
    [self call:@"" devices:YES method:@"GET" query:nil payload:nil
        completion:^(NSDictionary *data, NSError *error) {
          if (!data) {
              completion(nil, error);
              return;
          }
          NSMutableArray<ARTPushDevice *> *devices = [NSMutableArray array];
          id raw = data[@"devices"];
          if ([raw isKindOfClass:[NSArray class]]) {
              for (id item in (NSArray *)raw) {
                  if ([item isKindOfClass:[NSDictionary class]]) {
                      [devices addObject:[[ARTPushDevice alloc] initWithMap:item]];
                  }
              }
          }
          completion([[ARTPushDeviceList alloc]
                         initWithDevices:devices
                                   total:ARTNotificationInt(data[@"total"])],
                     nil);
        }];
}

#pragma mark Internals

- (nullable NSString *)tenant:(NSError **)error {
    AuthenticationConfig *credentials = [self.context getCredentials:error];
    return credentials ? (credentials.orgTitle ?: @"") : nil;
}

/// REST call through the host ADK. Completes with the response's `data`
/// object, or the whole response when it has no `data` wrapper.
- (void)call:(NSString *)suffix
       devices:(BOOL)devices
        method:(NSString *)method
         query:(nullable NSDictionary<NSString *, NSString *> *)query
       payload:(nullable NSDictionary *)payload
    completion:(void (^)(NSDictionary *_Nullable data,
                         NSError *_Nullable error))completion {
    NSError *tenantError = nil;
    NSString *tenant = [self tenant:&tenantError];
    if (!tenant) {
        completion(nil, tenantError);
        return;
    }
    NSString *endpoint = [NSString
        stringWithFormat:@"/api/%@/%@%@", [ARTEncoding uriComponent:tenant],
                         devices ? @"push-devices" : @"notifications", suffix];
    CallApiProps *props = [[CallApiProps alloc]
        initWithMethod:method
               payload:payload
           queryParams:query.count > 0 ? query : nil
               headers:nil
               baseUrl:self.options.apiBaseUrl ?: [self.context baseUrl]
             timeoutMs:nil];
    [self.context call:endpoint
               options:props
            completion:^(id result, NSError *error) {
              if (error) {
                  completion(nil, error);
                  return;
              }
              NSDictionary *root =
                  [result isKindOfClass:[NSDictionary class]] ? result : @{};
              NSDictionary *data = [root[@"data"] isKindOfClass:[NSDictionary class]]
                                       ? root[@"data"]
                                       : root;
              completion(data, nil);
            }];
}

@end

#pragma mark - Plugin

@implementation ARTNotificationsPlugin

+ (instancetype)pluginWithOptions:(ARTNotificationsOptions *)options {
    ARTNotificationsPlugin *plugin = [[self alloc] init];
    plugin->_options = options;
    return plugin;
}

- (NSString *)name {
    return @"notifications";
}

- (id)installWithContext:(ARTAdkPluginContext *)context {
    return [[ARTNotificationsApi alloc] initWithContext:context options:self.options];
}

@end
