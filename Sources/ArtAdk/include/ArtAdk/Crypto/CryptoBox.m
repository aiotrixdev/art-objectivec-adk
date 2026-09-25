//
//  CryptoBox.m
//  ADK
//

#import "CryptoBox.h"
#import "ctweetnacl.h"
#import <Security/Security.h>

static const NSInteger kPublicKeyBytes = 32;
static const NSInteger kSecretKeyBytes = 32;
static const NSInteger kNonceBytes = 24;

NSString *const CryptoBoxErrorDomain = @"com.art.adk.cryptobox";

static NSError *CryptoBoxMakeError(CryptoBoxErrorCode code, NSString *desc) {
    return [NSError errorWithDomain:CryptoBoxErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : desc}];
}

@implementation CryptoBox

+ (NSInteger)publicKeyLength {
    return kPublicKeyBytes;
}
+ (NSInteger)secretKeyLength {
    return kSecretKeyBytes;
}
+ (NSInteger)nonceLength {
    return kNonceBytes;
}

+ (KeyPairType *)generateKeyPair:(NSError **)error {
    NSMutableData *sk =
        [NSMutableData dataWithLength:(NSUInteger)kSecretKeyBytes];
    OSStatus status = SecRandomCopyBytes(
        kSecRandomDefault, (size_t)kSecretKeyBytes, sk.mutableBytes);
    if (status != errSecSuccess) {
        if (error) {
            *error = CryptoBoxMakeError(
                CryptoBoxErrorRandomGenerationFailed,
                @"SecRandomCopyBytes failed for secret key generation.");
        }
        return nil;
    }

    NSMutableData *pk =
        [NSMutableData dataWithLength:(NSUInteger)kPublicKeyBytes];
    int r = crypto_scalarmult_curve25519_tweet_base(
        (unsigned char *)pk.mutableBytes, (const unsigned char *)sk.bytes);
    if (r != 0) {
        if (error) {
            *error = CryptoBoxMakeError(CryptoBoxErrorCryptoOperationFailed,
                                        @"Key pair derivation failed.");
        }
        return nil;
    }

    NSString *publicKeyBase64 = [pk base64EncodedStringWithOptions:0];
    NSString *privateKeyBase64 = [sk base64EncodedStringWithOptions:0];

    return [[KeyPairType alloc] initWithPublicKey:publicKeyBase64
                                       privateKey:privateKeyBase64];
}

+ (NSString *)encrypt:(NSString *)message
            publicKey:(NSString *)publicKey
           privateKey:(NSString *)privateKey
                error:(NSError **)error {

    NSData *pub = [[NSData alloc] initWithBase64EncodedString:publicKey
                                                      options:0];
    NSData *priv = [[NSData alloc] initWithBase64EncodedString:privateKey
                                                       options:0];

    if (!pub || !priv) {
        if (error) {
            *error = CryptoBoxMakeError(CryptoBoxErrorInvalidBase64,
                                        @"Invalid base64 key.");
        }
        return nil;
    }

    NSData *messageData = [message dataUsingEncoding:NSUTF8StringEncoding];

    //  nonce (24 bytes)
    NSMutableData *nonce = [NSMutableData dataWithLength:24];
    if (SecRandomCopyBytes(kSecRandomDefault, 24, nonce.mutableBytes) !=
        errSecSuccess) {
        if (error) {
            *error = CryptoBoxMakeError(CryptoBoxErrorRandomGenerationFailed,
                                        @"Nonce generation failed.");
        }
        return nil;
    }

    NSUInteger mlen = messageData.length + 32;
    NSMutableData *m = [NSMutableData dataWithLength:mlen];
    [m replaceBytesInRange:NSMakeRange(32, messageData.length)
                 withBytes:messageData.bytes];

    NSMutableData *c = [NSMutableData dataWithLength:mlen];

    int result = crypto_box(c.mutableBytes, m.bytes, (unsigned long long)mlen,
                            nonce.bytes, pub.bytes, priv.bytes);

    if (result != 0) {
        if (error) {
            *error = CryptoBoxMakeError(CryptoBoxErrorCryptoOperationFailed,
                                        @"Encryption failed.");
        }
        return nil;
    }

    NSData *cipher = [c subdataWithRange:NSMakeRange(16, mlen - 16)];

    NSMutableData *full = [NSMutableData data];
    [full appendData:nonce];
    [full appendData:cipher];

    return [full base64EncodedStringWithOptions:0];
}

+ (NSString *)decrypt:(NSString *)encryptedData
            publicKey:(NSString *)publicKey
           privateKey:(NSString *)privateKey
                error:(NSError **)error {

    NSData *full = [[NSData alloc] initWithBase64EncodedString:encryptedData
                                                       options:0];
    NSData *pub = [[NSData alloc] initWithBase64EncodedString:publicKey
                                                      options:0];
    NSData *priv = [[NSData alloc] initWithBase64EncodedString:privateKey
                                                       options:0];

    if (!full || !pub || !priv) {
        if (error) {
            *error = CryptoBoxMakeError(CryptoBoxErrorInvalidBase64,
                                        @"Invalid base64.");
        }
        return nil;
    }

    if (full.length < 24) {
        if (error) {
            *error = CryptoBoxMakeError(CryptoBoxErrorDataTooShort,
                                        @"Data too short.");
        }
        return nil;
    }

    NSData *nonce = [full subdataWithRange:NSMakeRange(0, 24)];
    NSData *cipher = [full subdataWithRange:NSMakeRange(24, full.length - 24)];

    // 🔥 Add required padding
    NSUInteger clen = cipher.length + 16;
    NSMutableData *c = [NSMutableData dataWithLength:clen];
    [c replaceBytesInRange:NSMakeRange(16, cipher.length)
                 withBytes:cipher.bytes];

    NSMutableData *m = [NSMutableData dataWithLength:clen];

    int result =
        crypto_box_open(m.mutableBytes, c.bytes, (unsigned long long)clen,
                        nonce.bytes, pub.bytes, priv.bytes);

    if (result != 0) {
        if (error) {
            *error = CryptoBoxMakeError(CryptoBoxErrorCryptoOperationFailed,
                                        @"Decryption failed.");
        }
        return nil;
    }

    NSData *messageData = [m subdataWithRange:NSMakeRange(32, clen - 32)];

    return [[NSString alloc] initWithData:messageData
                                 encoding:NSUTF8StringEncoding];
}

@end
