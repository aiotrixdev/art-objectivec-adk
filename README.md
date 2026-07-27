# ART Objective-C ADK

![Objective-C](https://img.shields.io/badge/Objective--C-2.0-blue)
![Platform](https://img.shields.io/badge/iOS-15%2B-blue)
![SwiftPM](https://img.shields.io/badge/SwiftPM-supported-orange)
![License](https://img.shields.io/badge/license-MIT-green)

Objective-C SDK for **[ART – A Realtime Tech Communication](https://arealtimetech.com/)**, a realtime communication platform for building intelligent applications with WebSocket-based messaging, AI Agents, AI Orchestrators, presence tracking, end-to-end encrypted channels, and CRDT-backed shared objects.

---

## Features

- WebSocket connection management (`connect`, `pause`, `resume`, auto-reconnect)
- Channel subscriptions for default, targeted, secure, and shared-object/CRDT channels
- Structured message pushing with payloads and optional recipients
- Event-based message listening via `emitter`, `listen`, and `bind`
- Real-time presence tracking
- End-to-end encryption support
- Interceptors for message processing
- Shared objects using CRDT
- AI Agent integration
- AI Orchestrator workflows

---

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(
        url: "https://github.com/aiotrixdev/art-objectivec-adk.git",
        from: "1.0.1"
    )
]
```

### CocoaPods

Add the dependency to your Podfile:

```ruby
pod 'ArtAdk', '~> 1.0.0'
```

Then run:

```bash
pod install
```

You can also add the package directly in Xcode via:

**File → Add Packages → Paste repository URL**

Import the SDK where you need it:

```objc
#import <ArtAdk/ADK.h>
```

---

## Configuration

### 1. Create credentials

Store your ART credentials securely:

```objc
CredentialStore *creds = [[CredentialStore alloc]
    initWithEnvironment:@"YOUR_ENV"
             projectKey:@"YOUR_PROJECT_KEY"
               orgTitle:@"YOUR_ORG"
               clientID:@"CLIENT_ID"
           clientSecret:@"CLIENT_SECRET"
                 config:nil
            accessToken:nil];
```

### 2. Get a user passcode

ART uses a short-lived passcode for authentication:

```objc
- (void)fetchPasscodeWithCredentials:(CredentialStore *)creds
                          completion:(void (^)(NSString *passcode, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:@"https://dev.arealtimetech.com/ws/v1/connect/passcode"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";

    [request setValue:creds.clientID forHTTPHeaderField:@"Client-Id"];
    [request setValue:creds.clientSecret forHTTPHeaderField:@"Client-Secret"];
    [request setValue:creds.orgTitle forHTTPHeaderField:@"X-Org"];
    [request setValue:creds.environment forHTTPHeaderField:@"Environment"];
    [request setValue:creds.projectKey forHTTPHeaderField:@"ProjectKey"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"username": @"john_doe",
        @"first_name": @"John",
        @"last_name": @"Doe"
    };

    NSError *jsonError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:&jsonError];

    if (jsonError) {
        completion(nil, jsonError);
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *dataObj = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        NSString *passcode = [dataObj isKindOfClass:[NSDictionary class]] ? dataObj[@"passcode"] : nil;

        completion(passcode ?: @"", nil);
    }] resume];
}
```

---

## Quick Start

```objc
#import <ArtAdk/ADK.h>

CredentialStore *creds = [[CredentialStore alloc]
    initWithEnvironment:@"YOUR_ENV"
             projectKey:@"YOUR_PROJECT_KEY"
               orgTitle:@"YOUR_ORG"
               clientID:@"CLIENT_ID"
           clientSecret:@"CLIENT_SECRET"
                 config:nil
            accessToken:nil];

[self fetchPasscodeWithCredentials:creds
                        completion:^(NSString *passcode, NSError *error) {
    if (error || passcode.length == 0) {
        NSLog(@"Passcode error: %@", error);
        return;
    }

    creds.accessToken = passcode;

    AdkConfig *config = [[AdkConfig alloc]
        initWithUri:@"YOUR_WEBSOCKET_URI"
          authToken:passcode
     getCredentials:^CredentialStore *{
        return creds;
     }
               root:nil];

    Adk *adk = [[Adk alloc] initWithConfig:config];

    [adk on:@"connection" handler:^(id data) {
        if ([data isKindOfClass:[ConnectionDetail class]]) {
            ConnectionDetail *conn = (ConnectionDetail *)data;
            NSLog(@"Connected → %@", conn.connectionId);
        }
    }];

    [adk on:@"close" handler:^(id reason) {
        NSLog(@"Closed: %@", reason);
    }];

    [adk connect:nil completion:^{
        [adk subscribe:@"room-42"
            completion:^(BaseSubscription *subscription, NSError *subError) {
                if (subError || !subscription) {
                    NSLog(@"Subscribe error: %@", subError);
                    return;
                }

                [subscription.emitter on:@"message" handler:^(id data) {
                    NSLog(@"Received: %@", data);
                }];

                [subscription push:@"message"
                              data:@{@"text": @"Hello ART!"}
                           options:nil
                        completion:^(NSError *pushError) {
                            if (pushError) {
                                NSLog(@"Push error: %@", pushError);
                            }
                        }];
            }];
    }];
}];
```

---

## Connecting

```objc
[adk connect:nil completion:^{
    NSLog(@"Connected");
}];
```

Safe usage:

```objc
do {
    [adk connect:nil completion:^{
        NSLog(@"Connected");
    }];
} while (0);
```

Check the current state:

```objc
[adk getState]; // connected | retrying | paused | stopped
```

---

## Subscribing to a Channel

```objc
[adk subscribe:@"room-42"
    completion:^(BaseSubscription *subscription, NSError *error) {
        if (error || !subscription) {
            NSLog(@"Subscribe error: %@", error);
            return;
        }

        if ([subscription isKindOfClass:[LiveObjSubscription class]]) {
            LiveObjSubscription *live = (LiveObjSubscription *)subscription;
            NSLog(@"Shared-object channel: %@", live);
        }
    }];
```

Unsubscribe:

```objc
[subscription unsubscribe:^{
    NSLog(@"Unsubscribed");
}];
```

---

## Pushing Messages

```objc
[subscription push:@"message"
              data:@{@"text": @"Hello"}
           options:nil
        completion:^(NSError *error) {
            if (error) {
                NSLog(@"Push error: %@", error);
            }
        }];
```

Targeted messaging:

```objc
PushConfig *options = [[PushConfig alloc] initWithTo:@[@"bob"]];

[subscription push:@"message"
              data:@{@"text": @"Hi Bob"}
           options:options
        completion:^(NSError *error) {
            if (error) {
                NSLog(@"Push error: %@", error);
            }
        }];
```

For targeted and secure channels, exactly one recipient should be provided.

---

## Receiving Messages

```objc
[subscription.emitter on:@"message" handler:^(id data) {
    NSLog(@"Got: %@", data);
}];
```

Or receive every event on the channel:

```objc
if ([subscription isKindOfClass:[Subscription class]]) {
    Subscription *typedSub = (Subscription *)subscription;
    [typedSub listen:^(NSDictionary<NSString *, id> *message) {
        NSLog(@"Event: %@, content: %@", message[@"event"], message[@"content"]);
    }];
}
```

---

## Presence

```objc
__block PresenceUnsubscribe stopPresence = nil;

[subscription fetchPresence:YES
                   callback:^(NSArray<NSString *> *users) {
                       NSLog(@"Online: %@", users);
                   }
                 completion:^(PresenceUnsubscribe unsubscribe, NSError *error) {
                     if (error) {
                         NSLog(@"Presence error: %@", error);
                         return;
                     }

                     stopPresence = unsubscribe;
                 }];

// later
if (stopPresence) {
    stopPresence(^{
        NSLog(@"Presence listener removed");
    });
}
```

Pass `YES` to receive unique usernames, or `NO` to receive the raw presence list.

---

## Encrypted Channels

```objc
[adk generateKeyPair:^(KeyPairType *keyPair, NSError *error) {
    if (error || !keyPair) {
        NSLog(@"Key pair error: %@", error);
        return;
    }

    [adk subscribe:@"SECURE_CHANNEL"
        completion:^(BaseSubscription *subscription, NSError *subError) {
            if (subError || !subscription) {
                NSLog(@"Secure subscribe error: %@", subError);
                return;
            }

            PushConfig *options = [[PushConfig alloc] initWithTo:@[@"bob"]];

            [subscription push:@"message"
                          data:@{@"text": @"Private"}
                       options:options
                    completion:^(NSError *pushError) {
                        if (pushError) {
                            NSLog(@"Secure push error: %@", pushError);
                        }
                    }];

            [subscription.emitter on:@"message" handler:^(id data) {
                NSLog(@"Decrypted: %@", data);
            }];
        }];
}];
```

---

## Shared Object Channels (CRDT)

```objc
[adk subscribe:@"CRDT_CHANNEL"
    completion:^(BaseSubscription *subscription, NSError *error) {
        if (error || ![subscription isKindOfClass:[LiveObjSubscription class]]) {
            NSLog(@"CRDT subscribe error: %@", error);
            return;
        }

        LiveObjSubscription *live = (LiveObjSubscription *)subscription;

        // Write
        CRDTProxy *document = [[live state] objectForKeyedSubscript:@"document"];
        [[document objectForKeyedSubscript:@"title"] set:@"My Doc"];
        [live flush:^{}];

        // Read
        [[live query:@"document"] executeWithCompletion:^(id result) {
            NSLog(@"Snapshot: %@", result);
        }];

        // Listen
        void (^dispose)(void) = [[live query:@"document"] listenWithCallback:^(id value) {
            NSLog(@"Updated: %@", value);
        }];

        dispose();
    }];
```

### Array Operations

```objc
CRDTProxy *items = [[live state] objectForKeyedSubscript:@"items"];

[items pushItem:@"alpha"];
[items unshiftItem:@"zero"];
[items pop];
[items removeAtIndex:2];
[items spliceStart:1 deleteCount:1 insertItems:@[@"x" ]];

[items flushWithCompletion:^{}];
```

---

## Interceptors

```objc
[adk intercept:@"filter"
             fn:^(NSDictionary *request, InterceptorResolve resolve, InterceptorReject reject) {
                 NSString *text = [request[@"text"] isKindOfClass:[NSString class]] ? request[@"text"] : @"";

                 if ([text containsString:@"anyword"]) {
                     reject(@"Blocked");
                     return;
                 }

                 resolve(request);
             }
     completion:^(Interception *interception, NSError *error) {
         if (error) {
             NSLog(@"Interceptor error: %@", error);
         }
     }];
```

---

## Connection Lifecycle

```objc
[adk on:@"connection" handler:^(id data) {
    NSLog(@"Connected");
}];

[adk on:@"close" handler:^(id reason) {
    NSLog(@"Closed");
}];

[adk pause];
[adk resume:^{
    NSLog(@"Resumed");
}];
[adk disconnect:^{
    NSLog(@"Disconnected");
}];
```

---

## Agent Lab

ART ADK provides two AI integrations:

- Agent — interact with a single AI agent.
- Orchestrator — execute multi-agent workflows coordinated by an orchestrator.

### Agent

Connect to an Agent Builder agent and start a conversation.

```objc
Agent *agent = [adk agent:@"YOUR_AGENT_ID"];
AgentThread *thread = [agent thread];

[thread listen:^(AgentEventEnvelope *envelope) {
    NSLog(@"Envelope: %@", envelope);
}];

[thread run:@"Plan a 3-day trip to Dubai"
     replyId:nil
  completion:^(Run *run, NSError *error) {
      if (error || !run) {
          NSLog(@"Run error: %@", error);
          return;
      }

      [run done:^(AgentOutput *output, AgentError *agentError) {
          if (agentError) {
              NSLog(@"Agent error: %@", agentError);
              return;
          }

          NSLog(@"Output: %@", output);
      }];
  }];
```

### Human-in-the-Loop (HITL)

When an agent requires additional information, register a feedback handler before starting the run.

```objc
[thread feedbackRequest:^(HumanInputRequest *request, Run *run) {
    [run sendFeedback:@"Budget 50,000 travelling in December"
           completion:^(NSError *error) {
               if (error) {
                   NSLog(@"Feedback error: %@", error);
               }
           }];
}];
```

### Orchestrator

Connect to an Orchestrator Builder workflow.

```objc
Orchestrator *orchestrator = [adk orchestrator:@"YOUR_ORCHESTRATOR_ID"];

[orchestrator thread:^(OrchestratorThread *thread, NSError *error) {
    if (error || !thread) {
        NSLog(@"Thread error: %@", error);
        return;
    }

    [thread listen:^(NSDictionary<NSString *, id> *message) {
        NSLog(@"Event: %@", message);
    }];

    [thread push:@"user_input"
            data:@{@"message": @"Plan a 3-day trip to Goa"}
      completion:^(NSError *pushError) {
          if (pushError) {
              NSLog(@"Push error: %@", pushError);
          }
      }];
}];
```

---

## Documentation

Full documentation is available at:
[https://docs.arealtimetech.com/docs/adk/](https://docs.arealtimetech.com/docs/adk/)

| Topic | Link |
| --- | --- |
| Overview | [ADK Overview](https://docs.arealtimetech.com/docs/adk/) |
| Installation | [Objective-C Installation](https://docs.arealtimetech.com/docs/adk/objc/installation) |
| Publish & Subscribe | [Pub/Sub Docs](https://docs.arealtimetech.com/docs/adk/objc/pub-sub) |
| Connection Management | [Connection Docs](https://docs.arealtimetech.com/docs/adk/objc/connection-management) |
| User Presence | [Presence Docs](https://docs.arealtimetech.com/docs/adk/objc/user-presence) |
| Encrypted Channels | [Encryption Docs](https://docs.arealtimetech.com/docs/adk/objc/encrypted-channel) |
| Shared Object Channels | [Shared Object Docs](https://docs.arealtimetech.com/docs/adk/objc/shared-object-channel) |
| Interceptors | [Interceptor Docs](https://docs.arealtimetech.com/docs/adk/objc/intercept-channel) |
| Agents | [Agent Docs](https://docs.arealtimetech.com/docs/adk/objc/agent) |
| Orchestrator | [Orchestrator Docs](https://docs.arealtimetech.com/docs/adk/objc/orchestrator) |


---

## License

Released under the [MIT License](https://github.com/aiotrixdev/art-objectivec-adk/blob/main/LICENSE).
