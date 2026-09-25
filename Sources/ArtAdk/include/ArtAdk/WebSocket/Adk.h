#ifndef ARTADK_WEBSOCKET_ADK_H
#define ARTADK_WEBSOCKET_ADK_H

#pragma once

//
//  Adk.h
//  ADK
//

#import <Foundation/Foundation.h>

@class Socket;
@class AdkConfig;
@class ConnectConfig;
@class ConnectionDetail;
@class CredentialStore;
@class KeyPairType;
@class BaseSubscription;
@class Interception;
@class CallApiProps;
@class Agent;
@class Orchestrator;
@class ARTConnector;
@class ARTUpdateProfileData;
@class ARTFileRef;
@class ARTStorageFile;
@class ARTStorageFileList;
@class ARTUploadOptions;
@class ARTListOptions;
@protocol ARTAdkPlugin;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AdkState) {
    AdkStatePaused,
    AdkStateConnected,
    AdkStateConnecting,
    AdkStateStopped
};

@interface Adk : NSObject

@property(nonatomic, strong, readonly) Socket *socket;

@property(nonatomic, strong, nullable) KeyPairType *myKeyPair;

/// Connection state: connecting while connecting or retrying, connected
/// once the server has accepted the connection, paused after `pause`,
/// stopped otherwise.
@property(atomic, assign, readonly) AdkState state;

- (instancetype)initWithConfig:(nullable AdkConfig *)config;

/// Connects using, in order of precedence: `AdkConfig.getCredentials`, the
/// credentials from `setCredentials:`, or `adk-services.json` (loaded when
/// `AdkConfig.autoLoadCredsFromJSON` is set, or when no credentials were
/// supplied at all).
- (void)connect:(nullable ConnectConfig *)config
     completion:(nullable void (^)(void))completion;

/// Supplies credentials for `connect`. The credentials' `config` is ignored.
/// Takes effect on the first connection: the auth layer keeps the
/// credentials it started with.
- (void)setCredentials:(CredentialStore *)credentials;

/// Closes the connection and suspends reconnection until `resume:`.
- (void)pause;

- (void)resume:(nullable void (^)(void))completion;

- (void)disconnect:(nullable void (^)(void))completion;

/// `paused`, `connected`, `retrying` or `stopped`.
- (NSString *)getState;

- (NSUUID *)on:(NSString *)event handler:(void (^)(id data))handler;

- (void)off:(NSString *)event identifier:(NSUUID *)identifier;

- (void)subscribe:(NSString *)channel
       completion:(void (^)(BaseSubscription *_Nullable subscription,
                            NSError *_Nullable error))completion;

#pragma mark - Agentic

/// Returns an Agent handle for `agentId` (channel `agent_com_<agentId>`).
- (Agent *)agent:(NSString *)agentId;

/// Returns an Orchestrator handle for `orchestratorId`
/// (channel `orch_com_<orchestratorId>`).
- (Orchestrator *)orchestrator:(NSString *)orchestratorId;

/// Registers a handler fired after each RE-connection (not the first connect),
/// so agentic threads can re-attach listeners after a transport bounce.
/// Returns an id for removal via `offReconnected:`.
- (NSUUID *)onReconnected:(void (^)(void))handler;

/// Removes a handler registered with `onReconnected:`.
- (void)offReconnected:(NSUUID *)identifier;

#pragma mark - Profiles

/// Updates the signed-in user's profile (`POST /v1/update-profile`). Only
/// the fields that are set are sent.
- (void)updateProfile:(ARTUpdateProfileData *)data
           completion:(nullable void (^)(NSError *_Nullable error))completion;

/// Returns a handle for the signed-in user's profile on a connector. The
/// profile lookup starts right away. Returns nil and sets `error` when
/// `connectorId` is empty.
- (nullable ARTConnector *)connector:(NSString *)connectorId
                               error:(NSError **)error;

#pragma mark - Plugins

/// Installs a plugin (for example notifications) and returns its API. The
/// plugin shares this instance's connection, REST client and credentials.
/// Retrieve it later with `pluginNamed:`.
- (id)use:(id<ARTAdkPlugin>)plugin;

/// An installed plugin's API, by the plugin's name.
- (nullable id)pluginNamed:(NSString *)name;

#pragma mark - Storage

/// Uploads a local file. `options.configId` defaults to the project key.
- (void)uploadFileURL:(NSURL *)fileURL
              options:(nullable ARTUploadOptions *)options
           completion:(void (^)(ARTFileRef *_Nullable fileRef,
                                NSError *_Nullable error))completion;

/// Uploads bytes from memory. `contentType` defaults to
/// `application/octet-stream`.
- (void)uploadData:(NSData *)data
          filename:(nullable NSString *)filename
       contentType:(nullable NSString *)contentType
           options:(nullable ARTUploadOptions *)options
        completion:(void (^)(ARTFileRef *_Nullable fileRef,
                             NSError *_Nullable error))completion;

/// Lists stored files.
- (void)listFilesWithOptions:(nullable ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable list,
                                       NSError *_Nullable error))completion;

/// Fetches one file's details, including a signed read URL.
- (void)getFile:(NSString *)fileId
      timeoutMs:(nullable NSNumber *)timeoutMs
     completion:(void (^)(ARTStorageFile *_Nullable file,
                          NSError *_Nullable error))completion;

/// Deletes a file. `hard` removes it permanently.
- (void)deleteFile:(NSString *)fileId
              hard:(BOOL)hard
         timeoutMs:(nullable NSNumber *)timeoutMs
        completion:(nullable void (^)(NSError *_Nullable error))completion;

#pragma mark - Channels and crypto

- (void)intercept:(NSString *)interceptor
               fn:(void (^)(NSDictionary *request, void (^resolve)(id data),
                            void (^reject)(NSString *error)))fn
       completion:(void (^)(Interception *_Nullable interception,
                            NSError *_Nullable error))completion;

- (void)closeWebSocket:(nullable void (^)(void))completion;

- (void)pushForSecureLine:(NSString *)event
                     data:(id)data
                   listen:(BOOL)listen
               completion:(void (^)(id _Nullable result,
                                    NSError *_Nullable error))completion;

/// Generates a key pair and registers it: uploads the public key and makes
/// the pair active.
- (void)generateKeyPair:(void (^)(KeyPairType *_Nullable keyPair,
                                  NSError *_Nullable error))completion;

- (void)setKeyPair:(KeyPairType *)keyPair
        completion:(void (^)(NSError *_Nullable error))completion;

- (void)encrypt:(NSString *)data
    recipientPublicKey:(NSString *)key
            completion:(void (^)(NSString *_Nullable encrypted,
                                 NSError *_Nullable error))completion;

- (void)decrypt:(NSString *)data
    senderPublicKey:(NSString *)key
         completion:(void (^)(NSString *_Nullable decrypted,
                              NSError *_Nullable error))completion;

#pragma mark - REST

/// Calls an ART REST endpoint with a fresh token. Completes with the decoded
/// JSON (`NSNull` for an empty response). A non-2xx response gives an error
/// described as `API <endpoint> failed: <message>`, with the HTTP status in
/// `userInfo[ARTHTTPStatusCodeKey]`.
- (void)callEndpoint:(NSString *)endpoint
             options:(CallApiProps *)options
          completion:(void (^)(id _Nullable result,
                               NSError *_Nullable error))completion;

- (void)onConnectedHook:(ConnectionDetail *)connection;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_ADK_H */
