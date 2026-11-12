//
//  ARTStorage.m
//  ADK
//

#import "ARTStorage.h"
#import "ARTSupport.h"
#import "Auth.h"
#import "AuthTypes.h"
#import "HTTPCall+Internal.h"
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

/// Reports upload progress while the body is sent (1 is left for the moment
/// the server has stored the file) and the final result of the upload.
@interface ARTUploadTaskDelegate : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, copy, nullable) void (^progress)(double fraction);
@property(nonatomic, copy, nullable) void (^finished)(NSData *data,
                                                      NSURLResponse *_Nullable response,
                                                      NSError *_Nullable error);
@property(nonatomic, strong) NSMutableData *received;
@end

@implementation ARTUploadTaskDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _received = [NSMutableData data];
    }
    return self;
}

- (void)URLSession:(NSURLSession *)session
                        task:(NSURLSessionTask *)task
             didSendBodyData:(int64_t)bytesSent
              totalBytesSent:(int64_t)totalBytesSent
    totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    if (totalBytesExpectedToSend > 0 && totalBytesSent < totalBytesExpectedToSend &&
        self.progress) {
        self.progress((double)totalBytesSent / (double)totalBytesExpectedToSend);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    [self.received appendData:data];
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    if (self.finished) {
        self.finished(self.received, task.response, error);
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

    NSError *validationError = nil;
    AuthenticationConfig *credentials =
        [self credentials:@"call connect() before upload()" error:&validationError];
    if (!credentials) {
        completion(nil, validationError);
        return;
    }
    NSString *threadId = [self requireThreadId:opts.threadId error:&validationError];
    if (!threadId) {
        completion(nil, validationError);
        return;
    }
    NSString *fileName = opts.filename ?: filename ?: @"upload.bin";
    NSString *configId = opts.configId ?: credentials.projectKey ?: @"";

    NSMutableArray<NSArray<NSString *> *> *fields = [NSMutableArray array];
    [fields addObject:@[ @"owner_config_id", configId ]];
    [fields addObject:@[ @"thread_id", threadId ]];
    if (opts.ttlSeconds) {
        [fields addObject:@[ @"ttl_seconds", opts.ttlSeconds.stringValue ]];
    }
    if (opts.allowedMimeTypes.count > 0) {
        [fields addObject:@[
            @"allowed_mime_types",
            [ARTJSON stringify:opts.allowedMimeTypes error:nil] ?: @"[]"
        ]];
    }

    if (opts.progress) {
        opts.progress(0);
    }
    [self sendUploadData:data
                 fileURL:fileURL
                  fields:fields
                filename:fileName
             contentType:contentType
                 baseUrl:[self baseUrl:credentials]
                 options:opts
              completion:^(NSDictionary *object, NSError *uploadError) {
                if (uploadError) {
                    completion(nil, uploadError);
                    return;
                }
                NSString *objectId = [ARTJSON stringValue:object[@"id"]];
                if (!objectId) {
                    completion(nil, ARTUploadError(ARTUploadStepUpload,
                                                   @"Datalake upload did not return "
                                                   @"an object ID",
                                                   nil, nil));
                    return;
                }
                if (opts.progress) {
                    opts.progress(1);
                }

                NSString *path = [NSString
                    stringWithFormat:@"/objects/%@/access-url",
                                     [ARTEncoding uriComponent:objectId]];
                [self datalakeCall:ARTUploadStepGet
                            method:@"POST"
                              path:path
                             query:[self accessQuery:configId threadId:threadId]
                         timeoutMs:opts.timeoutMs
                        completion:^(id access, NSError *accessError) {
                          if (accessError) {
                              completion(nil, accessError);
                              return;
                          }
                          id readUrl = [access isKindOfClass:[NSDictionary class]]
                                           ? ((NSDictionary *)access)[@"read_url"]
                                           : nil;
                          id storedName = object[@"name"];
                          id storedType = object[@"content_type"];
                          NSNumber *size = [ARTJSON integerValue:object[@"size_bytes"]];
                          completion(
                              [[ARTFileRef alloc]
                                  initWithFileId:objectId
                                            name:([storedName isKindOfClass:[NSString class]] &&
                                                  [storedName length] > 0)
                                                     ? storedName
                                                     : fileName
                                         readUrl:[readUrl isKindOfClass:[NSString class]]
                                                     ? readUrl
                                                     : @""
                                            size:size ? size.integerValue : byteCount
                                     contentType:([storedType isKindOfClass:[NSString class]] &&
                                                  [storedType length] > 0)
                                                     ? storedType
                                                     : contentType],
                              nil);
                        }];
              }];
}

#pragma mark List / get / delete

- (void)listFilesWithOptions:(ARTListOptions *)options
                  completion:(ARTListFilesCompletion)completion {
    NSError *validationError = nil;
    NSString *configId = options.configId;
    if (!configId) {
        AuthenticationConfig *credentials =
            [self credentials:@"call connect() before using storage"
                        error:&validationError];
        if (!credentials) {
            completion(nil, validationError);
            return;
        }
        configId = credentials.projectKey ?: @"";
    }
    NSString *threadId = [self requireThreadId:options.threadId error:&validationError];
    if (!threadId) {
        completion(nil, validationError);
        return;
    }

    NSMutableArray<NSArray<NSString *> *> *query =
        [[self accessQuery:configId threadId:threadId] mutableCopy];
    if (options.page) {
        [query addObject:@[ @"page", options.page.stringValue ]];
    }
    if (options.limit) {
        [query addObject:@[ @"page_size", options.limit.stringValue ]];
    }

    [self datalakeCall:ARTUploadStepList
                method:@"GET"
                  path:@"/objects"
                 query:query
             timeoutMs:nil
            completion:^(id response, NSError *error) {
              if (error) {
                  completion(nil, error);
                  return;
              }
              NSDictionary *json =
                  [response isKindOfClass:[NSDictionary class]] ? response : nil;
              NSMutableArray<ARTStorageFile *> *files = [NSMutableArray array];
              id rawFiles = json[@"data"];
              if ([rawFiles isKindOfClass:[NSArray class]]) {
                  for (id item in (NSArray *)rawFiles) {
                      if ([item isKindOfClass:[NSDictionary class]]) {
                          [files addObject:[self storageFileFrom:item readUrl:nil]];
                      }
                  }
              }
              id meta = json[@"meta"];
              NSNumber *total = [meta isKindOfClass:[NSDictionary class]]
                                    ? [ARTJSON integerValue:((NSDictionary *)meta)[@"total"]]
                                    : nil;
              completion([[ARTStorageFileList alloc]
                             initWithFiles:files
                                     total:total ? total.integerValue
                                                 : (NSInteger)files.count],
                         nil);
            }];
}

- (void)getFile:(NSString *)fileId
       threadId:(NSString *)threadId
      timeoutMs:(NSNumber *)timeoutMs
     completion:(ARTGetFileCompletion)completion {
    NSError *validationError = nil;
    AuthenticationConfig *credentials =
        [self credentials:@"call connect() before using storage" error:&validationError];
    if (!credentials) {
        completion(nil, validationError);
        return;
    }
    NSString *thread = [self requireThreadId:threadId error:&validationError];
    if (!thread) {
        completion(nil, validationError);
        return;
    }
    NSArray<NSArray<NSString *> *> *query =
        [self accessQuery:credentials.projectKey ?: @"" threadId:thread];
    NSString *path = [NSString
        stringWithFormat:@"/objects/%@", [ARTEncoding uriComponent:fileId ?: @""]];

    [self datalakeCall:ARTUploadStepGet
                method:@"GET"
                  path:path
                 query:query
             timeoutMs:timeoutMs
            completion:^(id object, NSError *error) {
              if (error) {
                  completion(nil, error);
                  return;
              }
              [self datalakeCall:ARTUploadStepGet
                          method:@"POST"
                            path:[path stringByAppendingString:@"/access-url"]
                           query:query
                       timeoutMs:timeoutMs
                      completion:^(id access, NSError *accessError) {
                        if (accessError) {
                            completion(nil, accessError);
                            return;
                        }
                        id readUrl = [access isKindOfClass:[NSDictionary class]]
                                         ? ((NSDictionary *)access)[@"read_url"]
                                         : nil;
                        completion(
                            [self storageFileFrom:[object isKindOfClass:[NSDictionary class]]
                                                      ? object
                                                      : @{}
                                          readUrl:[readUrl isKindOfClass:[NSString class]]
                                                      ? readUrl
                                                      : nil],
                            nil);
                      }];
            }];
}

- (void)deleteFile:(NSString *)fileId
              hard:(BOOL)hard
         timeoutMs:(NSNumber *)timeoutMs
        completion:(void (^)(NSError *_Nullable))completion {
    NSString *path = [NSString
        stringWithFormat:@"/objects/%@", [ARTEncoding uriComponent:fileId ?: @""]];
    [self datalakeCall:ARTUploadStepDelete
                method:@"DELETE"
                  path:path
                 query:@[]
             timeoutMs:timeoutMs
            completion:^(id response, NSError *error) {
              completion(error);
            }];
}

#pragma mark Helpers

- (ARTStorageFile *)storageFileFrom:(NSDictionary *)object
                            readUrl:(nullable NSString *)readUrl {
    NSString * (^string)(NSString *) = ^NSString *(NSString *key) {
      id value = object[key];
      return [value isKindOfClass:[NSString class]] ? value : @"";
    };
    id expires = object[@"expires_at"];
    NSNumber *size = [ARTJSON integerValue:object[@"size_bytes"]];
    return [[ARTStorageFile alloc]
        initWithFileId:[ARTJSON stringValue:object[@"id"]] ?: @""
                  name:string(@"name")
            configType:ARTConfigTypeMedia
              configId:string(@"owner_config_id")
                  size:size ? size.integerValue : 0
           contentType:string(@"content_type")
                status:@"active"
             createdAt:string(@"created_at")
             expiresAt:[expires isKindOfClass:[NSString class]] ? expires : nil
               readUrl:readUrl];
}

- (nullable AuthenticationConfig *)credentials:(NSString *)message
                                         error:(NSError **)error {
    Auth *auth = [Auth getInstance:nil error:nil];
    if (!auth) {
        if (error) {
            *error = ARTUploadError(ARTUploadStepValidate, message, nil, nil);
        }
        return nil;
    }
    return [auth getCredentials];
}

- (nullable NSString *)requireThreadId:(nullable NSString *)threadId
                                 error:(NSError **)error {
    NSString *value = [threadId
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (value.length == 0) {
        if (error) {
            *error = ARTUploadError(ARTUploadStepValidate,
                                    @"threadId is required for temporary media", nil, nil);
        }
        return nil;
    }
    return value;
}

- (NSArray<NSArray<NSString *> *> *)accessQuery:(NSString *)configId
                                       threadId:(NSString *)threadId {
    return @[ @[ @"accessible_by", configId ], @[ @"thread_id", threadId ] ];
}

- (NSString *)baseUrl:(AuthenticationConfig *)credentials {
    return [NSString
        stringWithFormat:@"%@/api/%@/datalake/v1/system-buckets/temp", ARTGateway.restBase,
                         [ARTEncoding uriComponent:credentials.orgTitle ?: @""]];
}

/// The error reported for a failed `step`: keeps the status, since a 403
/// means the tenant role lacks storage permission.
- (NSError *)uploadError:(ARTUploadStep)step underlying:(NSError *)error {
    if ([error.domain isEqualToString:ARTUploadErrorDomain]) {
        return error;
    }
    NSString *message = error.userInfo[ARTHTTPMessageKey] ?: error.localizedDescription;
    return ARTUploadError(step,
                          [NSString stringWithFormat:@"Datalake %@ failed: %@",
                                                     ARTUploadStepName(step), message],
                          error.userInfo[ARTHTTPStatusCodeKey], error);
}

/// Calls the temporary-media bucket. Completes with the response's `data`, or
/// `{data, meta}` for `ARTUploadStepList`.
- (void)datalakeCall:(ARTUploadStep)step
              method:(NSString *)method
                path:(NSString *)path
               query:(NSArray<NSArray<NSString *> *> *)query
           timeoutMs:(nullable NSNumber *)timeoutMs
          completion:(void (^)(id _Nullable result, NSError *_Nullable error))completion {
    NSError *validationError = nil;
    AuthenticationConfig *credentials =
        [self credentials:@"call connect() before using storage" error:&validationError];
    if (!credentials) {
        completion(nil, validationError);
        return;
    }
    NSString *endpoint =
        query.count > 0
            ? [NSString stringWithFormat:@"%@?%@", path,
                                         [ARTEncoding formQueryWithPairs:query]]
            : path;
    CallApiProps *props = [[CallApiProps alloc] initWithMethod:method
                                                       payload:nil
                                                   queryParams:nil
                                                       headers:nil
                                                       baseUrl:[self baseUrl:credentials]
                                                     timeoutMs:timeoutMs];
    [ARTHTTPClient
              call:endpoint
           options:props
        completion:^(id json, NSError *error) {
          if (error) {
              completion(nil, [self uploadError:step underlying:error]);
              return;
          }
          NSDictionary *map = [json isKindOfClass:[NSDictionary class]] ? json : @{};
          if (step == ARTUploadStepList) {
              completion(@{
                  @"data" : map[@"data"] ?: @[],
                  @"meta" : map[@"meta"] ?: @{}
              },
                         nil);
              return;
          }
          completion(map[@"data"], nil);
        }];
}

/// POSTs the multipart upload with its own session so progress can be
/// reported; file bodies are staged in a temporary file and streamed.
- (void)sendUploadData:(nullable NSData *)data
               fileURL:(nullable NSURL *)fileURL
                fields:(NSArray<NSArray<NSString *> *> *)fields
              filename:(NSString *)filename
           contentType:(NSString *)contentType
               baseUrl:(NSString *)baseUrl
               options:(ARTUploadOptions *)options
            completion:(void (^)(NSDictionary *_Nullable object,
                                 NSError *_Nullable error))completion {
    CallApiProps *props =
        [[CallApiProps alloc] initWithMethod:@"POST"
                                     payload:nil
                                 queryParams:nil
                                     headers:nil
                                     baseUrl:baseUrl
                                   timeoutMs:options.timeoutMs ?: @60000];
    [ARTHTTPClient
        authorizedRequest:@"/objects"
                  options:props
               completion:^(NSMutableURLRequest *request, NSError *requestError) {
                 if (!request) {
                     completion(nil, [self uploadError:ARTUploadStepUpload
                                            underlying:requestError]);
                     return;
                 }
                 // The token may be cached, so this can still be the caller's
                 // queue: don't copy the file on it.
                 dispatch_async(
                     dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                       [self startUpload:request
                                    data:data
                                 fileURL:fileURL
                                  fields:fields
                                filename:filename
                             contentType:contentType
                                 options:options
                              completion:completion];
                     });
               }];
}

- (void)startUpload:(NSMutableURLRequest *)request
               data:(nullable NSData *)data
            fileURL:(nullable NSURL *)fileURL
             fields:(NSArray<NSArray<NSString *> *> *)fields
           filename:(NSString *)filename
        contentType:(NSString *)contentType
            options:(ARTUploadOptions *)options
         completion:(void (^)(NSDictionary *_Nullable object,
                              NSError *_Nullable error))completion {
    ARTMultipartBody *multipart = [[ARTMultipartBody alloc] init];
    [request setValue:multipart.contentType forHTTPHeaderField:@"Content-Type"];

    NSURL *stagedFile = nil;
    if (fileURL) {
        stagedFile = [NSURL
            fileURLWithPath:[NSTemporaryDirectory()
                                stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"art-upload-%@",
                                                               NSUUID.UUID.UUIDString]]];
        NSError *stageError = nil;
        if (![multipart writeFields:fields
                              field:@"file"
                           filename:filename
                        contentType:contentType
                             source:fileURL
                                 to:stagedFile
                              error:&stageError]) {
            [[NSFileManager defaultManager] removeItemAtURL:stagedFile error:nil];
            completion(nil, [self uploadError:ARTUploadStepUpload underlying:stageError]);
            return;
        }
    }

    ARTUploadTaskDelegate *delegate = [[ARTUploadTaskDelegate alloc] init];
    delegate.progress = options.progress;
    delegate.finished = ^(NSData *received, NSURLResponse *response, NSError *error) {
      if (stagedFile) {
          [[NSFileManager defaultManager] removeItemAtURL:stagedFile error:nil];
      }
      if ([error.domain isEqualToString:NSURLErrorDomain] &&
          error.code == NSURLErrorTimedOut) {
          completion(nil, ARTUploadError(ARTUploadStepUpload,
                                         @"Datalake upload timed out", nil, error));
          return;
      }
      if (error) {
          completion(nil, [self uploadError:ARTUploadStepUpload underlying:error]);
          return;
      }
      id json = nil;
      NSError *decodeError = nil;
      if (![ARTHTTPClient decodeData:received
                            response:response
                            endpoint:@"/objects"
                              result:&json
                               error:&decodeError]) {
          completion(nil, [self uploadError:ARTUploadStepUpload underlying:decodeError]);
          return;
      }
      id object = [json isKindOfClass:[NSDictionary class]]
                      ? ((NSDictionary *)json)[@"data"]
                      : nil;
      completion([object isKindOfClass:[NSDictionary class]] ? object : @{}, nil);
    };

    NSURLSession *session =
        [NSURLSession sessionWithConfiguration:ARTHTTPClient.uploadConfiguration
                                      delegate:delegate
                                 delegateQueue:nil];
    NSURLSessionUploadTask *task;
    if (stagedFile) {
        task = [session uploadTaskWithRequest:request fromFile:stagedFile];
    } else {
        ARTFormDataFile *file = [[ARTFormDataFile alloc] initWithField:@"file"
                                                                  data:data ?: [NSData data]
                                                              filename:filename
                                                           contentType:contentType];
        task = [session uploadTaskWithRequest:request
                                     fromData:[multipart encodeFields:fields files:@[ file ]]];
    }
    [task resume];
    // Releases the session (and its delegate) once the upload finishes.
    [session finishTasksAndInvalidate];
}

@end
