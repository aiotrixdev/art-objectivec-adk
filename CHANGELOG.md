# Changelog

All notable changes to the ART Objective-C ADK are documented in this file.

## [1.0.4]

### Added

- **Connection failures you can handle.** The new `connectionFailed` event delivers an `ARTConnectionError` with a readable `message`, a `connectionCode` and the HTTP `status` when there is one. It fires when the credentials are missing or rejected, a token can't be renewed, a billing or concurrency limit is reached, the connection isn't ready in time, it can't be restored after five reconnect attempts, or the app pauses or closes it. The ADK then stops reconnecting until you call `connect:completion:` again.
- **Agent runs end when the connection fails.** The active run ends with an `AgentError` that has the connection error's code, and its details have `source: connection` and `execution_status: unknown`, because the app can no longer tell whether the agent finished. The thread's state becomes `failed` with the message "Connection unavailable". Orchestrator threads with a request in progress report the same through `listen:`.
- **`AdkConfig.connectionTimeoutMs`** (default 30 seconds) sets how long the ADK waits for the connection to be ready, for a sign-in request and for ART's reply to a request such as a subscribe. It doesn't limit how long an agent can take to answer.
- **Rejected credentials stop reconnecting.** The new `authenticationFailed` event (`ARTAuthenticationFailedDetail`) fires when ART rejects the credentials, or when renewing a token fails while reconnecting. Sign-in rejections complete with an `ARTAuthHttpError` with the HTTP `status`; `isTerminal` (and `ARTIsTerminalAuthError`) is `YES` for HTTP 401 and 403.
- **`-[AgentThread dispose]`** ends the thread's run and removes only that thread's listeners. Other threads of the agent keep working. `isDisposed` tells you whether it was called.
- **Execution origin.** `-[AgentThread run:replyId:fileMeta:executionOrigin:completion:]` and `PushConfig.executionOrigin` mark requests started from the ART playground (`execution_origin`). Replies keep the origin of the thread's latest run.
- **Multipart requests.** `CallApiProps.payload` accepts an `ARTFormDataPayload` for `multipart/form-data` requests.
- `-[Subscription configurationId:]`, `-[BaseWorkflow configurationId:]` and `ChannelConfig.configurationID`: the server-side configuration behind a channel.
- `ARTValidateExecutionReference` checks an agent or orchestrator ID.

### Changed

- `connect:completion:` completes once ART has accepted the connection, and reports the `ARTConnectionError` when it can't connect, for example `AUTHENTICATION_FAILED` for missing or rejected credentials or `CONNECTION_TIMEOUT`. Calls made while an attempt is in progress share it. `resume:` now calls `connect:completion:` and reports errors too.
- `pause`, `closeWebSocket:` and `disconnect:` end the connection with `CONNECTION_PAUSED` or `CONNECTION_CLOSED`, so runs in progress end with an error. `disconnect:` also removes the instance's own listeners from the connection; `connect:completion:` adds them back.
- Messages are never queued to be sent later. Without a connection, `push` and `run` complete with an `ARTConnectionError` (`CONNECTION_LOST`) and the message isn't sent; a message is never resent automatically.
- Encrypted channels now wait for ART to confirm delivery, like targeted channels. A missing confirmation completes with an `ARTConnectionError` with the code `ACK_TIMEOUT` instead of an `ErrorCodeAckTimeout` error.
- After five failed reconnect attempts, the connection fails with `CONNECTION_LOST` instead of retrying forever.
- Requests to ART's `art_secure` line, such as subscribes, complete with `CONNECTION_TIMEOUT` when no reply arrives in time. `subscribe:` on a subscription now reports when it fails.
- With a client ID and client secret, the ADK signs in again to renew the access token and never uses refresh tokens. Without a client secret it exchanges `accessToken` and renews it with the refresh token, as before. A sign-in sends either the client credentials or the access token, not both.
- Sign-in requests give up after `connectionTimeoutMs`, and a response without an access token is an error.
- When the access token changes, the connection's sign-in is renewed with ART before the next push or subscribe.
- `+[Auth getInstance:error:]` updates the stored credentials, and starts with an empty token cache when the organisation, environment, project or client ID changes. A `getCredentials` block that switches to another identity also drops the old tokens.
- The long-poll fallback stops when ART rejects the credentials, and reports failed polls as `ARTAuthHttpError`. Its connection becomes active once a poll is answered, so `connect:completion:` fails with `CONNECTION_TIMEOUT` when ART can't be reached.
- **Files are temporary media that belong to a conversation thread.** `ARTUploadOptions.threadId` and `ARTListOptions.threadId` are required, and `getFile:threadId:timeoutMs:completion:` takes a thread ID. Uploads from agents, orchestrators, their threads and channels are owned by the channel's server-side configuration. Files in `listFilesWithOptions:completion:` have no `readUrl`; `getFile` returns one.
- New `ARTUploadOptions.allowedMimeTypes`. Upload progress reports `0` when the upload starts and `1` once ART has stored the file.
- Storage errors report `ARTUploadStepValidate`, `ARTUploadStepUpload`, `ARTUploadStepList`, `ARTUploadStepGet` or `ARTUploadStepDelete`.
- Files attached to a message are `ARTMediaRef` values, sent as `id`, `name` and `content_type`. Create one with `+[ARTMediaRef mediaRefWithFileRef:]`.
- Agent and orchestrator IDs must be lowercase slugs, optionally with a build name (`my-agent@release2`). `agent:error:` and `orchestrator:error:` return nil and set an `ErrorCodeInvalidArgument` error for anything else.
- A `Run` keeps its thread alive until it ends, so a run still ends when the app holds on to the run only.
- `done:` reports a run whose thread was disposed, or whose request couldn't be sent, as an `AgentError` with the code `RUN_CLOSED`. A run replaced by a newer run still reports `RUN_SUPERSEDED`.
- `WebsocketHandler` has new requirements: `ensureAuthorization:`, `onConnectionFailure:` and `offConnectionFailure:`. `wait:` and `sendMessage:error:` now report errors.
- `ARTSendNotificationInput.channels` now holds `ARTNotificationChannel` values: `ARTNotificationChannelInApp` or `ARTNotificationChannelEmail`. Push is no longer a delivery channel.

### Fixed

- The README's documentation links led to pages that don't exist.

### Deprecated

- `ARTFileMeta`: use `ARTMediaRef`.
- `ARTUploadOptions.scopes`: access follows the owning configuration and the thread, so scopes are ignored.
- `ARTConfigTypeKnowledgeBase`: storage only holds media files.
- `ARTUploadStepSignedURL`, `ARTUploadStepPut` and `ARTUploadStepConfirm`: an upload is now a single request (`ARTUploadStepUpload`).

### Removed

- **Push-device registration.** `registerDevice:completion:`, `unregisterDeviceToken:completion:`, `listDevices:`, `ARTRegisterDeviceInput`, `ARTPushDevice`, `ARTPushDeviceList` and `ARTDevicePlatform` are gone, because ART no longer offers these APIs.

### Upgrading

- Change the completion blocks of `connect:completion:` and `resume:` to `^(NSError *error) { … }`, and handle the error.
- Replace `[adk agent:…]` and `[adk orchestrator:…]` with `agent:error:` and `orchestrator:error:`, and make sure the IDs are slugs. If you create them directly, use `initWithAgentId:socket:error:` and `initWithOrchestratorId:socket:error:`.
- Change the completion block of `-[BaseSubscription subscribe:]` to `^(NSError *error) { … }`.
- Pass a thread ID when you use storage directly: `ARTUploadOptions.threadId`, `ARTListOptions.threadId` and `getFile:threadId:timeoutMs:completion:`. Thread uploads and lists set it for you.
- Replace `[ARTFileMeta fileMetaWithFileRef:file]` with `[ARTMediaRef mediaRefWithFileRef:file]`. `initWithFileId:scope:` and `scope` are gone: use `initWithFileId:name:contentType:`, because access now follows the owning configuration and the thread. Handle `ARTUploadStepUpload` where you checked `ARTUploadStepSignedURL`, `ARTUploadStepPut` or `ARTUploadStepConfirm`.
- Check for `ARTConnectionErrorCodeAckTimeout` where you checked `ErrorCodeAckTimeout`.
- If you implement `WebsocketHandler` or call `wait:` or `sendMessage:` on the socket yourself, use the new signatures.
- Listen for `connectionFailed` to show that the connection is gone and offer a way to reconnect.
- Remove calls to `registerDevice:completion:`, `unregisterDeviceToken:completion:` and `listDevices:`, and use a notifier configured on a connector instead.
- Replace channel strings with the `ARTNotificationChannel` constants, for example `input.channels = @[ ARTNotificationChannelInApp, ARTNotificationChannelEmail ]`.

## [1.0.3]

### Added

- **File storage.** Upload, list, fetch and delete files with `ARTStorage` or the matching `Adk` methods. A file can belong to your project, an agent, an orchestrator, a conversation thread or a channel. Uploads from disk are streamed and report their progress. If an upload fails, the error's code tells you which step failed, and `userInfo[ARTHTTPStatusCodeKey]` holds the HTTP status code.
- **Files for AI agents.** Attach uploaded files to a message with `-[AgentThread run:replyId:fileMeta:completion:]` so the agent can use them. Channel messages can carry files too, through `PushConfig.fileMeta`.
- **Conversation status.** Agent and orchestrator threads report their current status, such as queued, running, waiting for input, completed or failed. Follow it with `listenState:` or read it with `getState`.
- **Complete event data.** Agent events include every field the server sent, in `AgentEventEnvelope.content`. `AgentWait` also has `invocationId` and `progress`, and `PlannerCorrection` has `suggestedAgents`.
- **Profiles.** Update the signed-in user's profile with `updateProfile:completion:`, and read or update the user's profile for a connector with `connector:error:`.
- **Notifications.** The new, optional notifications add-on (`ArtAdk/Notifications` with CocoaPods, `ArtAdkNotifications` with Swift Package Manager) receives notifications as they arrive, lists past notifications, marks them as read, sends notifications and registers devices for push notifications. Add-ons are installed with `-[Adk use:]`.
- **More ways to provide credentials.** Pass credentials with `setCredentials:`, or load them automatically from `adk-services.json` with `AdkConfig.autoLoadCredsFromJSON`.
- **REST call options.** `CallApiProps` accepts a custom base URL and a timeout. Errors from REST calls include the HTTP status and the response body in their `userInfo`.
- **Removing a single listener.** `listen:`, `bind:callback:`, `attachThreadListener:callback:` and `attachThreadBind:event:callback:` return a token. Pass it to `remove:identifier:` or `detachThreadListener:event:identifier:` to remove that listener without affecting the others.
- **Logging.** Set `ARTLog.handler` to see the ADK's warnings and errors.

### Changed

- On targeted channels, `push` now completes once ART confirms delivery. If no confirmation arrives within 50 seconds, it completes with an `ErrorCodeAckTimeout` error.
- Messages on a channel are delivered to your listeners one at a time, in the order they arrive, including on encrypted channels. Messages that arrive before you start listening are replayed in the same order.
- `Adk.state` reports `AdkStateConnected` only after the server has accepted the connection, and `AdkStateConnecting` while the ADK reconnects.
- Access tokens are renewed 30 seconds before they expire, and requests made at the same time share a single renewal.
- Agent threads include their thread ID in every message, and also receive replies addressed to that thread. New thread IDs are lowercase UUIDs.
- Answers sent through the `reply` block of a request for human input are encoded as JSON, so text answers arrive in quotes.
- An interceptor that resolves with an array now sends the array unchanged.
- `adk-services.json` is now loaded from the app bundle, or from the folder set in `AdkConfig.root`.
- `-[OrchestratorThread push:data:options:completion:]` keeps the recipients and files you pass.
- Shared-object channels apply changes only from `update` messages.
- With CocoaPods, `@import ArtAdk;` also works when the pod is built as a static library.
- The source files moved to `Sources/ArtAdk/include/ArtAdk/`, with each header next to its implementation. Import paths such as `<ArtAdk/WebSocket/Adk.h>` are unchanged.

### Fixed

- Installing with Swift Package Manager failed because the ADK's headers couldn't be found. Add the `ArtAdkObjC` library and import it with `@import ArtAdk;`.
- Agent responses were empty when the server sent their content as JSON text. The message, reference ID and question text are now read correctly.
- `pause` reconnected automatically after five seconds. The connection now stays paused until you call `resume:`.
- `-[Subscription thread:]` always returned nil on orchestrator-enabled channels.
- Presence updates on shared-object channels never reached `fetchPresence:callback:completion:`.
- Closing one orchestrator thread removed the trace listeners of other threads.
- Data that can't be converted to JSON crashed the app. The ADK now reports an `ARTJSONErrorDomain` error instead.
- Using the ADK from several threads at once could corrupt its internal state.

### Deprecated

- `listenTrace:` on agent and orchestrator threads. Use `listenState:` for status updates.

### Upgrading

- If you `switch` over `AgentEventKind`, handle the new `AgentEventKindThreadState` case or add a `default` case.
- `push` on targeted channels now waits for delivery confirmation. Don't block the UI while it waits, and handle `ErrorCodeAckTimeout`.
- `messageBuffer` now returns a snapshot. Changing the returned dictionary no longer changes the subscription's buffer.
- With CocoaPods, run `pod install` again after updating, so the new files are added to your project.

## [1.0.2]

### Fixed

- The CocoaPods podspec now carries the release version, and the minimum macOS version is 12.0.

## [1.0.1]

### Added

- AI agent support
  - Agent API
  - Agent threads (`AgentThread`)
  - Run lifecycle
  - Typed agent events
  - Human-in-the-loop (HITL) support
  - Agent trace listeners
- AI orchestrator support
  - Orchestrator API
  - Orchestrator threads (`OrchestratorThread`)
  - Thread-scoped workflow communication
  - Human-in-the-loop (HITL) replies
  - Workflow trace listeners

### Changed

- Added documentation for agents and orchestrators.
- Added AI workflow examples to the README.

## [1.0.0]

Initial release.

### Added

- WebSocket connection management
- Channel subscriptions: broadcast, targeted, group, encrypted and shared
- Sending messages
- Listening for events
- User presence
- Encrypted channels
- Interceptors for processing messages
- Shared object channels, backed by CRDTs

[1.0.4]: https://github.com/aiotrixdev/art-objectivec-adk/releases/tag/1.0.4
[1.0.3]: https://github.com/aiotrixdev/art-objectivec-adk/releases/tag/1.0.3
[1.0.2]: https://github.com/aiotrixdev/art-objectivec-adk/releases/tag/1.0.2
[1.0.1]: https://github.com/aiotrixdev/art-objectivec-adk/releases/tag/1.0.1
[1.0.0]: https://github.com/aiotrixdev/art-objectivec-adk/releases/tag/1.0.0
