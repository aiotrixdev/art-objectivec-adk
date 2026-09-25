# ART Objective-C ADK

![Objective-C](https://img.shields.io/badge/Objective--C-2.0-blue)
![Platforms](https://img.shields.io/badge/platforms-iOS%2015%2B%20%7C%20macOS%2012%2B-blue)
![SwiftPM](https://img.shields.io/badge/SwiftPM-supported-orange)
![CocoaPods](https://img.shields.io/badge/CocoaPods-supported-red)
![License](https://img.shields.io/badge/license-MIT-green)

The ART Objective-C ADK connects iOS and macOS apps to [ART (A Realtime Tech)](https://arealtimetech.com/), a realtime communication platform for building intelligent applications with WebSocket-based messaging, AI Agents, AI Orchestrators, presence tracking, end-to-end encrypted channels, and CRDT-backed shared objects.

With the ADK you can:

- Send and receive messages in real time
- See who is online in a channel
- Encrypt conversations end-to-end
- Keep shared data in sync across users and devices
- Check or block messages before they are delivered
- Chat with AI agents and run multi-agent workflows
- Upload files and share them with AI agents
- Receive in-app notifications and register devices for push notifications

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Getting started](#getting-started)
- [Connection](#connection)
- [Channels and messages](#channels-and-messages)
- [Presence](#presence)
- [Encrypted channels](#encrypted-channels)
- [Shared objects](#shared-objects)
- [Interceptors](#interceptors)
- [AI agents](#ai-agents)
- [AI orchestrators](#ai-orchestrators)
- [File storage](#file-storage)
- [Profiles and connectors](#profiles-and-connectors)
- [Notifications](#notifications)
- [Calling ART APIs](#calling-art-apis)
- [Logging](#logging)
- [Documentation](#documentation)
- [License](#license)

## Requirements

- iOS 15 or later, or macOS 12 or later
- Xcode 15 or later
- An ART project with its environment, project key, organisation and client ID

## Installation

### CocoaPods

Add the ADK to your `Podfile`:

```ruby
pod 'ArtAdk', '~> 1.0.3'
pod 'ArtAdk/Notifications', '~> 1.0.3'   # optional
```

Then run:

```bash
pod install
```

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/aiotrixdev/art-objectivec-adk.git", from: "1.0.3")
]
```

Then add the libraries to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "ArtAdkObjC", package: "art-objectivec-adk"),
        .product(name: "ArtAdkNotifications", package: "art-objectivec-adk") // optional
    ]
)
```

In Xcode, choose **File › Add Package Dependencies…**, enter `https://github.com/aiotrixdev/art-objectivec-adk.git`, and add **ArtAdkObjC** to your app target. Add **ArtAdkNotifications** only if your app uses notifications.

### Importing the ADK

```objc
@import ArtAdk;
```

With CocoaPods, the notifications add-on is part of the `ArtAdk` module once you add `ArtAdk/Notifications`. With Swift Package Manager, also add `@import ArtAdkNotifications;`.

## Getting started

### 1. Get a user passcode

ART signs users in with a short-lived passcode. Your backend requests the passcode from ART using your client secret, and returns only the passcode to the app:

```objc
- (void)fetchPasscodeForUsername:(NSString *)username
                      completion:(void (^)(NSString *passcode, NSError *error))completion {
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"PASSCODE_URL"]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"username" : username}
                                                       options:0
                                                         error:nil];

    [[[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data
                                                                          options:0
                                                                            error:nil]
                                        : nil;
              NSString *passcode = [json isKindOfClass:[NSDictionary class]] ? json[@"passcode"] : nil;
              completion(passcode ?: @"", error);
          }] resume];
}
```

> **Important:** Never put your client secret in the app. Anything shipped inside an app can be extracted. Whether users can sign in using only a passcode depends on your ART project settings, so confirm this with the ART team before release.

### 2. Create credentials and connect

```objc
@import ArtAdk;

AdkConfig *config = [[AdkConfig alloc] initWithUri:@"YOUR_WEBSOCKET_URI"
                                         authToken:passcode
                                    getCredentials:nil
                                              root:nil];
Adk *adk = [[Adk alloc] initWithConfig:config];

[adk setCredentials:[[CredentialStore alloc] initWithEnvironment:@"YOUR_ENV"
                                                      projectKey:@"YOUR_PROJECT_KEY"
                                                        orgTitle:@"YOUR_ORG"
                                                        clientID:@"YOUR_CLIENT_ID"
                                                    clientSecret:@""
                                                          config:nil
                                                     accessToken:passcode]];

[adk connect:nil completion:^{
    NSLog(@"Connection state: %@", [adk getState]);
}];
```

### 3. Send and receive a message

```objc
[adk subscribe:@"CHANNEL_NAME"
    completion:^(BaseSubscription *channel, NSError *error) {
        if (!channel) {
            NSLog(@"Couldn't subscribe: %@", error);
            return;
        }

        [channel.emitter on:@"message" handler:^(id data) {
            NSLog(@"Received: %@", data);
        }];

        [channel push:@"message"
                 data:@{@"text" : @"Hello ART!"}
              options:nil
           completion:^(NSError *pushError) {
               if (pushError) {
                   NSLog(@"Couldn't send: %@", pushError);
               }
           }];
    }];
```

### Other ways to provide credentials

`setCredentials:` is the simplest option. You can also use one of these:

| **Option** | **When to use it** |
|---|---|
| `AdkConfig.getCredentials` | Your credentials change over time, for example when the passcode is refreshed. The ADK calls the block each time it signs in. |
| `AdkConfig.autoLoadCredsFromJSON = YES` | You keep credentials in an `adk-services.json` file, either in the app bundle or in the folder set in `AdkConfig.root`. The file uses the keys `Client-ID`, `Environment`, `Org-Title` and `ProjectKey`. |

If you use more than one option, `getCredentials` takes priority, then `setCredentials:`, then the JSON file.

## Connection

`connect:completion:` opens the connection and signs the user in. If the connection drops, the ADK reconnects automatically.

```objc
[adk on:@"connection" handler:^(id data) {
    if ([data isKindOfClass:[ConnectionDetail class]]) {
        NSLog(@"Connected: %@", ((ConnectionDetail *)data).connectionId);
    }
}];

[adk on:@"close" handler:^(id reason) {
    NSLog(@"Connection closed: %@", reason);
}];

[adk connect:nil completion:nil];
```

You can pause the connection and resume it later. A paused connection stays closed until you call `resume:`.

```objc
[adk pause];
[adk resume:nil];

[adk disconnect:nil];   // close the connection
```

`adk.state` tells you where the connection stands:

| **State** | **Meaning** |
|---|---|
| `AdkStateConnecting` | Opening the connection, or reconnecting after it dropped |
| `AdkStateConnected` | Connected and signed in |
| `AdkStatePaused` | Paused with `pause` |
| `AdkStateStopped` | Not connected |

If your project reaches its billing or concurrency limit, the ADK emits a `limitExceeded` event and stops reconnecting.

## Channels and messages

A channel is a named stream of messages. Subscribe to a channel to send and receive messages on it. `subscribe:completion:` returns a `Subscription` for regular channels and a `LiveObjSubscription` for [shared-object channels](#shared-objects).

```objc
[adk subscribe:@"room-42"
    completion:^(BaseSubscription *channel, NSError *error) {
        // Use the channel.

        // When you no longer need it:
        [channel unsubscribe:nil];
    }];
```

### Sending messages

```objc
[channel push:@"message" data:@{@"text" : @"Hello"} options:nil completion:^(NSError *error) {}];
```

To send a message to specific users, list their usernames in the `to` option:

```objc
[channel push:@"message"
         data:@{@"text" : @"Hi Bob"}
      options:[[PushConfig alloc] initWithTo:@[ @"bob" ]]
   completion:^(NSError *error) {}];
```

On targeted channels, `push` completes once ART confirms delivery. If no confirmation arrives within 50 seconds, it completes with an `ErrorCodeAckTimeout` error.

### Receiving messages

```objc
[channel.emitter on:@"message" handler:^(id data) {
    NSLog(@"Received: %@", data);
}];
```

On regular channels, `bind:callback:` also delivers messages that arrived before you started listening. It returns a token that you can use to remove that listener later:

```objc
Subscription *subscription = (Subscription *)channel;
NSUUID *token = [subscription bind:@"message" callback:^(id content) {
    NSLog(@"%@", content);
}];

// Later:
[subscription remove:@"message" identifier:token];
```

`listen:` works the same way for every event on the channel.

## Presence

Find out who is online in the channel. The callback runs again whenever someone joins or leaves.

```objc
__block PresenceUnsubscribe stopPresence = nil;

[channel fetchPresence:YES
              callback:^(NSArray<NSString *> *users) {
                  NSLog(@"Online: %@", users);
              }
            completion:^(PresenceUnsubscribe unsubscribe, NSError *error) {
                stopPresence = unsubscribe;
            }];

// Later, to stop receiving updates:
if (stopPresence) {
    stopPresence(nil);
}
```

Pass `YES` to list each user once, even when they are connected from several devices.

## Encrypted channels

Messages on encrypted channels are encrypted on the sender's device, and only the recipients can read them. Before using an encrypted channel, create a key pair for the current user. `generateKeyPair:` creates the keys and registers the public key with ART.

```objc
[adk generateKeyPair:^(KeyPairType *keyPair, NSError *error) {
    [adk subscribe:@"SECURE_CHANNEL"
        completion:^(BaseSubscription *secure, NSError *subscribeError) {
            [secure.emitter on:@"message" handler:^(id data) {
                NSLog(@"Decrypted: %@", data);
            }];

            [secure push:@"message"
                    data:@{@"text" : @"Private"}
                 options:[[PushConfig alloc] initWithTo:@[ @"bob" ]]
              completion:^(NSError *pushError) {}];
        }];
}];
```

## Shared objects

A shared-object channel holds a document that every subscriber can read and edit. Changes are merged automatically using CRDTs (conflict-free replicated data types), so everyone ends up with the same data.

```objc
[adk subscribe:@"CRDT_CHANNEL"
    completion:^(BaseSubscription *channel, NSError *error) {
        if (![channel isKindOfClass:[LiveObjSubscription class]]) {
            return;
        }
        LiveObjSubscription *live = (LiveObjSubscription *)channel;

        // Edit the document, then send your changes.
        [[live state][@"document"][@"title"] set:@"My Doc"];
        [live flush:^{}];

        // Read a value.
        [[live query:@"document"] executeWithCompletion:^(id document) {
            NSLog(@"%@", document);
        }];

        // Watch for changes. The callback also receives the current value.
        void (^stopWatching)(void) = [[live query:@"document"] listenWithCallback:^(id value) {
            NSLog(@"Updated: %@", value);
        }];

        // Later:
        stopWatching();
    }];
```

Lists support the usual operations:

```objc
CRDTProxy *items = [live state][@"items"];

[items pushItem:@"alpha"];                                         // add to the end
[items unshiftItem:@"zero"];                                       // add to the start
[items pop];                                                       // remove the last item
[items removeAtIndex:2];                                           // remove the item at an index
[items spliceStart:1 deleteCount:1 insertItems:@[ @"x" ]];         // replace a range

[items flushWithCompletion:^{}];
```

## Interceptors

An interceptor sees messages before they are delivered and decides what happens to each one. Call `resolve` to deliver the message, with or without changes, or `reject` to block it. You can resolve with a dictionary or an array.

```objc
[adk intercept:@"profanity-filter"
            fn:^(NSDictionary *payload, InterceptorResolve resolve, InterceptorReject reject) {
                NSString *text = [payload[@"text"] isKindOfClass:[NSString class]] ? payload[@"text"] : @"";
                if ([text containsString:@"badword"]) {
                    reject(@"Message blocked");
                    return;
                }
                resolve(payload);
            }
    completion:^(Interception *interception, NSError *error) {}];
```

The name must match an interceptor set up in your ART project.

## AI agents

Chat with an agent built on ART. Each conversation takes place in a thread.

### Start a conversation

```objc
Agent *agent = [adk agent:@"YOUR_AGENT_ID"];
AgentThread *thread = [agent thread];   // or [agent threadWithId:@"THREAD_ID"] to continue a conversation

[thread listen:^(AgentEventEnvelope *envelope) {
    NSLog(@"Event: %@", envelope.event);
}];

[thread run:@"Plan a 3-day trip to Dubai"
     replyId:nil
  completion:^(Run *run, NSError *error) {
      [run done:^(AgentOutput *output, AgentError *agentError) {
          if (agentError) {
              NSLog(@"The agent couldn't finish: %@", agentError.message);
              return;
          }
          NSLog(@"%@", output.message);
      }];
  }];
```

`done:` waits for the agent's final answer. `listen:` receives every event in the thread as it happens, such as progress updates and questions from the agent. `envelope.content` holds all the fields the server sent with the event.

### Display progress

Use the thread's state to drive a status indicator, such as "Queued" or "Waiting for your input":

```objc
ARTStateUnsubscribe stopUpdates = [thread listenState:^(ARTThreadState *state) {
    NSLog(@"%@: %@", state.phase, state.message);
}];

NSLog(@"%@", [thread getState].phase);   // the latest state
stopUpdates();                           // stop receiving updates
```

The phase is an `ARTThreadStatePhase`: `idle`, `submitted`, `queued`, `running`, `waiting_for_agent`, `waiting_for_approval`, `waiting_for_workspace`, `completed`, `failed` or `cancelled`, with constants such as `ARTThreadStatePhaseRunning`. A phase the ADK doesn't know yet is kept as the server's value.

### Answer questions from the agent

An agent can pause and ask the user for more information. This is often called human-in-the-loop. Register a handler before you start the run, and send the answer with `sendFeedback:completion:`:

```objc
[thread feedbackRequest:^(HumanInputRequest *request, Run *run) {
    NSLog(@"The agent asks: %@", request.prompt);

    [run sendFeedback:@"Budget is 50,000, travelling in December"
           completion:^(NSError *error) {
               if (error) {
                   NSLog(@"Couldn't send the answer: %@", error);
               }
           }];
}];
```

### Share files with an agent

Upload the file first, then attach it to your message:

```objc
ARTUploadOptions *options = [[ARTUploadOptions alloc] init];
options.progress = ^(double fraction) {
    NSLog(@"Uploaded %d%%", (int)(fraction * 100));
};

[agent uploadFileURL:documentURL
             options:options
          completion:^(ARTFileRef *file, NSError *error) {
              [thread run:@"Summarize this document"
                   replyId:nil
                  fileMeta:@[ [ARTFileMeta fileMetaWithFileRef:file] ]
                completion:^(Run *run, NSError *runError) {}];
          }];
```

By default, only the file's owner can use it. To allow other agents to use it as well, list their IDs in `scope`, for example `[[ARTFileMeta alloc] initWithFileRef:file scope:@[ @"OTHER_AGENT_ID" ]]`.

## AI orchestrators

An orchestrator coordinates several agents to complete a larger task. Start a thread, listen for its events, and send the user's input:

```objc
Orchestrator *orchestrator = [adk orchestrator:@"YOUR_ORCHESTRATOR_ID"];

[orchestrator thread:^(OrchestratorThread *thread, NSError *error) {
    [thread listen:^(NSDictionary<NSString *, id> *event) {
        NSLog(@"%@", event);
    }];

    [thread listenState:^(ARTThreadState *state) {
        NSLog(@"%@", state.phase);
    }];

    [thread push:@"user_input"
            data:@{@"message" : @"Plan a 3-day trip to Goa"}
      completion:^(NSError *pushError) {}];
}];
```

## File storage

Upload files to ART storage, then list, fetch or delete them. Each upload returns an `ARTFileRef` with the file's ID, name, size, content type and a URL for reading it.

```objc
[adk uploadData:pngData
       filename:@"chart.png"
    contentType:@"image/png"
        options:nil
     completion:^(ARTFileRef *ref, NSError *error) {
         // A signed URL for reading the file:
         [adk getFile:ref.fileId timeoutMs:nil completion:^(ARTStorageFile *file, NSError *getError) {}];

         // Pass hard:YES to delete it permanently:
         [adk deleteFile:ref.fileId hard:NO timeoutMs:nil completion:nil];
     }];

ARTListOptions *filter = [[ARTListOptions alloc] init];
filter.configType = ARTConfigTypeMedia;
filter.page = @1;
filter.limit = @20;
[adk listFilesWithOptions:filter completion:^(ARTStorageFileList *page, NSError *error) {}];
```

To upload a file from disk, use `uploadFileURL:options:completion:`. The file is streamed rather than loaded into memory, and you can follow its progress with `ARTUploadOptions.progress`.

Every file has an owner, which depends on where you upload it from:

| **Uploaded with** | **Owner** |
|---|---|
| `adk` | Your project, or the ID you set in `ARTUploadOptions.configId` |
| `agent` | The agent |
| An agent thread | The thread |
| `orchestrator` | The orchestrator |
| An orchestrator thread | The thread |
| A `Subscription` | The channel (orchestrator-enabled channels only) |

When an upload fails, the error's domain is `ARTUploadErrorDomain` and its code is the `ARTUploadStep` that failed. `userInfo[ARTHTTPStatusCodeKey]` holds the HTTP status code. A `403` at `ARTUploadStepSignedURL` means the user's role doesn't have storage permission.

```objc
[adk uploadData:pngData filename:nil contentType:nil options:nil completion:^(ARTFileRef *ref, NSError *error) {
    if ([error.domain isEqualToString:ARTUploadErrorDomain] &&
        error.code == ARTUploadStepSignedURL &&
        [error.userInfo[ARTHTTPStatusCodeKey] integerValue] == 403) {
        NSLog(@"This user's role doesn't allow uploads");
    }
}];
```

## Profiles and connectors

Update the signed-in user's profile. Only the fields you set are changed.

```objc
ARTUpdateProfileData *profile = [[ARTUpdateProfileData alloc] init];
profile.firstName = @"Ada";
profile.email = @"ada@example.com";
[adk updateProfile:profile completion:nil];
```

Each connector keeps its own profile for the user. Read it, or update the fields that the connector allows:

```objc
NSError *error = nil;
ARTConnector *crm = [adk connector:@"YOUR_CONNECTOR_ID" error:&error];

// The allowed fields and their current values:
[crm profile:^(ARTConnectorProfile *current, NSError *profileError) {}];

// Only allowed fields can be changed:
[crm updateProfile:@{@"region" : @"eu"} completion:^(ARTConnectorProfile *updated, NSError *updateError) {}];
```

## Notifications

Notifications are in the optional notifications add-on (`ArtAdk/Notifications` with CocoaPods, `ArtAdkNotifications` with Swift Package Manager). Add it to your `Adk` instance once and keep the object it returns:

```objc
ARTNotificationsApi *inbox = [adk use:[ARTNotificationsPlugin pluginWithOptions:nil]];

// Receive new notifications as they arrive.
[inbox onNew:^(ARTNotification *notification) {
    NSLog(@"%@", notification.title);
}
    completion:^(void (^stop)(void), NSError *error) {
        // Call stop() to stop receiving them.
    }];

ARTNotificationListParams *unread = [[ARTNotificationListParams alloc] init];
unread.status = ARTNotificationStatusUnread;
[inbox list:unread completion:^(ARTNotificationPage *page, NSError *error) {}];

[inbox markRead:nil completion:nil];   // marks every unread notification as read

// Register the device for push notifications.
[inbox registerDevice:[[ARTRegisterDeviceInput alloc] initWithToken:pushToken
                                                            platform:ARTDevicePlatformIOS]
           completion:nil];
```

You can also send notifications, count unread notifications and manage registered devices. To get the same object elsewhere in your app, call `[adk pluginNamed:@"notifications"]`.

## Calling ART APIs

`callEndpoint:options:completion:` sends an authenticated request to an ART REST endpoint and returns the decoded JSON response:

```objc
CallApiProps *options = [[CallApiProps alloc] initWithMethod:@"POST"
                                                     payload:@{@"key" : @"value"}
                                                 queryParams:nil
                                                     headers:nil];

[adk callEndpoint:@"/v1/some-endpoint"
          options:options
       completion:^(id result, NSError *error) {
           // On a non-2xx response, error.userInfo[ARTHTTPStatusCodeKey] holds the status.
       }];
```

## Logging

The ADK doesn't print anything by default. To see its warnings and errors, set a log handler:

```objc
ARTLog.handler = ^(ARTLogLevel level, NSString *message) {
    NSLog(@"[ART][%@] %@", ARTLogLevelName(level), message);
};
```

## Documentation

For full guides, see the [ART ADK documentation](https://docs.arealtimetech.com/docs/adk/). For what's new in each release and how to upgrade, see the [changelog](https://github.com/aiotrixdev/art-objectivec-adk/blob/main/CHANGELOG.md).

| **Topic** | **Link** |
|---|---|
| Overview | [ADK overview](https://docs.arealtimetech.com/docs/adk/) |
| Installation | [Objective-C installation](https://docs.arealtimetech.com/docs/adk/objc/installation) |
| Publish and subscribe | [Pub/sub](https://docs.arealtimetech.com/docs/adk/objc/pub-sub) |
| Connection management | [Connections](https://docs.arealtimetech.com/docs/adk/objc/connection-management) |
| User presence | [Presence](https://docs.arealtimetech.com/docs/adk/objc/user-presence) |
| Encrypted channels | [Encryption](https://docs.arealtimetech.com/docs/adk/objc/encrypted-channel) |
| Shared object channels | [Shared objects](https://docs.arealtimetech.com/docs/adk/objc/shared-object-channel) |
| Interceptors | [Interceptors](https://docs.arealtimetech.com/docs/adk/objc/intercept-channel) |
| Agents | [Agents](https://docs.arealtimetech.com/docs/adk/objc/agent) |
| Orchestrators | [Orchestrators](https://docs.arealtimetech.com/docs/adk/objc/orchestrator) |

## License

The ART Objective-C ADK is released under the [MIT License](https://github.com/aiotrixdev/art-objectivec-adk/blob/main/LICENSE).
