#ifndef ARTADK_WEBSOCKET_ARTCONNECTOR_H
#define ARTADK_WEBSOCKET_ARTCONNECTOR_H

#pragma once

//
//  ARTConnector.h
//  ADK
//
//  The signed-in user's profile for one connector. Talks to the server over
//  the secure line with the `connector-profile` event
//  (`action: "describe"` or `"update"`).
//

#import <ArtAdk/Types/SocketTypes.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Domain of connector errors (unknown connector, field not allowed,
/// unsuccessful server response).
FOUNDATION_EXPORT NSErrorDomain const ARTConnectorErrorDomain;

/// A metadata field a connector accepts.
@interface ARTConnectorField : NSObject

@property(nonatomic, copy, readonly) NSString *key;
@property(nonatomic, copy, readonly) NSString *label;
/// `string`, `secret`, `email`, `number`, `boolean`, `json`, or a
/// server-defined type.
@property(nonatomic, copy, readonly) NSString *type;
@property(nonatomic, copy, readonly, nullable) NSString *placeholder;
/// Boolean `NSNumber`, or nil when the server didn't say.
@property(nonatomic, strong, readonly, nullable) NSNumber *required;
/// The field's description (wire `description`).
@property(nonatomic, copy, readonly, nullable) NSString *fieldDescription;

- (instancetype)initWithKey:(NSString *)key
                      label:(NSString *)label
                       type:(NSString *)type
                placeholder:(nullable NSString *)placeholder
                   required:(nullable NSNumber *)required
           fieldDescription:(nullable NSString *)fieldDescription
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/// The signed-in user's profile for one connector.
@interface ARTConnectorProfile : NSObject

@property(nonatomic, copy, readonly) NSString *connectorId;
@property(nonatomic, copy, readonly) NSString *provider;
@property(nonatomic, copy, readonly) NSArray<ARTConnectorField *> *allowedFields;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *metadata;

- (instancetype)initWithConnectorId:(NSString *)connectorId
                           provider:(NSString *)provider
                      allowedFields:(NSArray<ARTConnectorField *> *)allowedFields
                           metadata:(NSDictionary<NSString *, NSString *> *)metadata
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/// Created with `-[Adk connector:error:]`. The profile lookup starts right
/// away.
@interface ARTConnector : NSObject

@property(nonatomic, copy, readonly) NSString *connectorId;

/// Starts the profile lookup. Returns nil and sets `error` when
/// `connectorId` is empty.
- (nullable instancetype)initWithConnectorId:(NSString *)connectorId
                                     handler:(id<WebsocketHandler>)handler
                                       error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// The connector, its allowed metadata fields, and the user's current
/// values.
- (void)profile:(void (^)(ARTConnectorProfile *_Nullable profile,
                          NSError *_Nullable error))completion;

/// Updates some of the user's metadata for this connector. Every key must be
/// one of the connector's `allowedFields`; the server repeats all
/// validation before saving the merged profile.
- (void)updateProfile:(NSDictionary<NSString *, NSString *> *)metadata
           completion:(void (^)(ARTConnectorProfile *_Nullable profile,
                                NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_ARTCONNECTOR_H */
