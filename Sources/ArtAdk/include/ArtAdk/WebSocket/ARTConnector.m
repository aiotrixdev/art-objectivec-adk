//
//  ARTConnector.m
//  ADK
//

#import "ARTConnector.h"
#import "ARTSupport.h"

NSErrorDomain const ARTConnectorErrorDomain = @"com.art.adk.connector";

typedef void (^ARTProfileCompletion)(ARTConnectorProfile *_Nullable,
                                     NSError *_Nullable);

static NSError *ARTConnectorError(NSString *message) {
    return [NSError errorWithDomain:ARTConnectorErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @""}];
}

@implementation ARTConnectorField

- (instancetype)initWithKey:(NSString *)key
                      label:(NSString *)label
                       type:(NSString *)type
                placeholder:(NSString *)placeholder
                   required:(NSNumber *)required
           fieldDescription:(NSString *)fieldDescription {
    self = [super init];
    if (self) {
        _key = [key copy];
        _label = [label copy];
        _type = [type copy];
        _placeholder = [placeholder copy];
        _required = required;
        _fieldDescription = [fieldDescription copy];
    }
    return self;
}

@end

@implementation ARTConnectorProfile

- (instancetype)initWithConnectorId:(NSString *)connectorId
                           provider:(NSString *)provider
                      allowedFields:(NSArray<ARTConnectorField *> *)allowedFields
                           metadata:(NSDictionary<NSString *, NSString *> *)metadata {
    self = [super init];
    if (self) {
        _connectorId = [connectorId copy];
        _provider = [provider copy];
        _allowedFields = [allowedFields copy] ?: @[];
        _metadata = [metadata copy] ?: @{};
    }
    return self;
}

@end

@interface ARTConnector ()
@property(nonatomic, strong) id<WebsocketHandler> handler;
// Guarded by @synchronized(self).
@property(nonatomic, assign) BOOL resolved;
@property(nonatomic, strong, nullable) ARTConnectorProfile *cachedProfile;
@property(nonatomic, strong, nullable) NSError *cachedError;
@property(nonatomic, strong) NSMutableArray<ARTProfileCompletion> *waiters;
@end

@implementation ARTConnector

- (instancetype)initWithConnectorId:(NSString *)connectorId
                            handler:(id<WebsocketHandler>)handler
                              error:(NSError **)error {
    if (connectorId.length == 0) {
        if (error) {
            *error = ARTConnectorError(@"connectorId must be a non-empty string");
        }
        return nil;
    }
    self = [super init];
    if (self) {
        _connectorId = [connectorId copy];
        _handler = handler;
        _waiters = [NSMutableArray array];

        // Start the describe lookup right away, so `connector:` can stay
        // synchronous. The lookup keeps the connector alive until it ends,
        // so pending `profile:` callbacks always run.
        [self requestAction:@"describe"
                   metadata:nil
                 completion:^(ARTConnectorProfile *profile, NSError *lookupError) {
                   [self resolveWithProfile:profile error:lookupError];
                 }];
    }
    return self;
}

- (void)resolveWithProfile:(nullable ARTConnectorProfile *)profile
                     error:(nullable NSError *)error {
    NSArray<ARTProfileCompletion> *waiters;
    @synchronized(self) {
        self.resolved = YES;
        self.cachedProfile = profile;
        self.cachedError = profile ? nil : error;
        waiters = [self.waiters copy];
        [self.waiters removeAllObjects];
    }
    for (ARTProfileCompletion waiter in waiters) {
        waiter(profile, profile ? nil : error);
    }
}

- (void)profile:(void (^)(ARTConnectorProfile *_Nullable,
                          NSError *_Nullable))completion {
    ARTConnectorProfile *profile;
    NSError *error;
    @synchronized(self) {
        if (!self.resolved) {
            [self.waiters addObject:[completion copy]];
            return;
        }
        profile = self.cachedProfile;
        error = self.cachedError;
    }
    completion(profile, error);
}

- (void)updateProfile:(NSDictionary<NSString *, NSString *> *)metadata
           completion:(void (^)(ARTConnectorProfile *_Nullable,
                                NSError *_Nullable))completion {
    [self profile:^(ARTConnectorProfile *current, NSError *error) {
      if (!current) {
          completion(nil, error);
          return;
      }
      NSMutableSet<NSString *> *allowed = [NSMutableSet set];
      for (ARTConnectorField *field in current.allowedFields) {
          [allowed addObject:field.key];
      }
      for (NSString *key in
           [metadata.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
          if (![allowed containsObject:key]) {
              completion(nil, ARTConnectorError([NSString
                                  stringWithFormat:@"Metadata field \"%@\" is not "
                                                   @"allowed for connector %@",
                                                   key, self.connectorId]));
              return;
          }
      }

      [self requestAction:@"update"
                 metadata:metadata
               completion:^(ARTConnectorProfile *updated, NSError *updateError) {
                 if (updated) {
                     @synchronized(self) {
                         self.cachedProfile = updated;
                         self.cachedError = nil;
                         self.resolved = YES;
                     }
                 }
                 completion(updated, updateError);
               }];
    }];
}

#pragma mark - Wire

- (void)requestAction:(NSString *)action
             metadata:(nullable NSDictionary<NSString *, NSString *> *)metadata
           completion:(ARTProfileCompletion)completion {
    NSString *connectorId = self.connectorId;
    id<WebsocketHandler> handler = self.handler;
    NSMutableDictionary *payload =
        [@{@"action" : action, @"connector_id" : connectorId} mutableCopy];
    if (metadata) {
        payload[@"metadata"] = metadata;
    }

    [handler wait:^{
      [handler
          pushForSecureLine:@"connector-profile"
                       data:payload
                     listen:YES
                 completion:^(id _Nullable result, NSError *_Nullable error) {
                   if (error) {
                       completion(nil, error);
                       return;
                   }
                   NSDictionary *data =
                       [result isKindOfClass:[NSDictionary class]]
                           ? ((NSDictionary *)result)[@"data"]
                           : nil;
                   if (![data isKindOfClass:[NSDictionary class]]) {
                       completion(nil, ARTConnectorError([NSString
                                           stringWithFormat:@"Connector %@ could "
                                                            @"not be resolved",
                                                            connectorId]));
                       return;
                   }
                   NSError *profileError = nil;
                   ARTConnectorProfile *profile =
                       [ARTConnector profileFromResponse:data
                                             connectorId:connectorId
                                                   error:&profileError];
                   completion(profile, profileError);
                 }];
    }];
}

+ (nullable ARTConnectorProfile *)profileFromResponse:(NSDictionary *)response
                                          connectorId:(NSString *)connectorId
                                                error:(NSError **)error {
    id status = response[@"status"];
    if (![status isKindOfClass:[NSString class]] ||
        ![status isEqualToString:@"successful"]) {
        id message = response[@"error"];
        if (error) {
            *error = ARTConnectorError(
                ([message isKindOfClass:[NSString class]] && [message length] > 0)
                    ? message
                    : [NSString stringWithFormat:@"Connector %@ could not be "
                                                 @"resolved",
                                                 connectorId]);
        }
        return nil;
    }

    NSString * (^string)(NSDictionary *, NSString *) =
        ^NSString *(NSDictionary *map, NSString *key) {
          id value = map[key];
          return [value isKindOfClass:[NSString class]] ? value : nil;
        };

    NSMutableArray<ARTConnectorField *> *fields = [NSMutableArray array];
    id rawFields = response[@"allowed_fields"];
    if ([rawFields isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)rawFields) {
            if (![item isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSDictionary *field = item;
            id required = field[@"required"];
            [fields addObject:[[ARTConnectorField alloc]
                                     initWithKey:string(field, @"key") ?: @""
                                           label:string(field, @"label") ?: @""
                                            type:string(field, @"type") ?: @"string"
                                     placeholder:string(field, @"placeholder")
                                        required:[required isKindOfClass:[NSNumber
                                                                             class]]
                                                     ? @([required boolValue])
                                                     : nil
                                fieldDescription:string(field, @"description")]];
        }
    }

    NSMutableDictionary<NSString *, NSString *> *metadata =
        [NSMutableDictionary dictionary];
    id rawMetadata = response[@"metadata"];
    if ([rawMetadata isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)rawMetadata
            enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
              metadata[[key description]] =
                  [value isKindOfClass:[NSString class]] ? value
                                                         : [value description];
            }];
    }

    return [[ARTConnectorProfile alloc]
        initWithConnectorId:[ARTJSON stringValue:response[@"connector_id"]]
                                ?: connectorId
                   provider:string(response, @"provider") ?: @""
              allowedFields:fields
                   metadata:metadata];
}

@end
