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

/// Opens the connection to the ART server and completes once it is ready.
///
/// Connects using, in order of precedence: `AdkConfig.getCredentials`, the
/// credentials from `setCredentials:`, or `adk-services.json` (loaded when
/// `AdkConfig.autoLoadCredsFromJSON` is set, or when no credentials were
/// supplied at all).
///
/// This is also how to recover after `connectionFailed`: it clears the
/// failure and starts over. A call made while an attempt is in flight joins
/// it; a call while connected completes at once.
///
/// Completes with an `ARTConnectionError` when the attempt fails:
/// `ARTConnectionErrorCodeAuthenticationFailed` when the credentials are
/// missing or the server rejects them (the `authenticationFailed` event
/// fires too), or `ARTConnectionErrorCodeTimeout` when the connection is not
/// ready within `AdkConfig.connectionTimeoutMs`. Completes with an
/// `ErrorCodeInvalidArgument` error when `connectionTimeoutMs` is not
/// positive.
- (void)connect:(nullable ConnectConfig *)config
     completion:(nullable void (^)(NSError *_Nullable error))completion;

/// Supplies credentials for `connect`. The credentials' `config` is ignored.
/// Credentials naming another organisation, environment, project or client
/// ID replace the session's tokens on the next connection.
- (void)setCredentials:(CredentialStore *)credentials;

/// Closes the connection, keeping subscriptions, and suspends
/// auto-reconnection until `resume:`.
///
/// The connection fails with `ARTConnectionErrorCodePaused`, so active agent
/// runs end with an error. No-op if already paused.
- (void)pause;

/// Reconnects after `pause` (see `connect:completion:`). Completes at once
/// if not paused.
- (void)resume:(nullable void (^)(NSError *_Nullable error))completion;

/// Tears down the connection, subscriptions and interceptors, and removes
/// this instance's own listeners from the shared socket.
///
/// The connection fails with `ARTConnectionErrorCodeClosed`, so active agent
/// runs end with an error. Call `connect:completion:` to use the instance
/// again; listeners the app added with `on:handler:` stay registered.
- (void)disconnect:(nullable void (^)(void))completion;

/// `paused`, `connected`, `retrying` or `stopped`.
- (NSString *)getState;

/// Registers `handler` for a connection event: `connection`
/// (`ConnectionDetail`), `open`, `close`, `error`, `limitExceeded`,
/// `authenticationFailed` (`ARTAuthenticationFailedDetail`) or
/// `connectionFailed` (`ARTConnectionError`).
///
/// `close` reports a closure the ADK may still recover from by reconnecting.
/// `connectionFailed` reports that the connection is gone for good: the
/// credentials were rejected, a limit was reached, the connection was paused
/// or closed, or it could not be restored in time. Active agent runs then
/// end with an `agent_error` whose details have `source: connection`, and
/// waits, sends and subscriptions fail with the same error. Fix the cause
/// and call `connect:completion:` to recover. Returns a token for
/// `off:identifier:`.
- (NSUUID *)on:(NSString *)event handler:(void (^)(id data))handler;

- (void)off:(NSString *)event identifier:(NSUUID *)identifier;

- (void)subscribe:(NSString *)channel
       completion:(void (^)(BaseSubscription *_Nullable subscription,
                            NSError *_Nullable error))completion;

#pragma mark - Agentic

/// Returns an Agent handle for `agentId` (channel `agent_com_<agentId>`).
///
/// `agentId` is the agent's slug, optionally pinned to a named build
/// (`my-agent@release2`). Returns nil and sets `error`
/// (`ErrorCodeInvalidArgument`) for anything else; see
/// `ARTValidateExecutionReference`.
- (nullable Agent *)agent:(NSString *)agentId error:(NSError **)error;

/// Returns an Orchestrator handle for `orchestratorId`
/// (channel `orch_com_<orchestratorId>`). `orchestratorId` is a slug,
/// optionally with `@buildname`, like the agent id in `agent:error:`.
- (nullable Orchestrator *)orchestrator:(NSString *)orchestratorId
                                  error:(NSError **)error;

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

// Temporary media for a thread (`options.threadId` is required), owned by
// `options.configId`, the project key by default. Scoped variants live on
// Agent, AgentThread, Orchestrator, OrchestratorThread and Subscription.

/// Uploads a local file.
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

/// Lists the files in `options.threadId` (required) that `options.configId`
/// (the project key by default) can access.
- (void)listFilesWithOptions:(nullable ARTListOptions *)options
                  completion:(void (^)(ARTStorageFileList *_Nullable list,
                                       NSError *_Nullable error))completion;

/// Fetches the metadata and a read URL of the file `fileId` in `threadId`.
- (void)getFile:(NSString *)fileId
       threadId:(NSString *)threadId
      timeoutMs:(nullable NSNumber *)timeoutMs
     completion:(void (^)(ARTStorageFile *_Nullable file,
                          NSError *_Nullable error))completion;

/// Deletes a file. `hard` is ignored: files are always removed.
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

/// Closes the connection without clearing subscriptions. The connection
/// fails with `ARTConnectionErrorCodeClosed` and does not reconnect until
/// `connect:completion:` is called.
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
