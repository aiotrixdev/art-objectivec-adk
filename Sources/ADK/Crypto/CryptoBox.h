//
//  CryptoBox.h
//  ADK
//

#import "../Types/CryptoTypes.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Error domain and codes

extern NSString *const CryptoBoxErrorDomain;

typedef NS_ENUM(NSInteger, CryptoBoxErrorCode) {
    /// Failed to decode a Base64-encoded string.
    CryptoBoxErrorInvalidBase64 = 2000,
    /// A key did not have the expected byte length for TweetNaCl.
    CryptoBoxErrorInvalidKeyLength,
    /// The encrypted payload is too short to contain a valid nonce prefix.
    CryptoBoxErrorDataTooShort,
    /// The decrypted bytes could not be interpreted as UTF-8.
    CryptoBoxErrorUTF8DecodeFailed,
    /// SecRandomCopyBytes failed to produce cryptographic random data.
    CryptoBoxErrorRandomGenerationFailed,
    /// The underlying TweetNaCl C call returned a non-zero error code.
    CryptoBoxErrorCryptoOperationFailed,
};

// MARK: - CryptoBox
@interface CryptoBox : NSObject

/// Standard Curve25519 public key length in bytes (32).
+ (NSInteger)publicKeyLength;

/// Standard Curve25519 secret key length in bytes (32).
+ (NSInteger)secretKeyLength;

/// Standard XSalsa20 nonce length in bytes (24).
+ (NSInteger)nonceLength;

+ (nullable KeyPairType *)generateKeyPair:(NSError **)error;
+ (nullable NSString *)encrypt:(NSString *)message
                     publicKey:(NSString *)publicKey
                    privateKey:(NSString *)privateKey
                         error:(NSError **)error;
+ (nullable NSString *)decrypt:(NSString *)encryptedData
                     publicKey:(NSString *)publicKey
                    privateKey:(NSString *)privateKey
                         error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
