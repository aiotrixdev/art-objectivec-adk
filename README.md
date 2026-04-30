# ART Objective-C ADK

![Objective-C](https://img.shields.io/badge/Objective--C-iOS-blue)
![Platform](https://img.shields.io/badge/iOS-15%2B-blue)
![SwiftPM](https://img.shields.io/badge/SwiftPM-supported-orange)

Objective-C SDK for **[ART - A Realtime Tech Communication](https://arealtimetech.com/)**, a realtime messaging platform providing WebSocket-based channels, presence tracking, end-to-end encrypted messaging, and CRDT-backed shared objects.

---

## Features

- WebSocket connection management (`connect`, `pause`, `resume`, auto-reconnect)
- Channel subscriptions (default, targeted, secure, shared-object/CRDT)
- Push messages with structured payloads
- Event-based message listening (`bind`, `listen`, `emitter.on`)
- Real-time presence tracking
- End-to-end encryption support
- Interceptors for message processing
- Shared objects using CRDT

---

## Installation

### Swift Package Manager
```swift
dependencies: [
    .package(
        url: "https://dev.azure.com/BixBytesSolutions/ART%20IPR-0063/_git/art-objectivec-adk",
        from: "1.0.0"
    )
]
```

Then add `ArtAdk` to your target dependencies.

Or in Xcode:

**File -> Add Packages -> Paste repository URL**

Import the SDK where you need it:

```objc
#import <ArtAdk/ADK.h>
```

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
        initWithUri:@"ws.arealtimetech.com"
          authToken:passcode
     getCredentials:^CredentialStore *{
        return creds;
     }
               root:nil];

    Adk *adk = [[Adk alloc] initWithConfig:config];

    [adk on:@"connection" handler:^(id data) {
        if ([data isKindOfClass:[ConnectionDetail class]]) {
            ConnectionDetail *conn = (ConnectionDetail *)data;
            NSLog(@"Connected -> %@", conn.connectionId);
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

## Connecting

```objc
[adk connect:nil completion:^{
    NSLog(@"Connected");
}];
```

Read the current state at any time:

```objc
[adk getState]; // connected | retrying | paused | stopped
```

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

For `targeted` and `secure` channels, exactly one recipient must be provided.

## Receiving Messages

Listen to a specific event:

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
[items spliceStart:1 deleteCount:1 insertItems:@[@"x"]];

[items flushWithCompletion:^{}];
```

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

## Documentation

Full documentation is available at:
[https://docs.arealtimetech.com/docs/adk/](https://docs.arealtimetech.com/docs/adk/)

For API details, see the public umbrella header:
[`Sources/ADK/include/ADK.h`](Sources/ADK/include/ADK.h)
