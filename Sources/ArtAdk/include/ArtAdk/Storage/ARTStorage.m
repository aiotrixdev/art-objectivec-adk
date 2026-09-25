//
//  ARTStorage.m
//  ADK
//

#import "ARTStorage.h"
#import "ARTSupport.h"
#import "Auth.h"
#import "AuthTypes.h"
#import "HTTPCall.h"
#import "SocketTypes.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const ARTDefaultContentType = @"application/octet-stream";

static NSError *ARTUploadError(ARTUploadStep step, NSString *message,
                               NSNumber *_Nullable status,
                               NSError *_Nullable underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message ?: @"";
    userInfo[ARTUploadStepNameKey] = ARTUploadStepName(step);
    if (status) {
        userInfo[ARTHTTPStatusCodeKey] = status;
    }
    if (underlying) {
        userInfo[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:ARTUploadErrorDomain
                               code:step
                           userInfo:userInfo];
}

static NSString *ARTMimeTypeForExtension(NSString *extension) {
    if (extension.length > 0) {
        if (@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)) {
            NSString *mime =
                [UTType typeWithFilenameExtension:extension].preferredMIMEType;
            if (mime.length > 0) {
                return mime;
            }
        }
    }
    return ARTDefaultContentType;
}

#pragma mark - Upload task delegate

/// Reports upload progress (0 to 1) and the final result of one PUT.
@interface ARTUploadTaskDelegate : NSObject <NSURLSessionTaskDelegate>
@property(nonatomic, copy, nullable) void (^progress)(double fraction);
@property(nonatomic, copy) void (^finished)(NSURLResponse *_Nullable response,
                                            NSError *_Nullable error);
@end

@implementation ARTUploadTaskDelegate

- (void)URLSession:(NSURLSession *)session
                        task:(NSURLSessionTask *)task
             didSendBodyData:(int64_t)bytesSent
              totalBytesSent:(int64_t)totalBytesSent
    totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    if (totalBytesExpectedToSend > 0 && self.progress) {
        self.progress((double)totalBytesSent / (double)totalBytesExpectedToSend);
    }
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    if (self.finished) {
        self.finished(task.response, error);
        self.finished = nil;
    }
}

@end

#pragma mark - ARTStorage

@implementation ARTStorage

#pragma mark Upload

- (void)uploadFileURL:(NSURL *)fileURL
              options:(ARTUploadOptions *)options
           completion:(ARTUploadCompletion)completion {
    BOOL scopedAccess = [fileURL startAccessingSecurityScopedResource];
    ARTUploadCompletion finish = ^(ARTFileRef *fileRef, NSError *error) {
      if (scopedAccess) {
          [fileURL stopAccessingSecurityScopedResource];
      }
      completion(fileRef, error);
    };

    NSString *name = fileURL.lastPathComponent ?: @"";
    NSNumber *isRegular = nil;
    NSNumber *size = nil;
    NSError *readError = nil;
    [fileURL getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
    if (isRegular && !isRegular.boolValue) {
        finish(nil, ARTUploadError(ARTUploadStepValidate,
                                   [NSString stringWithFormat:
                                                 @"%@ is not a regular file",
                                                 name],
                                   nil, nil));
        return;
    }
    if (![fileURL getResourceValue:&size
                            forKey:NSURLFileSizeKey
                             error:&readError] ||
        !size) {
        NSDictionary *attributes =
            [[NSFileManager defaultManager] attributesOfItemAtPath:fileURL.path
                                                             error:&readError];
        size = attributes[NSFileSize];
    }
    if (!size) {
        finish(nil, ARTUploadError(
                        ARTUploadStepValidate,
                        [NSString
                            stringWithFormat:@"failed to read file at %@: %@",
                                             name,
                                             readError.localizedDescription
                                                 ?: @"unknown error"],
                        nil, readError));
        return;
    }

    [self performUploadWithData:nil
                        fileURL:fileURL
                      byteCount:size.integerValue
                       filename:name
                    contentType:ARTMimeTypeForExtension(fileURL.pathExtension)
                        options:options
                     completion:finish];
}

- (void)uploadData:(NSData *)data
          filename:(NSString *)filename
       contentType:(NSString *)contentType
           options:(ARTUploadOptions *)options
        completion:(ARTUploadCompletion)completion {
    [self performUploadWithData:data ?: [NSData data]
                        fileURL:nil
                      byteCount:(NSInteger)data.length
                       filename:filename
                    contentType:contentType ?: ARTDefaultContentType
                        options:options
                     completion:completion];
}

- (void)performUploadWithData:(nullable NSData *)data
                      fileURL:(nullable NSURL *)fileURL
                    byteCount:(NSInteger)byteCount
                     filename:(nullable NSString *)filename
                  contentType:(NSString *)contentType
                      options:(nullable ARTUploadOptions *)options
                   completion:(ARTUploadCompletion)completion {
    ARTUploadOptions *opts = options ?: [[ARTUploadOptions alloc] init];

    if (byteCount <= 0) {
        completion(nil, ARTUploadError(ARTUploadStepValidate, @"file is empty",
                                       nil, nil));
        return;
    }

    Auth *auth = [Auth getInstance:nil error:nil];
    if (!auth) {
        completion(nil, ARTUploadError(ARTUploadStepValidate,
                                       @"call connect() before upload()", nil,
                                       nil));
        return;
    }

    NSString *fileName = opts.filename ?: filename ?: @"upload.bin";
    NSString *configId = opts.configId ?: [auth getCredentials].projectKey ?: @"";

    NSMutableDictionary *body = [@{
        @"config_type" : opts.configType ?: ARTConfigTypeMedia,
        @"config_id" : configId,
        @"file_name" : fileName,
        @"file_size" : @(byteCount),
        @"content_type" : contentType,
        @"scopes" : opts.scopes ?: @[],
    } mutableCopy];
    if (opts.ttlSeconds) {
        body[@"ttl_seconds"] = opts.ttlSeconds;
    }

    [self storageCall:ARTUploadStepSignedURL
               method:@"POST"
                 path:@"/upload/signed-url"
                 body:body
            timeoutMs:opts.timeoutMs
           completion:^(NSDictionary *initResponse, NSError *initError) {
             if (initError) {
                 completion(nil, initError);
                 return;
             }
             NSString *fileId =
                 [ARTJSON stringValue:initResponse[@"file_id"]];
             id uploadURLString = initResponse[@"upload_url"];
             NSURL *uploadURL = [uploadURLString isKindOfClass:[NSString class]]
                                    ? [NSURL URLWithString:uploadURLString]
                                    : nil;
             if (!fileId || !uploadURL) {
                 completion(nil,
                            ARTUploadError(ARTUploadStepSignedURL,
                                           @"signed-url missing "
                                           @"file_id/upload_url",
                                           nil, nil));
                 return;
             }

             [self putToStorage:uploadURL
                           data:data
                        fileURL:fileURL
                    contentType:contentType
                        options:opts
                     completion:^(NSError *putError) {
                       if (putError) {
                           completion(nil, putError);
                           return;
                       }
                       NSString *confirmPath = [NSString
                           stringWithFormat:@"/upload/confirm/%@",
                                            [ARTEncoding uriComponent:fileId]];
                       [self storageCall:ARTUploadStepConfirm
                                  method:@"POST"
                                    path:confirmPath
                                    body:nil
                               timeoutMs:opts.timeoutMs
                              completion:^(NSDictionary *done,
                                           NSError *confirmError) {
                                if (confirmError) {
                                    completion(nil, confirmError);
                                    return;
                                }
                                NSDictionary *file =
                                    [done[@"file"] isKindOfClass:[NSDictionary
                                                                    class]]
                                        ? done[@"file"]
                                        : nil;
                                id readUrl = done[@"read_url"];
                                NSNumber *size =
                                    [ARTJSON integerValue:file[@"file_size"]];
                                completion(
                                    [[ARTFileRef alloc]
                                        initWithFileId:fileId
                                                  name:fileName
                                               readUrl:[readUrl
                                                           isKindOfClass:
                                                               [NSString class]]
                                                           ? readUrl
                                                           : @""
                                                  size:size ? size.integerValue
                                                            : byteCount
                                           contentType:contentType],
                                    nil);
                              }];
                     }];
           }];
}

#pragma mark List / get / delete

- (void)listFilesWithOptions:(ARTListOptions *)options
                  completion:(ARTListFilesCompletion)completion {
    // Fixed parameter order; empty values are left out.
    NSMutableArray<NSArray<NSString *> *> *query = [NSMutableArray array];
    if (options.configType.length > 0) {
        [query addObject:@[ @"config_type", options.configType ]];
    }
    if (options.configId.length > 0) {
        [query addObject:@[ @"config_id", options.configId ]];
    }
    if (options.page) {
        [query addObject:@[ @"page", options.page.stringValue ]];
    }
    if (options.limit) {
        [query addObject:@[ @"limit", options.limit.stringValue ]];
    }
    NSString *path =
        query.count > 0
            ? [NSString stringWithFormat:@"/files?%@",
                                         [ARTEncoding formQueryWithPairs:query]]
            : @"/files";

    [self storageCall:ARTUploadStepList
               method:@"GET"
                 path:path
                 body:nil
            timeoutMs:nil
           completion:^(NSDictionary *data, NSError *error) {
             if (error) {
                 completion(nil, error);
                 return;
             }
             NSMutableArray<ARTStorageFile *> *files = [NSMutableArray array];
             id rawFiles = data[@"files"];
             if ([rawFiles isKindOfClass:[NSArray class]]) {
                 for (id item in (NSArray *)rawFiles) {
                     if ([item isKindOfClass:[NSDictionary class]]) {
                         [files addObject:[self storageFileFrom:item readUrl:nil]];
                     }
                 }
             }
             NSNumber *total = [ARTJSON integerValue:data[@"total"]];
             completion([[ARTStorageFileList alloc]
                            initWithFiles:files
                                    total:total ? total.integerValue : 0],
                        nil);
           }];
}

- (void)getFile:(NSString *)fileId
      timeoutMs:(NSNumber *)timeoutMs
     completion:(ARTGetFileCompletion)completion {
    NSString *path = [NSString
        stringWithFormat:@"/file/%@", [ARTEncoding uriComponent:fileId ?: @""]];
    [self storageCall:ARTUploadStepGet
               method:@"GET"
                 path:path
                 body:nil
            timeoutMs:timeoutMs
           completion:^(NSDictionary *data, NSError *error) {
             if (error) {
                 completion(nil, error);
                 return;
             }
             NSDictionary *file =
                 [data[@"file"] isKindOfClass:[NSDictionary class]]
                     ? data[@"file"]
                     : nil;
             id readUrl = data[@"read_url"];
             completion([self storageFileFrom:file
                                      readUrl:[readUrl isKindOfClass:[NSString
                                                                         class]]
                                                  ? readUrl
                                                  : nil],
                        nil);
           }];
}

- (void)deleteFile:(NSString *)fileId
              hard:(BOOL)hard
         timeoutMs:(NSNumber *)timeoutMs
        completion:(void (^)(NSError *_Nullable))completion {
    NSString *path =
        [NSString stringWithFormat:@"/file/%@%@",
                                   [ARTEncoding uriComponent:fileId ?: @""],
                                   hard ? @"/hard" : @""];
    [self storageCall:ARTUploadStepDelete
               method:@"DELETE"
                 path:path
                 body:nil
            timeoutMs:timeoutMs
           completion:^(NSDictionary *data, NSError *error) {
             completion(error);
           }];
}

#pragma mark Helpers

- (ARTStorageFile *)storageFileFrom:(nullable NSDictionary *)f
                            readUrl:(nullable NSString *)readUrl {
    NSString * (^string)(NSString *) = ^NSString *(NSString *key) {
      id value = f[key];
      return [value isKindOfClass:[NSString class]] ? value : @"";
    };
    id expires = f[@"expires_at"];
    id fileReadUrl = f[@"read_url"];
    NSNumber *size = [ARTJSON integerValue:f[@"file_size"]];
    return [[ARTStorageFile alloc]
        initWithFileId:[ARTJSON stringValue:f[@"id"]] ?: @""
                  name:string(@"original_name")
            configType:string(@"config_type")
              configId:string(@"config_id")
                  size:size ? size.integerValue : 0
           contentType:string(@"content_type")
                status:string(@"status")
             createdAt:string(@"created_at")
             expiresAt:[expires isKindOfClass:[NSString class]] ? expires : nil
               readUrl:readUrl ?: ([fileReadUrl isKindOfClass:[NSString class]]
                                       ? fileReadUrl
                                       : nil)];
}

/// Authenticated call to the storage API; completes with the `data` object.
- (void)storageCall:(ARTUploadStep)step
             method:(NSString *)method
               path:(NSString *)path
               body:(nullable NSDictionary *)body
          timeoutMs:(nullable NSNumber *)timeoutMs
         completion:(void (^)(NSDictionary *_Nullable data,
                              NSError *_Nullable error))completion {
    Auth *auth = [Auth getInstance:nil error:nil];
    if (!auth) {
        completion(nil, ARTUploadError(ARTUploadStepValidate,
                                       @"call connect() before using storage",
                                       nil, nil));
        return;
    }
    NSString *orgTitle = [auth getCredentials].orgTitle ?: @"";
    NSString *baseUrl =
        [NSString stringWithFormat:@"%@/api/%@/storage", ARTGateway.restBase,
                                   [ARTEncoding uriComponent:orgTitle]];

    CallApiProps *props = [[CallApiProps alloc] initWithMethod:method
                                                       payload:body
                                                   queryParams:nil
                                                       headers:nil
                                                       baseUrl:baseUrl
                                                     timeoutMs:timeoutMs];
    NSString *stepName = ARTUploadStepName(step);
    [ARTHTTPClient
              call:path
           options:props
        completion:^(id json, NSError *error) {
          if (error) {
              if ([error.domain isEqualToString:ARTUploadErrorDomain]) {
                  completion(nil, error);
                  return;
              }
              // Keep the status: a 403 on signed-url means the tenant role
              // has no storage permission.
              NSNumber *status = error.userInfo[ARTHTTPStatusCodeKey];
              completion(nil,
                         ARTUploadError(step,
                                        [NSString stringWithFormat:
                                                      @"storage %@ failed: %@",
                                                      stepName,
                                                      error.localizedDescription],
                                        status, error));
              return;
          }
          NSDictionary *root =
              [json isKindOfClass:[NSDictionary class]] ? json : nil;
          NSDictionary *data = [root[@"data"] isKindOfClass:[NSDictionary class]]
                                   ? root[@"data"]
                                   : @{};
          completion(data, nil);
        }];
}

/// PUTs the bytes to the signed storage URL, reporting progress through
/// `options.progress`. File bodies stream from disk.
- (void)putToStorage:(NSURL *)url
                data:(nullable NSData *)data
             fileURL:(nullable NSURL *)fileURL
         contentType:(NSString *)contentType
             options:(ARTUploadOptions *)options
          completion:(void (^)(NSError *_Nullable error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"PUT";
    [request setValue:@"BlockBlob" forHTTPHeaderField:@"x-ms-blob-type"];
    [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    request.timeoutInterval =
        (options.timeoutMs ? options.timeoutMs.doubleValue : 60000.0) / 1000.0;

    void (^progress)(double) = options.progress;
    if (progress) {
        progress(0);
    }

    ARTUploadTaskDelegate *delegate = [[ARTUploadTaskDelegate alloc] init];
    delegate.progress = progress;
    delegate.finished = ^(NSURLResponse *response, NSError *error) {
      if (error) {
          BOOL timedOut = [error.domain isEqualToString:NSURLErrorDomain] &&
                          error.code == NSURLErrorTimedOut;
          completion(ARTUploadError(ARTUploadStepPut,
                                    timedOut
                                        ? @"storage PUT timed out"
                                        : @"storage PUT failed (network/timeout)",
                                    nil, error));
          return;
      }
      NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                                    ? (NSHTTPURLResponse *)response
                                    : nil;
      if (!http || http.statusCode < 200 || http.statusCode >= 300) {
          NSNumber *status = http ? @(http.statusCode) : nil;
          completion(ARTUploadError(
              ARTUploadStepPut,
              [NSString stringWithFormat:@"storage PUT failed (%@)",
                                         status ? status.stringValue
                                                : @"no response"],
              status, nil));
          return;
      }
      if (progress) {
          progress(1);
      }
      completion(nil);
    };

    NSURLSession *session =
        [NSURLSession sessionWithConfiguration:ARTHTTPClient.uploadConfiguration
                                      delegate:delegate
                                 delegateQueue:nil];
    NSURLSessionUploadTask *task =
        fileURL ? [session uploadTaskWithRequest:request fromFile:fileURL]
                : [session uploadTaskWithRequest:request fromData:data ?: [NSData data]];
    [task resume];
    // Releases the session (and its delegate) once the upload finishes.
    [session finishTasksAndInvalidate];
}

@end
