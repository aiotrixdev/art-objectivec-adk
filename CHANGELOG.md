# Changelog

All notable changes to the ART Objective-C ADK are documented in this file.

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

[1.0.3]: https://github.com/aiotrixdev/art-objectivec-adk/releases/tag/1.0.3
[1.0.2]: https://github.com/aiotrixdev/art-objectivec-adk/releases/tag/1.0.2
[1.0.1]: https://github.com/aiotrixdev/art-objectivec-adk/releases/tag/1.0.1
[1.0.0]: https://github.com/aiotrixdev/art-objectivec-adk/releases/tag/1.0.0
