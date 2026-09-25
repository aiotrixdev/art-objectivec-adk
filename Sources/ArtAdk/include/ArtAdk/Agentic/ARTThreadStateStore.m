//
//  ARTThreadStateStore.m
//  ADK
//

#import "ARTThreadStateStore.h"
#import "ARTSupport.h"

@interface ARTThreadStateStore ()
@property(nonatomic, assign) BOOL enforcesSequence;
@property(nonatomic, strong) ARTThreadState *current;
@property(nonatomic, strong)
    NSMutableArray<NSArray *> *listeners; // @[NSUUID, block]
@end

@implementation ARTThreadStateStore

- (instancetype)initWithThreadId:(NSString *)threadId
                enforcesSequence:(BOOL)enforcesSequence {
    self = [super init];
    if (self) {
        _threadId = [threadId copy];
        _enforcesSequence = enforcesSequence;
        _listeners = [NSMutableArray array];
        _current = [[ARTThreadState alloc]
            initWithThreadId:_threadId
                       phase:ARTThreadStatePhaseIdle
                      source:ARTThreadStateSourceClient
                     message:@"Ready"
                      reason:nil
                      nodeId:nil
                    nodeName:nil
                      taskId:nil
                 workspaceId:nil
                     agentId:nil
               queuePosition:nil
                  occurredAt:[ARTEncoding isoTimestamp]
                    sequence:nil
                     details:nil];
    }
    return self;
}

- (ARTThreadState *)state {
    @synchronized(self) {
        return self.current;
    }
}

- (BOOL)hasListeners {
    @synchronized(self) {
        return self.listeners.count > 0;
    }
}

- (NSUUID *)addListener:(ARTThreadStateListener)listener {
    NSUUID *identifier = [NSUUID UUID];
    @synchronized(self) {
        [self.listeners addObject:@[ identifier, [listener copy] ]];
    }
    return identifier;
}

- (void)removeListener:(NSUUID *)identifier {
    @synchronized(self) {
        NSIndexSet *matches = [self.listeners
            indexesOfObjectsPassingTest:^BOOL(NSArray *entry, NSUInteger idx,
                                              BOOL *stop) {
              return [entry[0] isEqual:identifier];
            }];
        [self.listeners removeObjectsAtIndexes:matches];
    }
}

- (void)removeAllListeners {
    @synchronized(self) {
        [self.listeners removeAllObjects];
    }
}

- (void)apply:(ARTThreadState *)incoming {
    ARTThreadState *next = nil;
    NSArray<ARTThreadStateListener> *callbacks = nil;
    @synchronized(self) {
        if (incoming.threadId.length > 0 &&
            ![incoming.threadId isEqualToString:self.threadId]) {
            return;
        }
        NSNumber *sequence = incoming.sequence;
        if (self.enforcesSequence) {
            NSInteger previous =
                self.current.sequence ? self.current.sequence.integerValue : -1;
            NSInteger value = incoming.sequence ? incoming.sequence.integerValue
                                                : previous + 1;
            if (value < previous) {
                return;
            }
            sequence = @(value);
        }
        next = [incoming stateWithThreadId:self.threadId sequence:sequence];
        self.current = next;
        NSMutableArray *blocks = [NSMutableArray array];
        for (NSArray *entry in self.listeners) {
            [blocks addObject:entry[1]];
        }
        callbacks = blocks;
    }
    for (ARTThreadStateListener callback in callbacks) {
        callback(next);
    }
}

- (void)transition:(ARTThreadStatePhase)phase
            source:(ARTThreadStateSource)source
           message:(NSString *)message
            reason:(NSString *)reason
       workspaceId:(NSString *)workspaceId
           agentId:(NSString *)agentId {
    [self apply:[[ARTThreadState alloc] initWithThreadId:self.threadId
                                                   phase:phase
                                                  source:source
                                                 message:message
                                                  reason:reason
                                                  nodeId:nil
                                                nodeName:nil
                                                  taskId:nil
                                             workspaceId:workspaceId
                                                 agentId:agentId
                                           queuePosition:nil
                                              occurredAt:[ARTEncoding isoTimestamp]
                                                sequence:nil
                                                 details:nil]];
}

@end
