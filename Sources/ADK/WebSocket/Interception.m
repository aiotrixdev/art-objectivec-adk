//
//  Interception.m
//  ADK
//

#import "Interception.h"
#import "HelperFunctions.h"
#import "Utils.h"

@interface Interception ()

@property(nonatomic, copy, readonly) NSString *interceptorName;
@property(nonatomic, strong, nullable) id interceptorData;
@property(nonatomic, weak) id<WebsocketHandler> websocketHandler;
@property(nonatomic, copy, readonly) InterceptorFn fn;

@end

@implementation Interception

- (instancetype)initWithInterceptor:(NSString *)interceptor
                                 fn:(InterceptorFn)fn
                   websocketHandler:(id<WebsocketHandler>)websocketHandler {
    self = [super init];
    if (self) {
        _interceptorName = [interceptor copy];
        _fn = [fn copy];
        _websocketHandler = websocketHandler;
        _emitter = [[EventEmitter alloc] init];
    }
    return self;
}

- (void)validateInterception:(void (^)(NSError *_Nullable))completion {
    __weak typeof(self) weakSelf = self;
    [HelperFunctions
        getInterceptorConfig:_interceptorName
            websocketHandler:_websocketHandler
                  completion:^(id _Nullable config, NSError *_Nullable error) {
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf) {
                        strongSelf.interceptorData = config;
                    }
                    completion(error);
                  }];
}

- (void)reconnect {
    [self validateInterception:^(NSError *error){

    }];
}

- (NSDictionary *)createResponse:(NSDictionary *)config
                              id:(NSString *)msgId
                           refId:(NSString *)refId
                         channel:(NSString *)channel
                       namespace:(NSString *)namespace
                           event:(NSString *)event
                      pipelineId:(NSString *)pipelineId
                 interceptorName:(NSString *)interceptorName
                       attemptId:(NSString *)attemptId
                            type:(NSString *)type
                         content:(id)content {

    NSMutableDictionary *response = [config mutableCopy];
    response[@"channel"] = channel;
    response[@"namespace"] = namespace;
    response[@"event"] = event;
    response[@"id"] = msgId;
    response[@"ref_id"] = refId;
    response[@"return_flag"] = type;
    response[@"pipeline_id"] = pipelineId;
    response[@"interceptor_name"] = interceptorName;
    response[@"attempt_id"] = attemptId;

    NSString *contentStr = @"";
    NSData *contentData = [NSJSONSerialization dataWithJSONObject:content
                                                          options:0
                                                            error:nil];
    if (contentData) {
        NSString *str = [[NSString alloc] initWithData:contentData
                                              encoding:NSUTF8StringEncoding];
        if (str)
            contentStr = str;
    }
    response[@"content"] = contentStr;

    return response;
}

- (void)execute:(NSDictionary *)request {

    [self acknowledge:request];

    NSString *msgId =
        [request[@"id"] isKindOfClass:[NSString class]] ? request[@"id"] : @"";
    NSString *channel = [request[@"channel"] isKindOfClass:[NSString class]]
                            ? request[@"channel"]
                            : @"";
    NSString *namespace_ =
        [request[@"namespace"] isKindOfClass:[NSString class]]
            ? request[@"namespace"]
            : @"";
    NSString *from = [request[@"from"] isKindOfClass:[NSString class]]
                         ? request[@"from"]
                         : @"";
    id to = request[@"to"];
    NSString *event = [request[@"event"] isKindOfClass:[NSString class]]
                          ? request[@"event"]
                          : @"";
    NSString *interceptorName =
        [request[@"interceptor_name"] isKindOfClass:[NSString class]]
            ? request[@"interceptor_name"]
            : @"";
    NSString *pipelineId =
        [request[@"pipeline_id"] isKindOfClass:[NSString class]]
            ? request[@"pipeline_id"]
            : @"";
    NSString *attemptId =
        [request[@"attempt_id"] isKindOfClass:[NSString class]]
            ? request[@"attempt_id"]
            : @"";
    NSString *refId = [request[@"ref_id"] isKindOfClass:[NSString class]]
                          ? request[@"ref_id"]
                          : @"";

    NSMutableDictionary *config = [@{
        @"channel" : channel,
        @"namespace" : namespace_,
        @"event" : event,
        @"interceptor_name" : interceptorName,
        @"from" : from,
        @"to" : to ?: [NSNull null]
    } mutableCopy];
    // Forward the agentic routing / correlation fields when present, so an
    // interceptor's resolve/reject preserves them (js-adk-common realtime-comm
    // fix; mirrors the Swift/Flutter interceptor forwarding).
    for (NSString *k in @[
             @"thread_id", @"node_id", @"agent_node_id", @"agent_id",
             @"environment_id", @"to_username", @"configuration_id",
             @"root_workflow_id"
         ]) {
        id v = request[k];
        if (v) {
            config[k] = v;
        }
    }

    __weak typeof(self) weakSelf = self;

    // Resolve block
    InterceptorResolve resolve = ^(id data) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
          return;

      NSDictionary *dataDict = nil;

      if ([data isKindOfClass:[NSDictionary class]]) {
          dataDict = (NSDictionary *)data;
      } else if ([data isKindOfClass:[NSArray class]]) {
          dataDict = @{@"items" : data};
      }

      if (!dataDict) {
          return;
      }

      NSMutableDictionary *sanitized = [dataDict mutableCopy];
      if (sanitized[@"attempt_id"] != nil || sanitized[@"pipeline_id"] != nil) {
          NSDictionary *inner = sanitized[@"data"];
          sanitized = [inner isKindOfClass:[NSDictionary class]]
                          ? [inner mutableCopy]
                          : [NSMutableDictionary dictionary];
      }

      NSDictionary *response = [strongSelf createResponse:config
                                                       id:msgId
                                                    refId:refId
                                                  channel:channel
                                                namespace:namespace_
                                                    event:event
                                               pipelineId:pipelineId
                                          interceptorName:interceptorName
                                                attemptId:attemptId
                                                     type:@"resolve"
                                                  content:sanitized];
      [strongSelf sendJSON:response];
    };

    // Reject block
    InterceptorReject reject = ^(NSString *error) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
          return;

      id raw = request[@"data"];
      NSDictionary *errResponse =
          @{@"rawData" : raw ?: [NSNull null], @"error" : error};

      NSDictionary *response = [strongSelf createResponse:config
                                                       id:msgId
                                                    refId:refId
                                                  channel:channel
                                                namespace:namespace_
                                                    event:event
                                               pipelineId:pipelineId
                                          interceptorName:interceptorName
                                                attemptId:attemptId
                                                     type:@"reject"
                                                  content:errResponse];
      [strongSelf sendJSON:response];
    };

    _fn(request, resolve, reject);
}

- (void)acknowledge:(NSDictionary *)request {
    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"return_flag"] = @"IA";

    NSArray<NSString *> *keys = @[
        @"channel", @"namespace", @"id", @"ref_id", @"from", @"to",
        @"pipeline_id", @"interceptor_name", @"attempt_id",
        // Agentic routing / correlation fields (js-adk-common parity).
        @"thread_id", @"node_id", @"agent_node_id", @"agent_id",
        @"environment_id", @"to_username", @"configuration_id",
        @"root_workflow_id"
    ];
    for (NSString *k in keys) {
        id val = request[k];
        if (val)
            response[k] = val;
    }

    id dataVal = request[@"data"];
    if (dataVal) {
        NSString *contentStr = @"";
        NSData *contentData = [NSJSONSerialization dataWithJSONObject:dataVal
                                                              options:0
                                                                error:nil];
        if (contentData) {
            NSString *str =
                [[NSString alloc] initWithData:contentData
                                      encoding:NSUTF8StringEncoding];
            if (str)
                contentStr = str;
        }
        response[@"content"] = contentStr;
    }

    [self sendJSON:response];
}

- (void)handleMessage:(NSString *)channel data:(NSDictionary *)data {
    NSMutableDictionary *mutable = [data mutableCopy];

    // If "data" field is a JSON string, parse it
    id dataField = data[@"data"];
    if ([dataField isKindOfClass:[NSString class]]) {
        NSData *jsonData =
            [(NSString *)dataField dataUsingEncoding:NSUTF8StringEncoding];
        if (jsonData) {
            id parsed = [NSJSONSerialization JSONObjectWithData:jsonData
                                                        options:0
                                                          error:nil];
            if (parsed) {
                mutable[@"data"] = parsed;
            }
        }
    }

    [self execute:mutable];
}

- (void)sendJSON:(NSDictionary *)dict {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:0
                                                     error:nil];
    if (data) {
        NSString *str = [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];
        if (str) {
            [self.websocketHandler sendMessage:str];
        }
    }
}

@end
