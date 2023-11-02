// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#import <TargetConditionals.h>

#import <Firebase/Firebase.h>
#import <firebase_core/FLTFirebasePluginRegistry.h>
#import "FLTFirebaseStoragePlugin.h"
#import "FLTTaskStateChannelStreamHandler.h"

static NSString *const kFLTFirebaseStorageChannelName = @"plugins.flutter.io/firebase_storage";
static NSString *const kFLTFirebaseStorageKeyCacheControl = @"cacheControl";
static NSString *const kFLTFirebaseStorageKeyContentDisposition = @"contentDisposition";
static NSString *const kFLTFirebaseStorageKeyContentEncoding = @"contentEncoding";
static NSString *const kFLTFirebaseStorageKeyContentLanguage = @"contentLanguage";
static NSString *const kFLTFirebaseStorageKeyContentType = @"contentType";
static NSString *const kFLTFirebaseStorageKeyCustomMetadata = @"customMetadata";
static NSString *const kFLTFirebaseStorageKeyName = @"name";
static NSString *const kFLTFirebaseStorageKeyBucket = @"bucket";
static NSString *const kFLTFirebaseStorageKeyGeneration = @"generation";
static NSString *const kFLTFirebaseStorageKeyMetadataGeneration = @"metadataGeneration";
static NSString *const kFLTFirebaseStorageKeyFullPath = @"fullPath";
static NSString *const kFLTFirebaseStorageKeySize = @"size";
static NSString *const kFLTFirebaseStorageKeyCreationTime = @"creationTimeMillis";
static NSString *const kFLTFirebaseStorageKeyUpdatedTime = @"updatedTimeMillis";
static NSString *const kFLTFirebaseStorageKeyMD5Hash = @"md5Hash";
static NSString *const kFLTFirebaseStorageKeyAppName = @"appName";
static NSString *const kFLTFirebaseStorageKeyMaxOperationRetryTime = @"maxOperationRetryTime";
static NSString *const kFLTFirebaseStorageKeyMaxDownloadRetryTime = @"maxDownloadRetryTime";
static NSString *const kFLTFirebaseStorageKeyMaxUploadRetryTime = @"maxUploadRetryTime";
static NSString *const kFLTFirebaseStorageKeyPath = @"path";
static NSString *const kFLTFirebaseStorageKeySnapshot = @"snapshot";
static NSString *const kFLTFirebaseStorageKeyHandle = @"handle";
static NSString *const kFLTFirebaseStorageKeyMetadata = @"metadata";
static NSString *const kFLTFirebaseStorageKeyPageToken = @"pageToken";
static NSString *const kFLTFirebaseStorageKeyOptions = @"options";
static NSString *const kFLTFirebaseStorageKeyMaxResults = @"maxResults";
static NSString *const kFLTFirebaseStorageKeyItems = @"items";
static NSString *const kFLTFirebaseStorageKeyPrefixes = @"prefixes";
static NSString *const kFLTFirebaseStorageKeyNextPageToken = @"nextPageToken";
static NSString *const kFLTFirebaseStorageKeyMaxSize = @"maxSize";

typedef NS_ENUM(NSUInteger, FLTFirebaseStorageTaskState) {
  FLTFirebaseStorageTaskStateCancel = 0,
  FLTFirebaseStorageTaskStatePause = 1,
  FLTFirebaseStorageTaskStateResume = 2,
};

typedef NS_ENUM(NSUInteger, FLTFirebaseStorageTaskType) {
  FLTFirebaseStorageTaskTypeFile = 0,
  FLTFirebaseStorageTaskTypeBytes = 1,
  FLTFirebaseStorageTaskTypeDownload = 2,
  FLTFirebaseStorageTaskTypeString = 3,
};

typedef NS_ENUM(NSUInteger, FLTFirebaseStorageStringType) {
  // FLTFirebaseStorageStringTypeRaw = 0, // unused
  FLTFirebaseStorageStringTypeBase64 = 1,
  FLTFirebaseStorageStringTypeBase64URL = 2,
  // FLTFirebaseStorageStringTypeDataUrl = 3, // unused
};

@interface FLTFirebaseStoragePlugin ()
@property(nonatomic, retain) FlutterMethodChannel *storage_method_channel;

@end

@implementation FLTFirebaseStoragePlugin {
  NSMutableDictionary<NSNumber *, FIRStorageObservableTask<FIRStorageTaskManagement> *> *_tasks;
  dispatch_queue_t _callbackQueue;
  bool hasEmulatorBooted;
  NSObject<FlutterBinaryMessenger> *_binaryMessenger;
  NSMutableDictionary<NSString *, FlutterEventChannel *> *_eventChannels;
  NSMutableDictionary<NSString *, NSObject<FlutterStreamHandler> *> *_streamHandlers;
}

#pragma mark - FlutterPlugin

// Returns a singleton instance of the Firebase Storage plugin.
+ (instancetype)sharedInstance:(NSObject<FlutterBinaryMessenger> *)messenger {
  static dispatch_once_t onceToken;
  static FLTFirebaseStoragePlugin *instance;

  dispatch_once(&onceToken, ^{
    instance = [[FLTFirebaseStoragePlugin alloc] init:messenger];
    // Register with the Flutter Firebase plugin registry.
    [[FLTFirebasePluginRegistry sharedInstance] registerFirebasePlugin:instance];
  });

  return instance;
}

- (instancetype)init:(NSObject<FlutterBinaryMessenger> *)messenger {
  self = [super init];
  if (self) {
    _tasks = [NSMutableDictionary<NSNumber *, FIRStorageObservableTask<FIRStorageTaskManagement> *>
        dictionary];
    _callbackQueue =
        dispatch_queue_create("io.flutter.plugins.firebase.storage", DISPATCH_QUEUE_SERIAL);
    hasEmulatorBooted = false;
    _binaryMessenger = messenger;
    _eventChannels = [NSMutableDictionary dictionary];
    _streamHandlers = [NSMutableDictionary dictionary];
  }
  return self;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:kFLTFirebaseStorageChannelName
                                  binaryMessenger:[registrar messenger]];

  FLTFirebaseStoragePlugin *instance =
      [FLTFirebaseStoragePlugin sharedInstance:[registrar messenger]];
  if (instance.storage_method_channel != nil) {
    NSLog(@"FLTFirebaseStorage was already registered. If using isolates, you can safely ignore "
          @"this message.");
    return;
  }
  instance.storage_method_channel = channel;
#if TARGET_OS_OSX
  // TODO(Salakar): Publish does not exist on MacOS version of FlutterPluginRegistrar.
#else
  [registrar publish:instance];
#endif
  [registrar addMethodCallDelegate:instance channel:channel];

  FirebaseStorageHostApiSetup(registrar.messenger, instance);
}

- (void)cleanupWithCompletion:(void (^)(void))completion {
  for (FlutterEventChannel *channel in self->_eventChannels.allValues) {
    [channel setStreamHandler:nil];
  }
  [self->_eventChannels removeAllObjects];
  for (NSObject<FlutterStreamHandler> *handler in self->_streamHandlers.allValues) {
    [handler onCancelWithArguments:nil];
  }
  [self->_streamHandlers removeAllObjects];
  @synchronized(self->_tasks) {
    for (NSNumber *key in [self->_tasks allKeys]) {
      FIRStorageObservableTask<FIRStorageTaskManagement> *task = self->_tasks[key];
      if (task != nil) {
        [task removeAllObservers];
        [task cancel];
      }
    }
    [self->_tasks removeAllObjects];
    if (completion != nil) completion();
  }
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [self cleanupWithCompletion:^() {
    self.storage_method_channel = nil;
  }];
}

- (FIRStorage *_Nullable)getFIRStorageFromAppNameFromPigeon:(PigeonStorageFirebaseApp *)pigeonApp {
  FIRApp *app = [FLTFirebasePlugin firebaseAppNamed:pigeonApp.appName];
  FIRStorage *storage = [FIRStorage storageForApp:app];

  return storage;
}

- (FIRStorageReference *_Nullable)
    getFIRStorageReferenceFromPigeon:(PigeonStorageFirebaseApp *)pigeonApp
                           reference:(PigeonStorageReference *)reference {
  FIRStorage *storage = [self getFIRStorageFromAppNameFromPigeon:pigeonApp];
  return [storage referenceWithPath:reference.fullPath];
}

- (FIRStorageMetadata *)getFIRStorageMetadataFromPigeon:(PigeonSettableMetadata *)pigeonMetadata {
  FIRStorageMetadata *metadata = [[FIRStorageMetadata alloc] init];
  metadata.cacheControl = pigeonMetadata.cacheControl;
  metadata.contentDisposition = pigeonMetadata.contentDisposition;
  metadata.contentEncoding = pigeonMetadata.contentEncoding;
  metadata.contentLanguage = pigeonMetadata.contentLanguage;
  metadata.contentType = pigeonMetadata.contentType;

  metadata.customMetadata = pigeonMetadata.customMetadata;

  return metadata;
}

- (PigeonStorageReference *)makePigeonStorageReference:(FIRStorageReference *)reference {
  return [PigeonStorageReference makeWithBucket:reference.bucket
                                       fullPath:reference.fullPath
                                           name:reference.name];
}

#pragma mark - Firebase Storage API

- (void)getReferencebyPathApp:(PigeonStorageFirebaseApp *)app
                         path:(NSString *)path
                       bucket:(nullable NSString *)bucket
                   completion:(void (^)(PigeonStorageReference *_Nullable,
                                        FlutterError *_Nullable))completion {
  FIRStorage *storage = [self getFIRStorageFromAppNameFromPigeon:app];
  FIRStorageReference *storage_ref = [storage referenceWithPath:path];
  completion([PigeonStorageReference makeWithBucket:bucket
                                           fullPath:storage_ref.fullPath
                                               name:storage_ref.name],
             nil);
}

- (void)setMaxOperationRetryTimeApp:(PigeonStorageFirebaseApp *)app
                               time:(NSNumber *)time
                         completion:(void (^)(FlutterError *_Nullable))completion {
  FIRStorage *storage = [self getFIRStorageFromAppNameFromPigeon:app];
  if (![time isEqual:[NSNull null]]) {
    storage.maxOperationRetryTime = [time longLongValue] / 1000.0;
  }
  completion(nil);
}

- (void)setMaxUploadRetryTimeApp:(PigeonStorageFirebaseApp *)app
                            time:(NSNumber *)time
                      completion:(void (^)(FlutterError *_Nullable))completion {
  FIRStorage *storage = [self getFIRStorageFromAppNameFromPigeon:app];
  if (![time isEqual:[NSNull null]]) {
    storage.maxUploadRetryTime = [time longLongValue] / 1000.0;
  }
  completion(nil);
}

- (void)setMaxDownloadRetryTimeApp:(PigeonStorageFirebaseApp *)app
                              time:(NSNumber *)time
                        completion:(void (^)(FlutterError *_Nullable))completion {
  FIRStorage *storage = [self getFIRStorageFromAppNameFromPigeon:app];
  if (![time isEqual:[NSNull null]]) {
    storage.maxDownloadRetryTime = [time longLongValue] / 1000.0;
  }
  completion(nil);
}

- (void)useStorageEmulatorApp:(PigeonStorageFirebaseApp *)app
                         host:(NSString *)host
                         port:(NSNumber *)port
                   completion:(void (^)(FlutterError *_Nullable))completion {
  FIRStorage *storage = [self getFIRStorageFromAppNameFromPigeon:app];
  [storage useEmulatorWithHost:host port:[port integerValue]];
  completion(nil);
}

- (void)referenceDeleteApp:(PigeonStorageFirebaseApp *)app
                 reference:(PigeonStorageReference *)reference
                completion:(void (^)(FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];
  [storage_reference deleteWithCompletion:^(NSError *error) {
    completion([self FlutterErrorFromNSError:error]);
  }];
}

- (void)referenceGetDownloadURLApp:(PigeonStorageFirebaseApp *)app
                         reference:(PigeonStorageReference *)reference
                        completion:
                            (void (^)(NSString *_Nullable, FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];
  [storage_reference downloadURLWithCompletion:^(NSURL *URL, NSError *error) {
    if (error != nil) {
      completion(nil, [self FlutterErrorFromNSError:error]);
    } else {
      NSString *url = URL.absoluteString;

      if ([url rangeOfString:@":443"].location != NSNotFound) {
        NSRange replaceRange = [url rangeOfString:@":443"];
        url = [url stringByReplacingCharactersInRange:replaceRange withString:@""];
      }

      completion(url, nil);
    }
  }];
}

- (void)referenceGetMetaDataApp:(PigeonStorageFirebaseApp *)app
                      reference:(PigeonStorageReference *)reference
                     completion:(void (^)(PigeonFullMetaData *_Nullable,
                                          FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];

  [storage_reference metadataWithCompletion:^(FIRStorageMetadata *metadata, NSError *error) {
    if (error != nil) {
      completion(nil, [self FlutterErrorFromNSError:error]);
    } else {
      NSDictionary *dict = [FLTFirebaseStoragePlugin NSDictionaryFromFIRStorageMetadata:metadata];
      completion([PigeonFullMetaData makeWithMetadata:dict], nil);
    }
  }];
}

- (PigeonListResult *)makePigeonListResult:(FIRStorageListResult *)listResult {
  NSMutableArray<PigeonStorageReference *> *items =
      [NSMutableArray<PigeonStorageReference *> arrayWithCapacity:listResult.items.count];
  for (FIRStorageReference *item in listResult.items) {
    [items addObject:[self makePigeonStorageReference:item]];
  }
  NSMutableArray<PigeonStorageReference *> *prefixes =
      [NSMutableArray<PigeonStorageReference *> arrayWithCapacity:listResult.prefixes.count];
  for (FIRStorageReference *prefix in listResult.prefixes) {
    [prefixes addObject:[self makePigeonStorageReference:prefix]];
  }
  return [PigeonListResult makeWithItems:items pageToken:listResult.pageToken prefixs:prefixes];
}

- (void)referenceListApp:(PigeonStorageFirebaseApp *)app
               reference:(PigeonStorageReference *)reference
                 options:(PigeonListOptions *)options
              completion:
                  (void (^)(PigeonListResult *_Nullable, FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];

  id result_completion = ^(FIRStorageListResult *listResult, NSError *error) {
    if (error != nil) {
      completion(nil, [self FlutterErrorFromNSError:error]);
    } else {
      completion([self makePigeonListResult:listResult], nil);
    }
  };
  if (options.pageToken == nil) {
    [storage_reference listWithMaxResults:options.maxResults.longLongValue
                               completion:result_completion];
  } else {
    [storage_reference listWithMaxResults:options.maxResults.longLongValue
                                pageToken:options.pageToken
                               completion:result_completion];
  }
}

- (void)referenceListAllApp:(PigeonStorageFirebaseApp *)app
                  reference:(PigeonStorageReference *)reference
                 completion:
                     (void (^)(PigeonListResult *_Nullable, FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];
  [storage_reference listAllWithCompletion:^(FIRStorageListResult *listResult, NSError *error) {
    if (error != nil) {
      completion(nil, [self FlutterErrorFromNSError:error]);
    } else {
      completion([self makePigeonListResult:listResult], nil);
    }
  }];
}

- (void)referenceGetDataApp:(PigeonStorageFirebaseApp *)app
                  reference:(PigeonStorageReference *)reference
                    maxSize:(NSNumber *)maxSize
                 completion:(void (^)(FlutterStandardTypedData *_Nullable,
                                      FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];

  [storage_reference
      dataWithMaxSize:[maxSize longLongValue]
           completion:^(NSData *_Nullable data, NSError *_Nullable error) {
             if (error != nil) {
               completion(nil, [self FlutterErrorFromNSError:error]);
             } else {
               FlutterStandardTypedData *typedData;
               if (data == nil) {
                 typedData = [FlutterStandardTypedData typedDataWithBytes:[[NSData alloc] init]];
               } else {
                 typedData = [FlutterStandardTypedData typedDataWithBytes:data];
               }
               completion(typedData, nil);
             }
           }];
}

- (void)referencePutDataApp:(PigeonStorageFirebaseApp *)app
                  reference:(PigeonStorageReference *)reference
                       data:(FlutterStandardTypedData *)data
           settableMetaData:(PigeonSettableMetadata *)settableMetaData
                     handle:(NSNumber *)handle
                 completion:(void (^)(NSString *_Nullable, FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];

  FIRStorageMetadata *metadata = [self getFIRStorageMetadataFromPigeon:settableMetaData];

  FIRStorageObservableTask<FIRStorageTaskManagement> *task = [storage_reference putData:data.data
                                                                               metadata:metadata];

  @synchronized(self->_tasks) {
    self->_tasks[handle] = task;
  }

  completion([self setupTaskListeners:task], nil);
}

- (NSString *)setupTaskListeners:(FIRStorageObservableTask *)task {
  // Generate a random UUID to register with
  NSString *uuid = [[NSUUID UUID] UUIDString];

  // Set up task listeners
  NSString *channelName =
      [NSString stringWithFormat:@"%@/taskEvent/%@", kFLTFirebaseStorageChannelName, uuid];

  FlutterEventChannel *channel = [FlutterEventChannel eventChannelWithName:channelName
                                                           binaryMessenger:_binaryMessenger];
  FLTTaskStateChannelStreamHandler *handler =
      [[FLTTaskStateChannelStreamHandler alloc] initWithTask:task];
  [channel setStreamHandler:handler];

  [_eventChannels setObject:channel forKey:channelName];
  [_streamHandlers setObject:handler forKey:channelName];

  return uuid;
}

- (void)referencePutStringApp:(PigeonStorageFirebaseApp *)app
                    reference:(PigeonStorageReference *)reference
                         data:(NSString *)data
                       format:(NSNumber *)format
             settableMetaData:(PigeonSettableMetadata *)settableMetaData
                       handle:(NSNumber *)handle
                   completion:(void (^)(NSString *_Nullable, FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];

  NSData *formatted_data =
      [self NSDataFromUploadString:data format:(FLTFirebaseStorageStringType)[format intValue]];
  FIRStorageMetadata *metadata = [self getFIRStorageMetadataFromPigeon:settableMetaData];

  FIRStorageObservableTask<FIRStorageTaskManagement> *task =
      [storage_reference putData:formatted_data metadata:metadata];

  @synchronized(self->_tasks) {
    self->_tasks[handle] = task;
  }

  completion([self setupTaskListeners:task], nil);
}

- (void)referencePutFileApp:(PigeonStorageFirebaseApp *)app
                  reference:(PigeonStorageReference *)reference
                   filePath:(NSString *)filePath
           settableMetaData:(PigeonSettableMetadata *)settableMetaData
                     handle:(NSNumber *)handle
                 completion:(void (^)(NSString *_Nullable, FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];
  FIRStorageMetadata *metadata = [self getFIRStorageMetadataFromPigeon:settableMetaData];

  NSURL *fileUrl = [NSURL fileURLWithPath:filePath];
  FIRStorageObservableTask<FIRStorageTaskManagement> *task = [storage_reference putFile:fileUrl
                                                                               metadata:metadata];

  @synchronized(self->_tasks) {
    self->_tasks[handle] = task;
  }

  completion([self setupTaskListeners:task], nil);
}

- (void)referenceDownloadFileApp:(PigeonStorageFirebaseApp *)app
                       reference:(PigeonStorageReference *)reference
                        filePath:(NSString *)filePath
                          handle:(NSNumber *)handle
                      completion:
                          (void (^)(NSString *_Nullable, FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];

  NSURL *fileUrl = [NSURL fileURLWithPath:filePath];
  FIRStorageObservableTask<FIRStorageTaskManagement> *task =
      [storage_reference writeToFile:fileUrl];

  @synchronized(self->_tasks) {
    self->_tasks[handle] = task;
  }

  completion([self setupTaskListeners:task], nil);
}

- (void)referenceUpdateMetadataApp:(PigeonStorageFirebaseApp *)app
                         reference:(PigeonStorageReference *)reference
                          metadata:(PigeonSettableMetadata *)metadata
                        completion:(void (^)(PigeonFullMetaData *_Nullable,
                                             FlutterError *_Nullable))completion {
  FIRStorageReference *storage_reference = [self getFIRStorageReferenceFromPigeon:app
                                                                        reference:reference];
  FIRStorageMetadata *storage_metadata = [self getFIRStorageMetadataFromPigeon:metadata];

  [storage_reference updateMetadata:storage_metadata
                         completion:^(FIRStorageMetadata *updatedMetadata, NSError *error) {
                           if (error != nil) {
                             completion(nil, [self FlutterErrorFromNSError:error]);
                           } else {
                             NSDictionary *dict = [FLTFirebaseStoragePlugin
                                 NSDictionaryFromFIRStorageMetadata:updatedMetadata];
                             completion([PigeonFullMetaData makeWithMetadata:dict], nil);
                           }
                         }];
}

- (void)taskPauseApp:(PigeonStorageFirebaseApp *)app
              handle:(NSNumber *)handle
          completion:(void (^)(NSDictionary<NSString *, id> *_Nullable,
                               FlutterError *_Nullable))completion {
  FIRStorageObservableTask<FIRStorageTaskManagement> *task;
  @synchronized(self->_tasks) {
    task = self->_tasks[handle];
  }
  if (task != nil) {
    [self setState:FLTFirebaseStorageTaskStatePause
        forFIRStorageObservableTask:task
                     withCompletion:^(BOOL success, NSDictionary *snapshotDict) {
                       completion(
                           @{
                             @"status" : @(success),
                             @"snapshot" : (id)snapshotDict ?: [NSNull null],
                           },
                           nil);
                     }];
  } else {
    completion(nil, [FlutterError errorWithCode:@"unknown"
                                        message:@"Cannot find task to pause."
                                        details:@{}]);
  }
}

- (void)taskResumeApp:(PigeonStorageFirebaseApp *)app
               handle:(NSNumber *)handle
           completion:(void (^)(NSDictionary<NSString *, id> *_Nullable,
                                FlutterError *_Nullable))completion {
  FIRStorageObservableTask<FIRStorageTaskManagement> *task;
  @synchronized(self->_tasks) {
    task = self->_tasks[handle];
  }
  if (task != nil) {
    [self setState:FLTFirebaseStorageTaskStateResume
        forFIRStorageObservableTask:task
                     withCompletion:^(BOOL success, NSDictionary *snapshotDict) {
                       completion(
                           @{
                             @"status" : @(success),
                             @"snapshot" : (id)snapshotDict ?: [NSNull null],
                           },
                           nil);
                     }];
  } else {
    completion(nil, [FlutterError errorWithCode:@"unknown"
                                        message:@"Cannot find task to resume."
                                        details:@{}]);
  }
}

- (void)taskCancelApp:(PigeonStorageFirebaseApp *)app
               handle:(NSNumber *)handle
           completion:(void (^)(NSDictionary<NSString *, id> *_Nullable,
                                FlutterError *_Nullable))completion {
  FIRStorageObservableTask<FIRStorageTaskManagement> *task;
  @synchronized(self->_tasks) {
    task = self->_tasks[handle];
  }
  if (task != nil) {
    [self setState:FLTFirebaseStorageTaskStateCancel
        forFIRStorageObservableTask:task
                     withCompletion:^(BOOL success, NSDictionary *snapshotDict) {
                       completion(
                           @{
                             @"status" : @(success),
                             @"snapshot" : (id)snapshotDict ?: [NSNull null],
                           },
                           nil);
                     }];
  } else {
    completion(nil, [FlutterError errorWithCode:@"unknown"
                                        message:@"Cannot find task to cancel."
                                        details:@{}]);
  }
}

#pragma mark - Utilities

// To match Web & Android SDKs we need to return a bool of whether a task state change was
// successful.
- (void)setState:(FLTFirebaseStorageTaskState)state
    forFIRStorageObservableTask:(FIRStorageObservableTask<FIRStorageTaskManagement> *)task
                 withCompletion:(void (^)(BOOL, NSDictionary *))completion {
  // Pause
  if (state == FLTFirebaseStorageTaskStatePause) {
    if (task.snapshot.status == FIRStorageTaskStatusResume ||
        task.snapshot.status == FIRStorageTaskStatusProgress ||
        task.snapshot.status == FIRStorageTaskStatusUnknown) {
      __block FIRStorageHandle pauseHandle;
      __block FIRStorageHandle successHandle;
      __block FIRStorageHandle failureHandle;
      pauseHandle =
          [task observeStatus:FIRStorageTaskStatusPause
                      handler:^(FIRStorageTaskSnapshot *snapshot) {
                        [task removeObserverWithHandle:pauseHandle];
                        [task removeObserverWithHandle:successHandle];
                        [task removeObserverWithHandle:failureHandle];
                        completion(YES, [FLTFirebaseStoragePlugin parseTaskSnapshot:snapshot]);
                      }];
      successHandle = [task observeStatus:FIRStorageTaskStatusSuccess
                                  handler:^(FIRStorageTaskSnapshot *snapshot) {
                                    [task removeObserverWithHandle:pauseHandle];
                                    [task removeObserverWithHandle:successHandle];
                                    [task removeObserverWithHandle:failureHandle];
                                    completion(NO, nil);
                                  }];
      failureHandle = [task observeStatus:FIRStorageTaskStatusFailure
                                  handler:^(FIRStorageTaskSnapshot *snapshot) {
                                    [task removeObserverWithHandle:pauseHandle];
                                    [task removeObserverWithHandle:successHandle];
                                    [task removeObserverWithHandle:failureHandle];
                                    completion(NO, nil);
                                  }];

      [task pause];
    } else {
      completion(NO, nil);
    }
    return;
  }

  // Resume
  if (state == FLTFirebaseStorageTaskStateResume) {
    if (task.snapshot.status == FIRStorageTaskStatusPause) {
      __block FIRStorageHandle resumeHandle;
      __block FIRStorageHandle progressHandle;
      __block FIRStorageHandle successHandle;
      __block FIRStorageHandle failureHandle;
      resumeHandle =
          [task observeStatus:FIRStorageTaskStatusResume
                      handler:^(FIRStorageTaskSnapshot *snapshot) {
                        [task removeObserverWithHandle:resumeHandle];
                        [task removeObserverWithHandle:progressHandle];
                        [task removeObserverWithHandle:successHandle];
                        [task removeObserverWithHandle:failureHandle];
                        completion(YES, [FLTFirebaseStoragePlugin parseTaskSnapshot:snapshot]);
                      }];
      progressHandle =
          [task observeStatus:FIRStorageTaskStatusProgress
                      handler:^(FIRStorageTaskSnapshot *snapshot) {
                        [task removeObserverWithHandle:resumeHandle];
                        [task removeObserverWithHandle:progressHandle];
                        [task removeObserverWithHandle:successHandle];
                        [task removeObserverWithHandle:failureHandle];
                        completion(YES, [FLTFirebaseStoragePlugin parseTaskSnapshot:snapshot]);
                      }];
      successHandle = [task observeStatus:FIRStorageTaskStatusSuccess
                                  handler:^(FIRStorageTaskSnapshot *snapshot) {
                                    [task removeObserverWithHandle:resumeHandle];
                                    [task removeObserverWithHandle:progressHandle];
                                    [task removeObserverWithHandle:successHandle];
                                    [task removeObserverWithHandle:failureHandle];
                                    completion(NO, nil);
                                  }];
      failureHandle = [task observeStatus:FIRStorageTaskStatusFailure
                                  handler:^(FIRStorageTaskSnapshot *snapshot) {
                                    [task removeObserverWithHandle:resumeHandle];
                                    [task removeObserverWithHandle:progressHandle];
                                    [task removeObserverWithHandle:successHandle];
                                    [task removeObserverWithHandle:failureHandle];
                                    completion(NO, nil);
                                  }];
      [task resume];
    } else {
      completion(NO, nil);
    }
    return;
  }

  // Cancel
  if (state == FLTFirebaseStorageTaskStateCancel) {
    if (task.snapshot.status == FIRStorageTaskStatusPause ||
        task.snapshot.status == FIRStorageTaskStatusResume ||
        task.snapshot.status == FIRStorageTaskStatusProgress ||
        task.snapshot.status == FIRStorageTaskStatusUnknown) {
      __block FIRStorageHandle successHandle;
      __block FIRStorageHandle failureHandle;
      successHandle = [task observeStatus:FIRStorageTaskStatusSuccess
                                  handler:^(FIRStorageTaskSnapshot *snapshot) {
                                    [task removeObserverWithHandle:successHandle];
                                    [task removeObserverWithHandle:failureHandle];
                                    completion(NO, nil);
                                  }];
      failureHandle =
          [task observeStatus:FIRStorageTaskStatusFailure
                      handler:^(FIRStorageTaskSnapshot *snapshot) {
                        [task removeObserverWithHandle:successHandle];
                        [task removeObserverWithHandle:failureHandle];
                        if (snapshot.error && snapshot.error.code == FIRStorageErrorCodeCancelled) {
                          completion(YES, [FLTFirebaseStoragePlugin parseTaskSnapshot:snapshot]);
                        } else {
                          completion(NO, nil);
                        }
                      }];
      [task cancel];
    } else {
      completion(NO, nil);
    }
    return;
  }

  completion(NO, nil);
}

- (NSDictionary *)NSDictionaryFromNSError:(NSError *)error {
  NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
  NSString *code = @"unknown";
  NSString *message = [error localizedDescription];

  if (error.code == FIRStorageErrorCodeUnknown) {
    code = @"unknown";
  } else if (error.code == FIRStorageErrorCodeObjectNotFound) {
    code = @"object-not-found";
    message = @"No object exists at the desired reference.";
  } else if (error.code == FIRStorageErrorCodeBucketNotFound) {
    code = @"bucket-not-found";
    message = @"No bucket is configured for Firebase Storage.";
  } else if (error.code == FIRStorageErrorCodeProjectNotFound) {
    code = @"project-not-found";
    message = @"No project is configured for Firebase Storage.";
  } else if (error.code == FIRStorageErrorCodeQuotaExceeded) {
    code = @"quota-exceeded";
    message = @"Quota on your Firebase Storage bucket has been exceeded.";
  } else if (error.code == FIRStorageErrorCodeUnauthenticated) {
    code = @"unauthenticated";
    message = @"User is unauthenticated. Authenticate and try again.";
  } else if (error.code == FIRStorageErrorCodeUnauthorized) {
    code = @"unauthorized";
    message = @"User is not authorized to perform the desired action.";
  } else if (error.code == FIRStorageErrorCodeRetryLimitExceeded) {
    code = @"retry-limit-exceeded";
    message = @"The maximum time limit on an operation (upload, download, delete, etc.) has been "
              @"exceeded.";
  } else if (error.code == FIRStorageErrorCodeNonMatchingChecksum) {
    code = @"invalid-checksum";
    message = @"File on the client does not match the checksum of the file received by the server.";
  } else if (error.code == FIRStorageErrorCodeDownloadSizeExceeded) {
    code = @"download-size-exceeded";
    message =
        @"Size of the downloaded file exceeds the amount of memory allocated for the download.";
  } else if (error.code == FIRStorageErrorCodeCancelled) {
    code = @"canceled";
    message = @"User cancelled the operation.";
  } else if (error.code == FIRStorageErrorCodeInvalidArgument) {
    code = @"invalid-argument";
  }

  dictionary[@"code"] = code;
  dictionary[@"message"] = message;

  return dictionary;
}

- (FlutterError *_Nullable)FlutterErrorFromNSError:(NSError *_Nullable)error {
  if (error == nil) {
    return nil;
  }
  NSDictionary *dictionary = [self NSDictionaryFromNSError:error];
  return [FlutterError errorWithCode:dictionary[@"code"]
                             message:dictionary[@"message"]
                             details:@{}];
}

- (NSDictionary *)NSDictionaryFromHandle:(NSNumber *)handle
               andFIRStorageTaskSnapshot:(FIRStorageTaskSnapshot *)snapshot {
  NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
  dictionary[kFLTFirebaseStorageKeyHandle] = handle;
  dictionary[kFLTFirebaseStorageKeyAppName] =
      [FLTFirebasePlugin firebaseAppNameFromIosName:snapshot.reference.storage.app.name];
  dictionary[kFLTFirebaseStorageKeyBucket] = snapshot.reference.bucket;
  if (snapshot.error != nil) {
    dictionary[@"error"] = [self NSDictionaryFromNSError:snapshot.error];
  } else {
    dictionary[kFLTFirebaseStorageKeySnapshot] =
        [FLTFirebaseStoragePlugin parseTaskSnapshot:snapshot];
  }
  return dictionary;
}

+ (NSDictionary *)parseTaskSnapshot:(FIRStorageTaskSnapshot *)snapshot {
  NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];

  dictionary[kFLTFirebaseStorageKeyPath] = snapshot.reference.fullPath;

  if (snapshot.metadata != nil) {
    dictionary[@"metadata"] =
        [FLTFirebaseStoragePlugin NSDictionaryFromFIRStorageMetadata:snapshot.metadata];
  }

  if (snapshot.progress != nil) {
    dictionary[@"bytesTransferred"] = @(snapshot.progress.completedUnitCount);
    dictionary[@"totalBytes"] = @(snapshot.progress.totalUnitCount);
  } else {
    dictionary[@"bytesTransferred"] = @(0);
    dictionary[@"totalBytes"] = @(0);
  }

  return dictionary;
}

- (NSData *)NSDataFromUploadString:(NSString *)string format:(FLTFirebaseStorageStringType)format {
  // Dart: PutStringFormat.base64
  if (format == FLTFirebaseStorageStringTypeBase64) {
    return [[NSData alloc] initWithBase64EncodedString:string options:0];
  }

  // Dart: PutStringFormat.base64Url
  if (format == FLTFirebaseStorageStringTypeBase64URL) {
    // Convert to base64 from base64url.
    NSString *base64Encoded = string;
    base64Encoded = [base64Encoded stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    base64Encoded = [base64Encoded stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    // Add mandatory base64 encoding padding.
    while (base64Encoded.length % 4 != 0) {
      base64Encoded = [base64Encoded stringByAppendingString:@"="];
    }

    return [[NSData alloc] initWithBase64EncodedString:base64Encoded options:0];
  }

  return nil;
}

- (NSDictionary *)NSDictionaryFromFIRStorageListResult:(FIRStorageListResult *)listResult {
  NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];

  NSMutableArray<NSString *> *items = [[NSMutableArray alloc] init];
  for (FIRStorageReference *reference in listResult.items) {
    [items addObject:reference.fullPath];
  }
  dictionary[kFLTFirebaseStorageKeyItems] = items;

  NSMutableArray<NSString *> *prefixes = [[NSMutableArray alloc] init];
  for (FIRStorageReference *reference in listResult.prefixes) {
    [prefixes addObject:reference.fullPath];
  }
  dictionary[kFLTFirebaseStorageKeyPrefixes] = prefixes;

  if (listResult.pageToken != nil) {
    dictionary[kFLTFirebaseStorageKeyNextPageToken] = listResult.pageToken;
  }

  return dictionary;
}

- (FIRStorageMetadata *)FIRStorageMetadataFromNSDictionary:(NSDictionary *)dictionary
                                                  fullPath:(NSString *)fullPath {
  NSMutableDictionary *metadata = [NSMutableDictionary dictionary];

  // NOTE: Firebase iOS SDK 10 requires a "path" property on `FIRStorageMetadata`. We do this by
  // "initWithDictionary()" which uses "name" property as "path" under the hood.
  // See
  // https://github.com/firebase/firebase-ios-sdk/blob/970b4c45098319e40e6e5157d340d16cb73a2b88/FirebaseStorage/Sources/StorageMetadata.swift#L156-L178
  metadata[@"name"] = fullPath;

  if (dictionary == nil || [dictionary isEqual:[NSNull null]]) return nil;

  if (dictionary[kFLTFirebaseStorageKeyCacheControl] != [NSNull null]) {
    metadata[@"cacheControl"] = dictionary[kFLTFirebaseStorageKeyCacheControl];
  }
  if (dictionary[kFLTFirebaseStorageKeyContentDisposition] != [NSNull null]) {
    metadata[@"contentDisposition"] = dictionary[kFLTFirebaseStorageKeyContentDisposition];
  }
  if (dictionary[kFLTFirebaseStorageKeyContentEncoding] != [NSNull null]) {
    metadata[@"contentEncoding"] = dictionary[kFLTFirebaseStorageKeyContentEncoding];
  }
  if (dictionary[kFLTFirebaseStorageKeyContentLanguage] != [NSNull null]) {
    metadata[@"contentLanguage"] = dictionary[kFLTFirebaseStorageKeyContentLanguage];
  }
  if (dictionary[kFLTFirebaseStorageKeyContentType] != [NSNull null]) {
    metadata[@"contentType"] = dictionary[kFLTFirebaseStorageKeyContentType];
  }
  if (dictionary[kFLTFirebaseStorageKeyCustomMetadata] != [NSNull null]) {
    metadata[@"metadata"] = dictionary[kFLTFirebaseStorageKeyCustomMetadata];
  }

  return [[FIRStorageMetadata alloc] initWithDictionary:metadata];
}

+ (NSDictionary *)NSDictionaryFromFIRStorageMetadata:(FIRStorageMetadata *)metadata {
  NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];

  [dictionary setValue:[metadata name] forKey:kFLTFirebaseStorageKeyName];
  [dictionary setValue:[metadata bucket] forKey:kFLTFirebaseStorageKeyBucket];

  [dictionary setValue:[NSString stringWithFormat:@"%lld", [metadata generation]]
                forKey:kFLTFirebaseStorageKeyGeneration];

  [dictionary setValue:[NSString stringWithFormat:@"%lld", [metadata metageneration]]
                forKey:kFLTFirebaseStorageKeyMetadataGeneration];

  [dictionary setValue:[metadata path] forKey:kFLTFirebaseStorageKeyFullPath];

  [dictionary setValue:@([metadata size]) forKey:kFLTFirebaseStorageKeySize];

  [dictionary setValue:@((long)([[metadata timeCreated] timeIntervalSince1970] * 1000.0))
                forKey:kFLTFirebaseStorageKeyCreationTime];

  [dictionary setValue:@((long)([[metadata updated] timeIntervalSince1970] * 1000.0))
                forKey:kFLTFirebaseStorageKeyUpdatedTime];

  if ([metadata md5Hash] != nil) {
    [dictionary setValue:[metadata md5Hash] forKey:kFLTFirebaseStorageKeyMD5Hash];
  }

  if ([metadata cacheControl] != nil) {
    [dictionary setValue:[metadata cacheControl] forKey:kFLTFirebaseStorageKeyCacheControl];
  }

  if ([metadata contentDisposition] != nil) {
    [dictionary setValue:[metadata contentDisposition]
                  forKey:kFLTFirebaseStorageKeyContentDisposition];
  }

  if ([metadata contentEncoding] != nil) {
    [dictionary setValue:[metadata contentEncoding] forKey:kFLTFirebaseStorageKeyContentEncoding];
  }

  if ([metadata contentLanguage] != nil) {
    [dictionary setValue:[metadata contentLanguage] forKey:kFLTFirebaseStorageKeyContentLanguage];
  }

  if ([metadata contentType] != nil) {
    [dictionary setValue:[metadata contentType] forKey:kFLTFirebaseStorageKeyContentType];
  }

  if ([metadata customMetadata] != nil) {
    [dictionary setValue:[metadata customMetadata] forKey:kFLTFirebaseStorageKeyCustomMetadata];
  } else {
    [dictionary setValue:@{} forKey:kFLTFirebaseStorageKeyCustomMetadata];
  }

  return dictionary;
}

- (FIRStorage *)FIRStorageForArguments:(id)arguments {
  FIRStorage *storage;
  NSString *appName = arguments[kFLTFirebaseStorageKeyAppName];
  NSString *bucket = arguments[kFLTFirebaseStorageKeyBucket];
  FIRApp *firebaseApp = [FLTFirebasePlugin firebaseAppNamed:appName];

  if (![bucket isEqual:[NSNull null]] && bucket != nil) {
    NSString *url = [@"gs://" stringByAppendingString:bucket];
    storage = [FIRStorage storageForApp:firebaseApp URL:url];
  } else {
    storage = [FIRStorage storageForApp:firebaseApp];
  }

  NSNumber *maxOperationRetryTime = arguments[kFLTFirebaseStorageKeyMaxOperationRetryTime];
  if (![maxOperationRetryTime isEqual:[NSNull null]]) {
    storage.maxOperationRetryTime = [maxOperationRetryTime longLongValue] / 1000.0;
  }

  NSNumber *maxDownloadRetryTime = arguments[kFLTFirebaseStorageKeyMaxDownloadRetryTime];
  if (![maxDownloadRetryTime isEqual:[NSNull null]]) {
    storage.maxDownloadRetryTime = [maxDownloadRetryTime longLongValue] / 1000.0;
  }

  NSNumber *maxUploadRetryTime = arguments[kFLTFirebaseStorageKeyMaxUploadRetryTime];
  if (![maxUploadRetryTime isEqual:[NSNull null]]) {
    storage.maxUploadRetryTime = [maxUploadRetryTime longLongValue] / 1000.0;
  }

  NSString *emulatorHost = arguments[@"host"];
  if (![emulatorHost isEqual:[NSNull null]] && emulatorHost != nil && hasEmulatorBooted == false) {
    [storage useEmulatorWithHost:emulatorHost port:[arguments[@"port"] integerValue]];
    hasEmulatorBooted = true;
  }

  storage.callbackQueue = _callbackQueue;

  return storage;
}

- (FIRStorageReference *)FIRStorageReferenceForArguments:(id)arguments {
  NSString *path = arguments[kFLTFirebaseStorageKeyPath];
  FIRStorage *storage = [self FIRStorageForArguments:arguments];
  return [storage referenceWithPath:path];
}

#pragma mark - FLTFirebasePlugin

- (void)didReinitializeFirebaseCore:(void (^)(void))completion {
  [self cleanupWithCompletion:completion];
}

- (NSDictionary *_Nonnull)pluginConstantsForFIRApp:(FIRApp *)firebase_app {
  return @{};
}

- (NSString *_Nonnull)firebaseLibraryName {
  return LIBRARY_NAME;
}

- (NSString *_Nonnull)firebaseLibraryVersion {
  return LIBRARY_VERSION;
}

- (NSString *_Nonnull)flutterChannelName {
  return kFLTFirebaseStorageChannelName;
}

@end
