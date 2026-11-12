#ifndef ARTADK_STORAGE_ARTSTORAGEMODELS_H
#define ARTADK_STORAGE_ARTSTORAGEMODELS_H

#pragma once

//
//  ARTStorageModels.h
//  ADK
//
//  Storage models, request options and errors.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - ARTConfigType

/// Storage file category (`config_type`). Only `media` is supported.
typedef NSString *ARTConfigType NS_TYPED_EXTENSIBLE_ENUM;
/// `media`, the default.
FOUNDATION_EXPORT ARTConfigType const ARTConfigTypeMedia;
/// `knowledge_base`.
FOUNDATION_EXPORT ARTConfigType const ARTConfigTypeKnowledgeBase
    __attribute__((deprecated("Storage only holds media files.")));

#pragma mark - ARTFileRef

/// Result of a successful upload.
@interface ARTFileRef : NSObject <NSCopying>

@property(nonatomic, copy, readonly) NSString *fileId;
@property(nonatomic, copy, readonly) NSString *name;
/// Signed URL for reading the file.
@property(nonatomic, copy, readonly) NSString *readUrl;
@property(nonatomic, assign, readonly) NSInteger size;
@property(nonatomic, copy, readonly) NSString *contentType;

- (instancetype)initWithFileId:(NSString *)fileId
                          name:(NSString *)name
                       readUrl:(NSString *)readUrl
                          size:(NSInteger)size
                   contentType:(NSString *)contentType NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

#pragma mark - ARTStorageFile

/// A stored file, as returned by `listFiles` and `getFile`.
@interface ARTStorageFile : NSObject <NSCopying>

@property(nonatomic, copy, readonly) NSString *fileId;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *configType;
@property(nonatomic, copy, readonly) NSString *configId;
@property(nonatomic, assign, readonly) NSInteger size;
@property(nonatomic, copy, readonly) NSString *contentType;
@property(nonatomic, copy, readonly) NSString *status;
@property(nonatomic, copy, readonly) NSString *createdAt;
@property(nonatomic, copy, readonly, nullable) NSString *expiresAt;
/// Signed read URL. Present from `getFile`, absent from `listFiles`.
@property(nonatomic, copy, readonly, nullable) NSString *readUrl;

- (instancetype)initWithFileId:(NSString *)fileId
                          name:(NSString *)name
                    configType:(NSString *)configType
                      configId:(NSString *)configId
                          size:(NSInteger)size
                   contentType:(NSString *)contentType
                        status:(NSString *)status
                     createdAt:(NSString *)createdAt
                     expiresAt:(nullable NSString *)expiresAt
                       readUrl:(nullable NSString *)readUrl
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

#pragma mark - ARTStorageFileList

/// One page of `listFiles` results.
@interface ARTStorageFileList : NSObject

@property(nonatomic, copy, readonly) NSArray<ARTStorageFile *> *files;
@property(nonatomic, assign, readonly) NSInteger total;

- (instancetype)initWithFiles:(NSArray<ARTStorageFile *> *)files
                        total:(NSInteger)total NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

#pragma mark - ARTMediaRef

/// A file an agent request refers to, sent as an entry of the frame's
/// top-level `file_meta` array
/// (`{ "id": ..., "name": ..., "content_type": ... }`).
///
/// Build one from an upload result with `+mediaRefWithFileRef:`.
@interface ARTMediaRef : NSObject <NSCopying>

/// Storage id of the file.
@property(nonatomic, copy, readonly) NSString *fileId;
/// File name.
@property(nonatomic, copy, readonly) NSString *name;
/// MIME type of the file.
@property(nonatomic, copy, readonly) NSString *contentType;

- (instancetype)initWithFileId:(NSString *)fileId
                          name:(NSString *)name
                   contentType:(NSString *)contentType NS_DESIGNATED_INITIALIZER;
/// Refers to an uploaded file.
- (instancetype)initWithFileRef:(ARTFileRef *)fileRef;
+ (instancetype)mediaRefWithFileRef:(ARTFileRef *)fileRef;
- (instancetype)init NS_UNAVAILABLE;

/// Former name of `+mediaRefWithFileRef:`.
+ (instancetype)fileMetaWithFileRef:(ARTFileRef *)fileRef
    __attribute__((deprecated("Use +mediaRefWithFileRef:.")));
/// `scope` is ignored: access follows the owning configuration and thread.
- (instancetype)initWithFileRef:(ARTFileRef *)fileRef
                          scope:(nullable NSArray<NSString *> *)scope
    __attribute__((deprecated("Use -initWithFileRef:. Access follows the owning "
                              "configuration and thread.")));

/// The wire form: `{ "id": fileId, "name": name, "content_type": contentType }`.
- (NSDictionary<NSString *, id> *)JSONObject;

@end

/// Former name of `ARTMediaRef`.
typedef ARTMediaRef ARTFileMeta __attribute__((deprecated("Use ARTMediaRef.")));

#pragma mark - ARTUploadOptions

/// Options for uploads.
///
/// Uploads are temporary media scoped to a conversation thread, so
/// `threadId` is required; the thread-level upload helpers set it. Scoped
/// uploads (`Agent`, `AgentThread`, `Orchestrator`, `OrchestratorThread`,
/// `Subscription`) always set `configId` to their channel's configuration.
@interface ARTUploadOptions : NSObject <NSCopying>

/// File name sent to storage. Defaults to the file URL's last path
/// component (or the `filename` argument), else `upload.bin`.
@property(nonatomic, copy, nullable) NSString *filename;
/// Storage file category. Only `ARTConfigTypeMedia` is supported.
@property(nonatomic, copy, nullable) ARTConfigType configType;
/// Configuration that owns the file. Defaults to the project key for
/// `-[Adk upload...]`.
@property(nonatomic, copy, nullable) NSString *configId;
/// Thread the file belongs to. Required.
@property(nonatomic, copy, nullable) NSString *threadId;
/// No longer used: access follows the owning configuration and thread.
@property(nonatomic, copy) NSArray<NSString *> *scopes
    __attribute__((deprecated("Uploads are scoped to their thread; scopes are "
                              "ignored.")));
/// Time-to-live for the uploaded file, in seconds.
@property(nonatomic, strong, nullable) NSNumber *ttlSeconds;
/// MIME types the server should accept for this upload.
@property(nonatomic, copy, nullable) NSArray<NSString *> *allowedMimeTypes;
/// Per-request timeout in milliseconds. The upload itself defaults to
/// 60 000.
@property(nonatomic, strong, nullable) NSNumber *timeoutMs;
/// Upload progress from 0 to 1: 0 when the upload starts, fractions while
/// the bytes are sent, and 1 once the server has stored the file. Called on
/// a background queue.
@property(nonatomic, copy, nullable) void (^progress)(double fraction);

@end

#pragma mark - ARTListOptions

/// Filters for `listFiles`.
///
/// Files are listed per thread, so `threadId` is required; the thread-level
/// list helpers set it.
@interface ARTListOptions : NSObject <NSCopying>

/// Storage file category. Only `ARTConfigTypeMedia` is supported.
@property(nonatomic, copy, nullable) ARTConfigType configType;
/// List the files this configuration can access. Defaults to the project
/// key; scoped calls set it for you.
@property(nonatomic, copy, nullable) NSString *configId;
/// Thread whose files are listed. Required.
@property(nonatomic, copy, nullable) NSString *threadId;
/// Page number (1-based).
@property(nonatomic, strong, nullable) NSNumber *page;
/// Maximum files per page.
@property(nonatomic, strong, nullable) NSNumber *limit;

@end

#pragma mark - Errors

/// Domain of storage errors. The error code is the `ARTUploadStep` that
/// failed; `userInfo[ARTHTTPStatusCodeKey]` holds the HTTP status when the
/// failure was an HTTP response (a 403 means the tenant role has no storage
/// permission).
FOUNDATION_EXPORT NSErrorDomain const ARTUploadErrorDomain;

/// `userInfo` key with the failed step's wire name, e.g. `upload`.
FOUNDATION_EXPORT NSErrorUserInfoKey const ARTUploadStepNameKey;

/// Storage step that failed.
typedef NS_ERROR_ENUM(ARTUploadErrorDomain, ARTUploadStep){
    ARTUploadStepValidate = 1,
    /// No longer reported: an upload is a single request.
    ARTUploadStepSignedURL __attribute__((deprecated("Use ARTUploadStepUpload."))),
    /// No longer reported: an upload is a single request.
    ARTUploadStepPut __attribute__((deprecated("Use ARTUploadStepUpload."))),
    /// No longer reported: an upload is a single request.
    ARTUploadStepConfirm __attribute__((deprecated("Use ARTUploadStepUpload."))),
    ARTUploadStepList,
    ARTUploadStepGet,
    ARTUploadStepDelete,
    ARTUploadStepUpload,
};

/// The step's wire name: `validate`, `upload`, `list`, `get` or `delete`.
FOUNDATION_EXPORT NSString *ARTUploadStepName(ARTUploadStep step);

NS_ASSUME_NONNULL_END

#endif /* ARTADK_STORAGE_ARTSTORAGEMODELS_H */
