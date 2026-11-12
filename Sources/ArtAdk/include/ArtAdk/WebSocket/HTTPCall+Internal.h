#ifndef ARTADK_WEBSOCKET_HTTPCALL_INTERNAL_H
#define ARTADK_WEBSOCKET_HTTPCALL_INTERNAL_H

#pragma once

//
//  HTTPCall+Internal.h
//  ADK
//
//  Request building, bounded requests and multipart bodies shared by auth,
//  the socket and storage. Not part of the public API.
//

#import "HTTPCall.h"

NS_ASSUME_NONNULL_BEGIN

@class ARTFormDataFile;

@interface ARTHTTPClient (Internal)

/// Sends `request` through `session`, abandoned after `timeoutMs`
/// milliseconds: the request is cancelled and the completion gets the error
/// from `timeoutError`.
+ (void)sendRequest:(NSURLRequest *)request
          timeoutMs:(NSInteger)timeoutMs
       timeoutError:(NSError * (^)(void))timeoutError
         completion:(void (^)(NSData *_Nullable data,
                              NSURLResponse *_Nullable response,
                              NSError *_Nullable error))completion;

/// Builds the request `call:options:completion:` sends: a fresh token, the
/// URL, the ART headers, the body and the timeout.
+ (void)authorizedRequest:(NSString *)endpoint
                  options:(nullable CallApiProps *)options
               completion:(void (^)(NSMutableURLRequest *_Nullable request,
                                    NSError *_Nullable error))completion;

/// Decodes a REST response. Returns NO and sets `error` for a non-2xx
/// response or invalid JSON; `result` is nil for a 204 or empty body.
+ (BOOL)decodeData:(nullable NSData *)data
          response:(nullable NSURLResponse *)response
          endpoint:(NSString *)endpoint
            result:(id _Nullable *_Nullable)result
             error:(NSError **)error;

@end

/// Builds `multipart/form-data` bodies: text fields first, then files.
/// Fields are `@[name, value]` pairs.
@interface ARTMultipartBody : NSObject

@property(nonatomic, copy, readonly) NSString *boundary;
@property(nonatomic, copy, readonly) NSString *contentType;

/// The whole body in memory.
- (NSData *)encodeFields:(NSArray<NSArray<NSString *> *> *)fields
                   files:(NSArray<ARTFormDataFile *> *)files;

/// Writes a body with one file part, copied from `source` in chunks, to
/// `destination`, so large files are never held in memory.
- (BOOL)writeFields:(NSArray<NSArray<NSString *> *> *)fields
              field:(NSString *)field
           filename:(NSString *)filename
        contentType:(NSString *)contentType
             source:(NSURL *)source
                 to:(NSURL *)destination
              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_WEBSOCKET_HTTPCALL_INTERNAL_H */
