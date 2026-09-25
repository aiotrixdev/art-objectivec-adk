#ifndef ARTADK_STORAGE_ARTSTORAGE_H
#define ARTADK_STORAGE_ARTSTORAGE_H

#pragma once

//
//  ARTStorage.h
//  ADK
//
//  File storage on the ART gateway.
//
//  An upload takes three steps:
//    1. POST {gateway}/api/{tenant}/storage/upload/signed-url
//       { config_type, config_id, file_name, file_size, content_type,
//         scopes, ttl_seconds? } → { file_id, upload_url }
//    2. PUT upload_url (the file bytes; no ART auth on the signed URL)
//    3. POST {gateway}/api/{tenant}/storage/upload/confirm/{file_id}
//       → { read_url, file }
//
//  To let an agent use an uploaded file, attach it to a run:
//
//      [agent uploadFileURL:url options:nil
//                completion:^(ARTFileRef *file, NSError *error) {
//          [thread run:@"Summarize this"
//              replyId:nil
//             fileMeta:@[ [ARTFileMeta fileMetaWithFileRef:file] ]
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
/// `options.filename` overrides the name.
- (void)uploadFileURL:(NSURL *)fileURL
              options:(nullable ARTUploadOptions *)options
           completion:(ARTUploadCompletion)completion;

/// Uploads bytes from memory.
///
/// @param filename used when `options.filename` is not set, else
///        `upload.bin`.
/// @param contentType MIME type; defaults to `application/octet-stream`.
- (void)uploadData:(NSData *)data
          filename:(nullable NSString *)filename
       contentType:(nullable NSString *)contentType
           options:(nullable ARTUploadOptions *)options
        completion:(ARTUploadCompletion)completion;

/// Lists stored files, optionally filtered by storage group.
- (void)listFilesWithOptions:(nullable ARTListOptions *)options
                  completion:(ARTListFilesCompletion)completion;

/// Fetches one file's details, including a signed `readUrl`.
- (void)getFile:(NSString *)fileId
      timeoutMs:(nullable NSNumber *)timeoutMs
     completion:(ARTGetFileCompletion)completion;

/// Deletes a file. `hard` removes it permanently.
- (void)deleteFile:(NSString *)fileId
              hard:(BOOL)hard
         timeoutMs:(nullable NSNumber *)timeoutMs
        completion:(void (^)(NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* ARTADK_STORAGE_ARTSTORAGE_H */
