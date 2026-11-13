//
//  ARTStorageModels.m
//  ADK
//

#import "ARTStorageModels.h"

ARTConfigType const ARTConfigTypeMedia = @"media";
ARTConfigType const ARTConfigTypeKnowledgeBase = @"knowledge_base";

NSErrorDomain const ARTUploadErrorDomain = @"com.art.adk.storage";
NSErrorUserInfoKey const ARTUploadStepNameKey = @"ARTUploadStepName";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
NSString *ARTUploadStepName(ARTUploadStep step) {
    switch (step) {
    case ARTUploadStepValidate:
        return @"validate";
    case ARTUploadStepUpload:
        return @"upload";
    case ARTUploadStepSignedURL:
        return @"signed-url";
    case ARTUploadStepPut:
        return @"put";
    case ARTUploadStepConfirm:
        return @"confirm";
    case ARTUploadStepList:
        return @"list";
    case ARTUploadStepGet:
        return @"get";
    case ARTUploadStepDelete:
        return @"delete";
    }
    return @"validate";
}
#pragma clang diagnostic pop

#pragma mark - ARTFileRef

@implementation ARTFileRef

- (instancetype)initWithFileId:(NSString *)fileId
                          name:(NSString *)name
                       readUrl:(NSString *)readUrl
                          size:(NSInteger)size
                   contentType:(NSString *)contentType {
    self = [super init];
    if (self) {
        _fileId = [fileId copy];
        _name = [name copy];
        _readUrl = [readUrl copy];
        _size = size;
        _contentType = [contentType copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[ARTFileRef class]]) {
        return NO;
    }
    ARTFileRef *other = object;
    return [self.fileId isEqualToString:other.fileId] &&
           [self.name isEqualToString:other.name] &&
           [self.readUrl isEqualToString:other.readUrl] &&
           self.size == other.size &&
           [self.contentType isEqualToString:other.contentType];
}

- (NSUInteger)hash {
    return self.fileId.hash ^ self.readUrl.hash;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<ARTFileRef %@ \"%@\" %ld bytes %@>",
                                      self.fileId, self.name, (long)self.size,
                                      self.contentType];
}

@end

#pragma mark - ARTStorageFile

@implementation ARTStorageFile

- (instancetype)initWithFileId:(NSString *)fileId
                          name:(NSString *)name
                    configType:(NSString *)configType
                      configId:(NSString *)configId
                          size:(NSInteger)size
                   contentType:(NSString *)contentType
                        status:(NSString *)status
                     createdAt:(NSString *)createdAt
                     expiresAt:(NSString *)expiresAt
                       readUrl:(NSString *)readUrl {
    self = [super init];
    if (self) {
        _fileId = [fileId copy];
        _name = [name copy];
        _configType = [configType copy];
        _configId = [configId copy];
        _size = size;
        _contentType = [contentType copy];
        _status = [status copy];
        _createdAt = [createdAt copy];
        _expiresAt = [expiresAt copy];
        _readUrl = [readUrl copy];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[ARTStorageFile class]]) {
        return NO;
    }
    ARTStorageFile *other = object;
    return [self.fileId isEqualToString:other.fileId] &&
           [self.status isEqualToString:other.status] &&
           (self.readUrl == other.readUrl ||
            [self.readUrl isEqualToString:other.readUrl]);
}

- (NSUInteger)hash {
    return self.fileId.hash;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<ARTStorageFile %@ \"%@\" %@/%@ %@>",
                                      self.fileId, self.name, self.configType,
                                      self.configId, self.status];
}

@end

#pragma mark - ARTStorageFileList

@implementation ARTStorageFileList

- (instancetype)initWithFiles:(NSArray<ARTStorageFile *> *)files
                        total:(NSInteger)total {
    self = [super init];
    if (self) {
        _files = [files copy] ?: @[];
        _total = total;
    }
    return self;
}

@end

#pragma mark - ARTMediaRef

@implementation ARTMediaRef

- (instancetype)initWithFileId:(NSString *)fileId
                          name:(NSString *)name
                   contentType:(NSString *)contentType {
    self = [super init];
    if (self) {
        _fileId = [fileId copy];
        _name = [name copy];
        _contentType = [contentType copy];
    }
    return self;
}

- (instancetype)initWithFileRef:(ARTFileRef *)fileRef {
    return [self initWithFileId:fileRef.fileId
                           name:fileRef.name
                    contentType:fileRef.contentType];
}

+ (instancetype)mediaRefWithFileRef:(ARTFileRef *)fileRef {
    return [[self alloc] initWithFileRef:fileRef];
}

+ (instancetype)fileMetaWithFileRef:(ARTFileRef *)fileRef {
    return [self mediaRefWithFileRef:fileRef];
}

- (instancetype)initWithFileRef:(ARTFileRef *)fileRef scope:(NSArray<NSString *> *)scope {
    return [self initWithFileRef:fileRef];
}

- (NSDictionary<NSString *, id> *)JSONObject {
    return @{
        @"id" : self.fileId ?: @"",
        @"name" : self.name ?: @"",
        @"content_type" : self.contentType ?: @""
    };
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[ARTMediaRef class]]) {
        return NO;
    }
    ARTMediaRef *other = object;
    return [self.fileId isEqualToString:other.fileId] &&
           [self.name isEqualToString:other.name] &&
           [self.contentType isEqualToString:other.contentType];
}

- (NSUInteger)hash {
    return self.fileId.hash;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<ARTMediaRef %@ \"%@\" %@>", self.fileId,
                                      self.name, self.contentType];
}

@end

#pragma mark - ARTUploadOptions

@implementation ARTUploadOptions

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
@synthesize scopes = _scopes;
#pragma clang diagnostic pop

- (instancetype)init {
    self = [super init];
    if (self) {
        _scopes = @[];
    }
    return self;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (NSArray<NSString *> *)scopes {
    return _scopes;
}

- (void)setScopes:(NSArray<NSString *> *)scopes {
    _scopes = [scopes copy] ?: @[];
}
#pragma clang diagnostic pop

- (id)copyWithZone:(NSZone *)zone {
    ARTUploadOptions *copy = [[ARTUploadOptions allocWithZone:zone] init];
    copy.filename = self.filename;
    copy.configType = self.configType;
    copy.configId = self.configId;
    copy.threadId = self.threadId;
    copy->_scopes = _scopes;
    copy.ttlSeconds = self.ttlSeconds;
    copy.allowedMimeTypes = self.allowedMimeTypes;
    copy.timeoutMs = self.timeoutMs;
    copy.progress = self.progress;
    return copy;
}

@end

#pragma mark - ARTListOptions

@implementation ARTListOptions

- (id)copyWithZone:(NSZone *)zone {
    ARTListOptions *copy = [[ARTListOptions allocWithZone:zone] init];
    copy.configType = self.configType;
    copy.configId = self.configId;
    copy.threadId = self.threadId;
    copy.page = self.page;
    copy.limit = self.limit;
    return copy;
}

@end
