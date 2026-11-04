#ifndef ARTADK_STORAGE_ARTSTORAGE_H
#define ARTADK_STORAGE_ARTSTORAGE_H

#pragma once

//
//  ARTStorage.h
//  ADK
//
//  Temporary media, scoped to a conversation thread and owned by a
//  configuration (an agent, an orchestrator, or the project by default):
//
//    upload  POST   {gateway}/api/{tenant}/datalake/v1/system-buckets/temp/objects
//            multipart: file, owner_config_id, thread_id, ttl_seconds?,
//            allowed_mime_types? → then POST /objects/{id}/access-url
//    list    GET    /objects?accessible_by=&thread_id=&page=&page_size=
//    get     GET    /objects/{id} + POST /objects/{id}/access-url
//    delete  DELETE /objects/{id}
//
//  To let an agent use an uploaded file, attach it to a run:
//
//      [thread uploadFileURL:url options:nil
//                 completion:^(ARTFileRef *file, NSError *error) {
//          [thread run:@"Summarize this"
//              replyId:nil
//             fileMeta:@[ [ARTMediaRef mediaRefWithFileRef:file] ]
//           completion:^(Run *run, NSError *error) { ... }];
//      }];
//

#import "ARTStorageModels.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ARTUploadCompletion)(ARTFileRef *_Nullable fileRef,
                                    NSError *_Nullable error);
typedef void (^ARTListFilesCompletion)(ARTStorageFileList *_Nullable list,
                                       NSError *_Nullable error);
typedef void (^ARTGetFileCompletion)(ARTStorageFile *_Nullable file,
                                     NSError *_Nullable error);

/// Storage API. Errors use `ARTUploadErrorDomain`, with the failed step as
/// the error code. Call `-[Adk connect:completion:]` first.
@interface ARTStorage : NSObject

/// Uploads a local file (for example a document picker result), streaming
/// it from disk. The name and MIME type come from the URL;
/// `options.filename` overrides the name. `options.threadId` is required.
///
/// Fails with `ARTUploadStepValidate` when the file is empty, the thread id
/// is missing or the ADK is not connected, and with `ARTUploadStepUpload` or
/// `ARTUploadStepGet` when the server rejects the request.
- (void)uploadFileURL:(NSURL *)fileURL
              options:(nullable ARTUploadOptions *)options
           completion:(ARTUploadCompletion)completion;

/// Uploads bytes from memory. `options.threadId` is required.
///
/// @param filename used when `options.filename` is not set, else
///        `upload.bin`.
/// @param contentType MIME type; defaults to `application/octet-stream`.
- (void)uploadData:(NSData *)data
          filename:(nullable NSString *)filename
       contentType:(nullable NSString *)contentType
           options:(nullable ARTUploadOptions *)options
        completion:(ARTUploadCompletion)completion;

/// Lists the files `options.configId` (default: the project key) can access
/// in `options.threadId` (required). Files carry no `readUrl`.
- (void)listFilesWithOptions:(nullable ARTListOptions *)options
                  completion:(ARTListFilesCompletion)completion;

/// Fetches the metadata and a read URL of the file `fileId` in `threadId`.
- (void)getFile:(NSString *)fileId
       threadId:(NSString *)threadId
      timeoutMs:(nullable NSNumber *)timeoutMs
     completion:(ARTGetFileCompletion)completion;

/// Deletes the file `fileId`. `hard` is ignored: files are always removed.
- (void)deleteFile:(NSString *)fileId
              hard:(BOOL)hard
         timeoutMs:(nullable NSNumber *)timeoutMs
        completion:(void (^)(NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_STORAGE_ARTSTORAGE_H */
