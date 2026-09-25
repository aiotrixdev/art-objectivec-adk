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

/// Storage group type (`config_type`). Any server value can be used.
typedef NSString *ARTConfigType NS_TYPED_EXTENSIBLE_ENUM;
/// `media`, the default.
FOUNDATION_EXPORT ARTConfigType const ARTConfigTypeMedia;
/// `knowledge_base`.
FOUNDATION_EXPORT ARTConfigType const ARTConfigTypeKnowledgeBase;

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

#pragma mark - ARTFileMeta

/// An uploaded file attached to a message, sent as an entry of the frame's
/// top-level `file_meta` array (`{ "id": ..., "scope": [...] }`).
///
/// `scope` lists the config ids (for example agent ids) allowed to read the
/// file for this message. Empty means only the owner can.
@interface ARTFileMeta : NSObject <NSCopying>

@property(nonatomic, copy, readonly) NSString *fileId;
@property(nonatomic, copy, readonly) NSArray<NSString *> *scope;

- (instancetype)initWithFileId:(NSString *)fileId
                         scope:(nullable NSArray<NSString *> *)scope
    NS_DESIGNATED_INITIALIZER;
/// Attaches an uploaded file.
- (instancetype)initWithFileRef:(ARTFileRef *)fileRef
                          scope:(nullable NSArray<NSString *> *)scope;
+ (instancetype)fileMetaWithFileRef:(ARTFileRef *)fileRef;
- (instancetype)init NS_UNAVAILABLE;

/// The wire form: `{ "id": fileId, "scope": [...] }`.
- (NSDictionary<NSString *, id> *)JSONObject;

@end

#pragma mark - ARTUploadOptions

/// Options for uploads.
///
/// Scoped uploads (`Agent`, `AgentThread`, `Orchestrator`,
/// `OrchestratorThread`, `Subscription`) always replace `configId` with
/// their own id.
@interface ARTUploadOptions : NSObject <NSCopying>

/// File name sent to storage. Defaults to the file URL's last path
/// component (or the `filename` argument), else `upload.bin`.
@property(nonatomic, copy, nullable) NSString *filename;
/// Storage group type. Defaults to `ARTConfigTypeMedia`.
@property(nonatomic, copy, nullable) ARTConfigType configType;
/// Owning config id. Defaults to the project key for `-[Adk upload...]`.
@property(nonatomic, copy, nullable) NSString *configId;
/// Config ids granted access to the file. Empty means only the owner.
@property(nonatomic, copy) NSArray<NSString *> *scopes;
/// Optional expiry, in seconds.
@property(nonatomic, strong, nullable) NSNumber *ttlSeconds;
/// Per-request timeout in milliseconds. The upload itself defaults to
/// 60 000.
@property(nonatomic, strong, nullable) NSNumber *timeoutMs;
/// Upload progress, 0 to 1, for the transfer step. Called on a background
/// queue.
@property(nonatomic, copy, nullable) void (^progress)(double fraction);

@end

#pragma mark - ARTListOptions

/// Filters for `listFiles`.
@interface ARTListOptions : NSObject <NSCopying>

@property(nonatomic, copy, nullable) ARTConfigType configType;
/// Storage group to list. Scoped calls set it for you.
@property(nonatomic, copy, nullable) NSString *configId;
@property(nonatomic, strong, nullable) NSNumber *page;
@property(nonatomic, strong, nullable) NSNumber *limit;

@end

#pragma mark - Errors

/// Domain of storage errors. The error code is the `ARTUploadStep` that
/// failed; `userInfo[ARTHTTPStatusCodeKey]` holds the HTTP status when the
/// failure was an HTTP response (a 403 on `ARTUploadStepSignedURL` means
/// the tenant role has no storage permission).
FOUNDATION_EXPORT NSErrorDomain const ARTUploadErrorDomain;

/// `userInfo` key with the failed step's wire name, e.g. `signed-url`.
FOUNDATION_EXPORT NSErrorUserInfoKey const ARTUploadStepNameKey;

/// Storage step that failed.
typedef NS_ERROR_ENUM(ARTUploadErrorDomain, ARTUploadStep){
    ARTUploadStepValidate = 1,
    ARTUploadStepSignedURL,
    ARTUploadStepPut,
    ARTUploadStepConfirm,
    ARTUploadStepList,
    ARTUploadStepGet,
    ARTUploadStepDelete,
};

/// The step's wire name: `validate`, `signed-url`, `put`, `confirm`, `list`,
/// `get` or `delete`.
FOUNDATION_EXPORT NSString *ARTUploadStepName(ARTUploadStep step);

NS_ASSUME_NONNULL_END

#endif /* ARTADK_STORAGE_ARTSTORAGEMODELS_H */
