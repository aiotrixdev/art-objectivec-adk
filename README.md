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
- Receive in-app notifications

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
- [Errors](#errors)
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
pod 'ArtAdk', '~> 1.0.4'
pod 'ArtAdk/Notifications', '~> 1.0.4'   # optional
```

Then run:

```bash
pod install
```

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/aiotrixdev/art-objectivec-adk.git", from: "1.0.4")
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

[adk connect:nil completion:^(NSError *error) {
    if (error) {
        NSLog(@"Couldn't connect: %@", error);
        return;
    }
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

If you use more than one option, `getCredentials` takes priority. Otherwise the ADK uses `setCredentials:`, unless `autoLoadCredsFromJSON` is `YES`: then the JSON file replaces those credentials when it can be read. The ADK also reads the file when you haven't set any credentials.

When you provide both a client ID and a client secret, the ADK signs in with them and signs in again whenever the access token needs renewing. Otherwise it exchanges `accessToken` for an ART token and renews it with a refresh token.

## Connection

`connect:completion:` opens the connection, signs the user in, and completes once ART has accepted the connection. If the connection drops, the ADK reconnects automatically.

```objc
[adk on:@"connection" handler:^(id data) {
    if ([data isKindOfClass:[ConnectionDetail class]]) {
        NSLog(@"Connected: %@", ((ConnectionDetail *)data).connectionId);
    }
}];

[adk on:@"close" handler:^(id reason) {
    NSLog(@"Connection closed, reconnecting: %@", reason);
}];

[adk connect:nil completion:^(NSError *error) {
    if ([error isKindOfClass:[ARTConnectionError class]]) {
        ARTConnectionError *failure = (ARTConnectionError *)error;
        NSLog(@"Couldn't connect: %@ %@", failure.connectionCode, failure.message);
    }
}];
```

`connect:completion:` completes with an `ARTConnectionError` when it can't connect: `AUTHENTICATION_FAILED` when the credentials are missing or ART rejects them, or `CONNECTION_TIMEOUT` when the connection isn't ready in time. Calls made while a connection attempt is in progress share it.

By default the ADK waits up to 30 seconds for the connection, for a sign-in request and for ART's reply to a request such as a subscribe. To change this, set `connectionTimeoutMs` to a positive number; anything else makes `connect:completion:` complete with an `ErrorCodeInvalidArgument` error. It doesn't limit how long an agent can take to answer.

```objc
AdkConfig *config = [[AdkConfig alloc] initWithUri:@"YOUR_WEBSOCKET_URI"];
config.connectionTimeoutMs = 15000;
```

You can pause the connection and resume it later. A paused connection stays closed until you call `resume:`.

```objc
[adk pause];
[adk resume:^(NSError *error) {}];

[adk disconnect:nil];   // close the connection
```

### When the connection fails

Sometimes the connection can't continue: the credentials were rejected, a limit was reached, you paused or closed the connection, or it couldn't be restored after five attempts. The ADK then emits `connectionFailed` with an `ARTConnectionError` and stops reconnecting. Agent runs in progress end with an error, and later sends and subscribes fail with the same `ARTConnectionError` until you call `connect:completion:` again.

```objc
[adk on:@"connectionFailed" handler:^(id data) {
    if ([data isKindOfClass:[ARTConnectionError class]]) {
        ARTConnectionError *error = data;
        NSLog(@"Connection failed: %@ %@", error.connectionCode, error.message);
    }
}];

[adk on:@"authenticationFailed" handler:^(id data) {
    if ([data isKindOfClass:[ARTAuthenticationFailedDetail class]]) {
        ARTAuthenticationFailedDetail *detail = data;
        // Update the credentials, then connect again.
        NSLog(@"Sign-in rejected: %ld %@", (long)detail.status, detail.error);
    }
}];
```

An `ARTConnectionError` is an `NSError` subclass. Its `connectionCode` is a string, with a constant for each value:

| **Code** | **Constant** | **Meaning** |
|---|---|---|
| `AUTHENTICATION_FAILED` | `ARTConnectionErrorCodeAuthenticationFailed` | The credentials are missing or were rejected. `status` holds the HTTP status when ART rejected them. |
| `CONNECTION_TIMEOUT` | `ARTConnectionErrorCodeTimeout` | The connection, or ART's reply to a request, didn't arrive in time |
| `CONNECTION_LOST` | `ARTConnectionErrorCodeLost` | The connection dropped before a message could be sent, or couldn't be restored |
| `CONNECTION_PAUSED` | `ARTConnectionErrorCodePaused` | You called `pause` |
| `CONNECTION_CLOSED` | `ARTConnectionErrorCodeClosed` | You called `closeWebSocket:` or `disconnect:` |
| `CONNECTION_CANCELLED` | `ARTConnectionErrorCodeCancelled` | A newer connection attempt replaced this one |
| `CONNECTION_AUTHORIZATION_FAILED` | `ARTConnectionErrorCodeAuthorizationFailed` | The connection's sign-in couldn't be renewed |
| `ACK_TIMEOUT` | `ARTConnectionErrorCodeAckTimeout` | ART didn't confirm a message |
| `CONNECTION_MINUTES_LIMIT_EXCEEDED` | `ARTConnectionErrorCodeMinutesLimitExceeded` | Your project reached its billing limit |
| `CONCURRENT_LIMIT_EXCEEDED` | `ARTConnectionErrorCodeConcurrentLimitExceeded` | Your project reached its concurrency limit |

`adk.state` tells you where the connection stands:

| **State** | **Meaning** |
|---|---|
| `AdkStateConnecting` | Opening the connection, or reconnecting after it dropped |
| `AdkStateConnected` | Connected and signed in |
| `AdkStatePaused` | Paused with `pause` |
| `AdkStateStopped` | Not connected |

If your project reaches its billing or concurrency limit, the ADK also emits a `limitExceeded` event.

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

On targeted and encrypted channels, `push` completes once ART confirms delivery. If no confirmation arrives within 50 seconds, it completes with an `ARTConnectionError` with the code `ACK_TIMEOUT`.

The ADK never queues a message to send later. If there's no connection, `push` completes with an `ARTConnectionError` and the message isn't sent. A message is never resent automatically, so after an error, check whether it took effect before you send it again.

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
NSError *invalidId = nil;
Agent *agent = [adk agent:@"your-agent-id" error:&invalidId];
AgentThread *thread = [agent thread];   // or [agent threadWithId:@"THREAD_ID"] to continue a conversation

[thread listen:^(AgentEventEnvelope *envelope) {
    NSLog(@"Event: %@", envelope.event);
}];

[thread run:@"Plan a 3-day trip to Dubai"
     replyId:nil
  completion:^(Run *run, NSError *error) {
      if (error) {
          NSLog(@"Couldn't start the run: %@", error);
          return;
      }

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

An agent ID is the agent's slug, such as `travel-agent`. To use a specific build, add its name: `travel-agent@release2`. For any other ID, `agent:error:` returns nil and sets an `ErrorCodeInvalidArgument` error.

`run:` subscribes to the agent's channel when needed, and completes with an error if that fails. For example, it completes with an `ErrorCodeServerError` error holding the server's message when the signed-in user has no access to the agent. `listen:` and `listenState:` can't report this, so always check the error from `run:`.

If the connection fails during a run, the run ends with an `AgentError` that has the connection error's code, and `details[@"source"]` is `connection`. The agent may still finish on the server, but the app can't receive the answer, so check the result before you run the request again. The thread's state becomes `failed` with the message "Connection unavailable".

```objc
[run done:^(AgentOutput *output, AgentError *agentError) {
    if ([agentError.details[@"source"] isEqual:@"connection"]) {
        NSLog(@"Connection lost: %@", agentError.code);
    }
}];
```

When you no longer need a thread, call `[thread dispose]`. It ends the thread's run and removes the thread's listeners, while other threads of the agent keep working. After `dispose`, `run` fails with an error and new listeners are ignored.

Runs started from the ART playground can say so with `executionOrigin`:

```objc
[thread run:@"Plan a trip"
            replyId:nil
           fileMeta:nil
    executionOrigin:ARTExecutionOriginPlayground
         completion:^(Run *run, NSError *error) {}];
```

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

Upload the file to the thread first, then attach it to your message:

```objc
ARTUploadOptions *options = [[ARTUploadOptions alloc] init];
options.progress = ^(double fraction) {
    NSLog(@"Uploaded %d%%", (int)(fraction * 100));
};

[thread uploadFileURL:documentURL
              options:options
           completion:^(ARTFileRef *file, NSError *error) {
               [thread run:@"Summarize this document"
                    replyId:nil
                   fileMeta:@[ [ARTMediaRef mediaRefWithFileRef:file] ]
                 completion:^(Run *run, NSError *runError) {}];
           }];
```

The file belongs to the thread and is owned by the agent. `listFilesWithOptions:completion:` on the thread lists its files.

## AI orchestrators

An orchestrator coordinates several agents to complete a larger task. Start a thread, listen for its events, and send the user's input:

```objc
NSError *invalidId = nil;
Orchestrator *orchestrator = [adk orchestrator:@"your-orchestrator-id" error:&invalidId];

[orchestrator thread:^(OrchestratorThread *thread, NSError *error) {
    if (!thread) {
        NSLog(@"Couldn't start the thread: %@", error);
        return;
    }

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

An orchestrator ID is a slug like an agent ID, optionally with a build name. `thread:` subscribes to the orchestrator's channel and completes with an error if that fails, for example when the signed-in user has no access. To continue a conversation, use `threadWithId:completion:`.

If the connection fails while a request is in progress, `listen:` receives an `agent_error` event whose details have `source: connection`, and the thread's state becomes `failed`. Call `[thread dispose]` when you no longer need the thread.

## File storage

Files are temporary media that belong to a conversation thread. Upload a file, then list, fetch or delete it. Each upload returns an `ARTFileRef` with the file's ID, name, size, content type and a URL for reading it. `listFilesWithOptions:completion:` leaves out that URL, and `getFile:threadId:timeoutMs:completion:` includes it.

The easiest way is to upload from an agent or orchestrator thread, which fills in the thread for you (see [Share files with an agent](#share-files-with-an-agent)). When you use `adk` directly, pass the thread ID:

```objc
ARTUploadOptions *options = [[ARTUploadOptions alloc] init];
options.threadId = @"THREAD_ID";
options.allowedMimeTypes = @[ @"image/png" ];

[adk uploadData:pngData
       filename:@"chart.png"
    contentType:@"image/png"
        options:options
     completion:^(ARTFileRef *ref, NSError *error) {
         // Includes a URL for reading the file:
         [adk getFile:ref.fileId
              threadId:@"THREAD_ID"
             timeoutMs:nil
            completion:^(ARTStorageFile *file, NSError *getError) {}];

         [adk deleteFile:ref.fileId hard:NO timeoutMs:nil completion:nil];
     }];

ARTListOptions *filter = [[ARTListOptions alloc] init];
filter.threadId = @"THREAD_ID";
filter.page = @1;
filter.limit = @20;
[adk listFilesWithOptions:filter completion:^(ARTStorageFileList *page, NSError *error) {}];
```

To upload a file from disk, use `uploadFileURL:options:completion:`. The file is streamed rather than loaded into memory, and you can follow its progress with `ARTUploadOptions.progress`: it reports `0` when the upload starts and `1` once ART has stored the file. Set `ttlSeconds` to choose how long the file is kept, and `allowedMimeTypes` to limit the types ART accepts.

Every file has an owner, which depends on where you upload it from:

| **Uploaded with** | **Owner** |
|---|---|
| `adk` | Your project, or the configuration you set in `ARTUploadOptions.configId` |
| `agent`, or an agent thread | The agent |
| `orchestrator`, or an orchestrator thread | The orchestrator |
| A `Subscription` | The channel's configuration (orchestrator-enabled channels only) |

When an upload fails, the error's domain is `ARTUploadErrorDomain` and its code is the `ARTUploadStep` that failed: `ARTUploadStepValidate`, `ARTUploadStepUpload`, `ARTUploadStepList`, `ARTUploadStepGet` or `ARTUploadStepDelete`. `userInfo[ARTHTTPStatusCodeKey]` holds the HTTP status code. A `403` means the user's role doesn't have storage permission.

```objc
[adk uploadData:pngData filename:nil contentType:nil options:options completion:^(ARTFileRef *ref, NSError *error) {
    if ([error.domain isEqualToString:ARTUploadErrorDomain] &&
        error.code == ARTUploadStepUpload &&
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
```

You can also send notifications and count unread notifications. A notification you send is delivered in-app unless you set `channels` on `ARTSendNotificationInput` to `ARTNotificationChannelInApp`, `ARTNotificationChannelEmail` or both. To get the same object elsewhere in your app, call `[adk pluginNamed:@"notifications"]`.

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

To send a `multipart/form-data` request, pass an `ARTFormDataPayload` as the payload:

```objc
ARTFormDataFile *avatar = [[ARTFormDataFile alloc] initWithField:@"file"
                                                            data:pngData
                                                        filename:@"avatar.png"
                                                     contentType:@"image/png"];
CallApiProps *upload = [[CallApiProps alloc]
    initWithMethod:@"POST"
           payload:[[ARTFormDataPayload alloc] initWithFields:@{@"purpose" : @"avatar"}
                                                        files:@[ avatar ]]
       queryParams:nil
           headers:nil];

[adk callEndpoint:@"/v1/some-upload" options:upload completion:^(id result, NSError *error) {}];
```

## Errors

Errors reach you as `NSError` values:

| **Error** | **When** |
|---|---|
| `ARTConnectionError` | The connection failed or isn't available. See [When the connection fails](#when-the-connection-fails). |
| `ARTAuthHttpError` | ART rejected a sign-in request. `status` holds the HTTP status, and `isTerminal` is `YES` for rejected credentials (401 or 403). |
| `AgentError` | An agent run failed, or ended because the connection failed. It reaches you through `-[Run done:]`. Its `code` is `RUN_SUPERSEDED` when a newer run on the thread replaced the run, and `RUN_CLOSED` when the thread was disposed or the request couldn't be sent. |
| Domain `ARTUploadErrorDomain` | A storage request failed |
| Domain `ARTConnectorErrorDomain` | A connector ID is empty or can't be resolved, or you updated a field the connector doesn't allow |
| Domain `ARTJSONErrorDomain` | Data you passed can't be converted to JSON |
| Domain `ErrorDomain` | Other errors, for example `ErrorCodeInvalidArgument` for an agent ID that isn't a slug, or `ErrorCodeServerError` when ART refuses a request or a REST call gets an error response |

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
| Installation | [Objective-C installation](https://docs.arealtimetech.com/docs/adk/objective-c/installation) |
| Publish and subscribe | [Pub/sub](https://docs.arealtimetech.com/docs/adk/objective-c/pub-sub) |
| Connection management | [Connections](https://docs.arealtimetech.com/docs/adk/objective-c/connection-management) |
| User presence | [Presence](https://docs.arealtimetech.com/docs/adk/objective-c/user-presence) |
| Encrypted channels | [Encryption](https://docs.arealtimetech.com/docs/adk/objective-c/encrypted-channel) |
| Shared object channels | [Shared objects](https://docs.arealtimetech.com/docs/adk/objective-c/shared-object-channel) |
| Interceptors | [Interceptors](https://docs.arealtimetech.com/docs/adk/objective-c/intercept-channel) |
| Agents | [Agents](https://docs.arealtimetech.com/docs/adk/objective-c/agent) |
| Orchestrators | [Orchestrators](https://docs.arealtimetech.com/docs/adk/objective-c/orchestrator) |

## License

The ART Objective-C ADK is released under the [MIT License](https://github.com/aiotrixdev/art-objectivec-adk/blob/main/LICENSE).
