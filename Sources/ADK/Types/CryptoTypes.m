//
//  CryptoTypes.m
//  ADK
//

#import "CryptoTypes.h"

@implementation KeyPairType

- (instancetype)initWithPublicKey:(NSString *)publicKey
                       privateKey:(NSString *)privateKey {
    self = [super init];
    if (self) {
        _publicKey = [publicKey copy];
        _privateKey = [privateKey copy];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: publicKey=%@, privateKey=%@>",
                                      NSStringFromClass([self class]),
                                      _publicKey, _privateKey];
}

@end
