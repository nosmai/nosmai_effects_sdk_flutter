#import "NosmaiFlutterPlugin.h"
#import "NosmaiCameraPreviewView.h"
#import <nosmai/Nosmai.h>
#import <Photos/Photos.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <sys/socket.h>
#import <netinet/in.h>
#include <math.h>

#if DEBUG
#define NOSMAI_PLUGIN_LOG(...) NSLog(__VA_ARGS__)
#else
#define NOSMAI_PLUGIN_LOG(...) do { } while (0)
#endif

// NosmaiExternalProcessor interface
@interface NosmaiExternalProcessor : NSObject
@property (nonatomic, assign) BOOL isInitialized;
@property (nonatomic, assign) CVPixelBufferRef lastProcessedBuffer;
@property (nonatomic, strong) dispatch_semaphore_t frameSemaphore;
- (BOOL)processPixelBuffer:(CVPixelBufferRef)pixelBuffer mirror:(BOOL)mirror;
@end

@interface NosmaiFlutterPlugin() <NosmaiDelegate, NosmaiCameraDelegate, NosmaiEffectsDelegate>
@property(nonatomic, strong) FlutterMethodChannel* channel;
@property(nonatomic, assign) BOOL isInitialized;
@property(nonatomic, assign) BOOL isRecording;
@property(nonatomic, strong) NSTimer* recordingProgressTimer;
@property(nonatomic, strong) NSCache* filterCache;
@property(nonatomic, strong) NSArray* cachedLocalFilters;
@property(nonatomic, strong) NSDate* lastFilterCacheTime;
@property(nonatomic, assign) BOOL isCameraAttached;
@property(nonatomic, strong) dispatch_semaphore_t cameraStateSemaphore;
@property(nonatomic, strong) dispatch_queue_t cacheQueue;
@property(nonatomic, strong) dispatch_semaphore_t filterOperationSemaphore;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *pendingCloudDownloadResults;
@property(nonatomic, assign) BOOL gameEventsEnabled;
// Flash and Torch state tracking (NosmaiCamera doesn't provide getters)
@property(nonatomic, assign) AVCaptureFlashMode currentFlashMode;
@property(nonatomic, assign) AVCaptureTorchMode currentTorchMode;
@end

@implementation NosmaiFlutterPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"nosmai_camera_sdk"
            binaryMessenger:[registrar messenger]];
  NosmaiFlutterPlugin* instance = [[NosmaiFlutterPlugin alloc] init];
  instance.channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];

  NosmaiCameraPreviewViewFactory* factory =
      [[NosmaiCameraPreviewViewFactory alloc] initWithMessenger:[registrar messenger]];
  [registrar registerViewFactory:factory withId:@"nosmai_camera_preview"];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _isInitialized = NO;
    _isCameraAttached = NO;

    _filterCache = [[NSCache alloc] init];
    _filterCache.countLimit = 100;
    _filterCache.totalCostLimit = 50 * 1024 * 1024;

    _cameraStateSemaphore = dispatch_semaphore_create(1);

    _cacheQueue = dispatch_queue_create("com.nosmai.cache", DISPATCH_QUEUE_CONCURRENT);

    _filterOperationSemaphore = dispatch_semaphore_create(1);

    // Initialize flash/torch state to off
    _currentFlashMode = AVCaptureFlashModeOff;
    _currentTorchMode = AVCaptureTorchModeOff;
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* method = call.method;

  if ([@"getPlatformVersion" isEqualToString:method]) {
    result([@"iOS " stringByAppendingString:[[UIDevice currentDevice] systemVersion]]);
  }
  else if ([@"initWithLicense" isEqualToString:method]) {
    [self handleInitWithLicense:call result:result];
  }
  else if ([@"configureCamera" isEqualToString:method]) {
    [self handleConfigureCamera:call result:result];
  }
  else if ([@"startProcessing" isEqualToString:method]) {
    [self handleStartProcessing:call result:result];
  }
  else if ([@"stopProcessing" isEqualToString:method]) {
    [self handleStopProcessing:call result:result];
  }
  else if ([@"pauseCamera" isEqualToString:method]) {
    [self handlePauseCamera:call result:result];
  }
  else if ([@"resumeCamera" isEqualToString:method]) {
    [self handleResumeCamera:call result:result];
  }
  else if ([@"applyBrightnessFilter" isEqualToString:method]) {
    [self handleApplyBrightnessFilter:call result:result];
  }
  else if ([@"applyContrastFilter" isEqualToString:method]) {
    [self handleApplyContrastFilter:call result:result];
  }
  else if ([@"applyRGBFilter" isEqualToString:method]) {
    [self handleApplyRGBFilter:call result:result];
  }
  else if ([@"applySkinSmoothing" isEqualToString:method]) {
    [self handleApplySkinSmoothing:call result:result];
  }
  else if ([@"applySkinWhitening" isEqualToString:method]) {
    [self handleApplySkinWhitening:call result:result];
  }
  else if ([@"applySharpening" isEqualToString:method]) {
    [self handleApplySharpening:call result:result];
  }
  else if ([@"applyTeethWhitening" isEqualToString:method]) {
    [self handleApplyTeethWhitening:call result:result];
  }
  else if ([@"applyGrayscaleFilter" isEqualToString:method]) {
    [self handleApplyGrayscaleFilter:call result:result];
  }
  else if ([@"applyHue" isEqualToString:method]) {
    [self handleApplyHue:call result:result];
  }
  else if ([@"applyWhiteBalance" isEqualToString:method]) {
    [self handleApplyWhiteBalance:call result:result];
  }
  else if ([@"adjustHSB" isEqualToString:method]) {
    [self handleAdjustHSB:call result:result];
  }
  else if ([@"removeBuiltInFilters" isEqualToString:method]) {
    [self handleRemoveBuiltInFilters:call result:result];
  }
  else if ([@"removeBuiltInFilterByName" isEqualToString:method]) {
    [self handleRemoveBuiltInFilterByName:call result:result];
  }
  // Lipstick Methods
  else if ([@"applyLipstick" isEqualToString:method]) {
    [self handleApplyLipstick:call result:result];
  }
  else if ([@"setLipstickIntensity" isEqualToString:method]) {
    [self handleSetLipstickIntensity:call result:result];
  }
  else if ([@"removeLipstick" isEqualToString:method]) {
    [self handleRemoveLipstick:call result:result];
  }
  else if ([@"hasLipstick" isEqualToString:method]) {
    [self handleHasLipstick:call result:result];
  }
  else if ([@"getLipstickColors" isEqualToString:method]) {
    [self handleGetLipstickColors:call result:result];
  }
  // Eyeshadow Methods
  else if ([@"applyEyeshadow" isEqualToString:method]) {
    [self handleApplyEyeshadow:call result:result];
  }
  else if ([@"setEyeshadowIntensity" isEqualToString:method]) {
    [self handleSetEyeshadowIntensity:call result:result];
  }
  else if ([@"removeEyeshadow" isEqualToString:method]) {
    [self handleRemoveEyeshadow:call result:result];
  }
  else if ([@"hasEyeshadow" isEqualToString:method]) {
    [self handleHasEyeshadow:call result:result];
  }
  // Blusher Methods
  else if ([@"applyBlusher" isEqualToString:method]) {
    [self handleApplyBlusher:call result:result];
  }
  else if ([@"setBlusherIntensity" isEqualToString:method]) {
    [self handleSetBlusherIntensity:call result:result];
  }
  else if ([@"removeBlusher" isEqualToString:method]) {
    [self handleRemoveBlusher:call result:result];
  }
  else if ([@"hasBlusher" isEqualToString:method]) {
    [self handleHasBlusher:call result:result];
  }
  // Eyelash Methods
  else if ([@"applyEyelash" isEqualToString:method]) {
    [self handleApplyEyelash:call result:result];
  }
  else if ([@"setEyelashIntensity" isEqualToString:method]) {
    [self handleSetEyelashIntensity:call result:result];
  }
  else if ([@"removeEyelash" isEqualToString:method]) {
    [self handleRemoveEyelash:call result:result];
  }
  else if ([@"hasEyelash" isEqualToString:method]) {
    [self handleHasEyelash:call result:result];
  }
  // Eyebrow Methods
  else if ([@"applyEyebrow" isEqualToString:method]) {
    [self handleApplyEyebrow:call result:result];
  }
  else if ([@"setEyebrowIntensity" isEqualToString:method]) {
    [self handleSetEyebrowIntensity:call result:result];
  }
  else if ([@"removeEyebrow" isEqualToString:method]) {
    [self handleRemoveEyebrow:call result:result];
  }
  else if ([@"hasEyebrow" isEqualToString:method]) {
    [self handleHasEyebrow:call result:result];
  }
  // Face Morphing Methods
  else if ([@"setFaceSlimLevel" isEqualToString:method]) {
    [self handleSetFaceSlimLevel:call result:result];
  }
  else if ([@"setEyeSizeLevel" isEqualToString:method]) {
    [self handleSetEyeSizeLevel:call result:result];
  }
  else if ([@"setNoseSlimLevel" isEqualToString:method]) {
    [self handleSetNoseSlimLevel:call result:result];
  }
  else if ([@"removeAllMorphing" isEqualToString:method]) {
    [self handleRemoveAllMorphing:call result:result];
  }
  // Eye Coloring Methods
  else if ([@"setEyeColor" isEqualToString:method]) {
    [self handleSetEyeColor:call result:result];
  }
  else if ([@"setEyeColorIntensity" isEqualToString:method]) {
    [self handleSetEyeColorIntensity:call result:result];
  }
  else if ([@"removeEyeColoring" isEqualToString:method]) {
    [self handleRemoveEyeColoring:call result:result];
  }
  // Utility Methods
  else if ([@"removeAllMakeup" isEqualToString:method]) {
    [self handleRemoveAllMakeup:call result:result];
  }
  else if ([@"removeAllBeautyEffects" isEqualToString:method]) {
    [self handleRemoveAllBeautyEffects:call result:result];
  }
  else if ([@"applyEffect" isEqualToString:method]) {
    [self handleApplyEffect:call result:result];
  }
  else if ([@"applyFilter" isEqualToString:method]) {
    [self handleApplyFilter:call result:result];
  }
  else if ([@"getActiveEffects" isEqualToString:method] ||
           [@"getCurrentPipelineState" isEqualToString:method]) {
    [self handleGetCurrentPipelineState:call result:result];
  }
  else if ([@"getActiveFilterInfo" isEqualToString:method]) {
    [self handleGetActiveFilterInfo:call result:result];
  }
  else if ([@"getActiveEffectInfo" isEqualToString:method]) {
    [self handleGetActiveEffectInfo:call result:result];
  }
  else if ([@"isGameReady" isEqualToString:method]) {
    [self handleIsGameReady:call result:result];
  }
  else if ([@"sendGameTap" isEqualToString:method]) {
    [self handleSendGameTap:call result:result];
  }
  else if ([@"sendGameInput" isEqualToString:method]) {
    [self handleSendGameInput:call result:result];
  }
  else if ([@"pauseGame" isEqualToString:method]) {
    [[NosmaiCore shared].effects pauseGame];
    result(nil);
  }
  else if ([@"resumeGame" isEqualToString:method]) {
    [[NosmaiCore shared].effects resumeGame];
    result(nil);
  }
  else if ([@"restartGame" isEqualToString:method]) {
    [[NosmaiCore shared].effects restartGame];
    result(nil);
  }
  else if ([@"setGameEventListenerEnabled" isEqualToString:method]) {
    [self handleSetGameEventListenerEnabled:call result:result];
  }
  else if ([@"removeEffect" isEqualToString:method]) {
    [self handleRemoveEffect:call result:result];
  }
  else if ([@"downloadCloudFilter" isEqualToString:method]) {
    [self handleDownloadCloudFilter:call result:result];
  }
  else if ([@"removeCloudFilter" isEqualToString:method]) {
    [self handleRemoveCloudFilter:call result:result];
  }
  else if ([@"getCloudFilters" isEqualToString:method]) {
    [self handleGetCloudFilters:call result:result];
  }
  else if ([@"getLocalFilters" isEqualToString:method]) {
    [self handleGetLocalFilters:call result:result];
  }
  else if ([@"getAllLocalFilters" isEqualToString:method]) {
    [self handleGetAllLocalFilters:call result:result];
  }
  else if ([@"getDebugFilters" isEqualToString:method]) {
    [self handleGetDebugFilters:call result:result];
  }
  else if ([@"getLocalEffects" isEqualToString:method]) {
    [self handleGetLocalEffects:call result:result];
  }
  else if ([@"getLocalBackgrounds" isEqualToString:method]) {
    [self handleGetLocalBackgrounds:call result:result];
  }
  else if ([@"getLocalBeautyEffects" isEqualToString:method]) {
    [self handleGetLocalBeautyEffects:call result:result];
  }
  else if ([@"getLocalGames" isEqualToString:method]) {
    [self handleGetLocalGames:call result:result];
  }
  else if ([@"validateLocalFilters" isEqualToString:method]) {
    [self handleValidateLocalFilters:call result:result];
  }
  else if ([@"clearLocalFiltersCache" isEqualToString:method]) {
    [self handleClearLocalFiltersCache:call result:result];
  }
  else if ([@"startRecording" isEqualToString:method]) {
    [self handleStartRecording:call result:result];
  }
  else if ([@"stopRecording" isEqualToString:method]) {
    [self handleStopRecording:call result:result];
  }
  else if ([@"isRecording" isEqualToString:method]) {
    [self handleIsRecording:call result:result];
  }
  else if ([@"getCurrentRecordingDuration" isEqualToString:method]) {
    [self handleGetCurrentRecordingDuration:call result:result];
  }
  else if ([@"switchCamera" isEqualToString:method]) {
    [self handleSwitchCamera:call result:result];
  }
  else if ([@"removeAllFilters" isEqualToString:method]) {
    [self handleRemoveAllFilters:call result:result];
  }
  else if ([@"clearAREffect" isEqualToString:method]) {
    [self handleClearAREffect:call result:result];
  }
  else if ([@"clearFilter" isEqualToString:method]) {
    [self handleClearFilter:call result:result];
  }
  else if ([@"clearAll" isEqualToString:method]) {
    [self handleClearAll:call result:result];
  }
  else if ([@"cleanup" isEqualToString:method]) {
    [self handleCleanup:call result:result];
  }
  else if ([@"setPreviewView" isEqualToString:method]) {
    [self handleSetPreviewView:call result:result];
  }
  else if ([@"capturePhoto" isEqualToString:method]) {
    [self handleCapturePhoto:call result:result];
  }
  else if ([@"saveImageToGallery" isEqualToString:method]) {
    [self handleSaveImageToGallery:call result:result];
  }
  else if ([@"saveVideoToGallery" isEqualToString:method]) {
    [self handleSaveVideoToGallery:call result:result];
  }
  else if ([@"clearFilterCache" isEqualToString:method]) {
    [self handleClearFilterCache:call result:result];
  }
  else if ([@"detachCameraView" isEqualToString:method]) {
    [self handleDetachCameraView:call result:result];
  }
  else if ([@"reinitializePreview" isEqualToString:method]) {
    [self handleReinitializePreview:call result:result];
  }
  else if ([@"isBeautyEffectEnabled" isEqualToString:method]) {
    [self handleIsBeautyEffectEnabled:call result:result];
  }
  else if ([@"isCloudFilterEnabled" isEqualToString:method]) {
    [self handleIsCloudFilterEnabled:call result:result];
  }
  else if ([@"startLiveFrameStream" isEqualToString:method]) {
    [self handleStartLiveFrameStream:call result:result];
  }
  else if ([@"stopLiveFrameStream" isEqualToString:method]) {
    [self handleStopLiveFrameStream:call result:result];
  }
  else if ([@"hasFlash" isEqualToString:method]) {
    [self handleHasFlash:call result:result];
  }
  else if ([@"hasTorch" isEqualToString:method]) {
    [self handleHasTorch:call result:result];
  }
  else if ([@"setFlashMode" isEqualToString:method]) {
    [self handleSetFlashMode:call result:result];
  }
  else if ([@"setTorchMode" isEqualToString:method]) {
    [self handleSetTorchMode:call result:result];
  }
  else if ([@"getFlashMode" isEqualToString:method]) {
    [self handleGetFlashMode:call result:result];
  }
  else if ([@"getTorchMode" isEqualToString:method]) {
    [self handleGetTorchMode:call result:result];
  }
  else if ([@"getEffectParameters" isEqualToString:method]) {
    [self handleGetEffectParameters:call result:result];
  }
  else if ([@"getEffectParameterValue" isEqualToString:method]) {
    [self handleGetEffectParameterValue:call result:result];
  }
  else if ([@"setEffectParameter" isEqualToString:method]) {
    [self handleSetEffectParameter:call result:result];
  }
  else if ([@"setEffectParameterString" isEqualToString:method]) {
    [self handleSetEffectParameterString:call result:result];
  }
  // Background Segmentation Methods
  else if ([@"isAdvancedFiltersEnabled" isEqualToString:method]) {
    [self handleIsAdvancedFiltersEnabled:call result:result];
  }
  else if ([@"setBackgroundSegmentation" isEqualToString:method]) {
    [self handleSetBackgroundSegmentation:call result:result];
  }
  else if ([@"clearBackgroundSegmentation" isEqualToString:method]) {
    [self handleClearBackgroundSegmentation:call result:result];
  }
  else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark - SDK Initialization

- (void)handleInitWithLicense:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* licenseKey = call.arguments[@"licenseKey"];

  if (!licenseKey || licenseKey.length == 0) {
    result([FlutterError errorWithCode:@"INVALID_LICENSE"
                               message:@"License key is required"
                               details:nil]);
    return;
  }

  [NosmaiCore shared].delegate = self;

  __weak typeof(self) weakSelf = self;
  [[NosmaiCore shared] initializeWithAPIKey:licenseKey completion:^(BOOL success, NSError *error) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;

    dispatch_async(dispatch_get_main_queue(), ^{
      strongSelf.isInitialized = success;

      if (success) {
        [[NosmaiCore shared].camera setDelegate:strongSelf];
        [[NosmaiCore shared].effects setDelegate:strongSelf];
        [strongSelf updateGameEventHandler];

        [[NosmaiSDK sharedInstance] setDelegate:strongSelf];
        [NosmaiCameraPreviewView reattachActivePreviewIfReady];

        result(@YES);
      } else {
        result([FlutterError errorWithCode:@"INIT_FAILED"
                                   message:error ? error.localizedDescription : @"Failed to initialize SDK with provided license"
                                   details:nil]);
      }
    });
  }];
}

#pragma mark - Live Frame Streaming
- (void)handleStartLiveFrameStream:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before starting the frame stream"
                               details:nil]);
    return;
  }

  result([FlutterError errorWithCode:@"NOT_IMPLEMENTED"
                             message:@"Live frame streaming is not implemented"
                             details:nil]);

}

- (void)handleStopLiveFrameStream:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before stopping the frame stream"
                               details:nil]);
    return;
  }

  result([FlutterError errorWithCode:@"NOT_IMPLEMENTED"
                             message:@"Live frame streaming is not implemented"
                             details:nil]);
}

#pragma mark - Camera Configuration

- (void)handleConfigureCamera:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before configuring camera"
                               details:nil]);
    return;
  }

  NSString* position = call.arguments[@"position"];
  NSString* sessionPreset = call.arguments[@"sessionPreset"];

  if (!position || (![position isEqualToString:@"front"] && ![position isEqualToString:@"back"])) {
    result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                               message:@"Camera position must be 'front' or 'back'"
                               details:@{@"position": position ?: @"null"}]);
    return;
  }

  NosmaiCameraPosition cameraPosition = NosmaiCameraPositionFront;
  if ([@"back" isEqualToString:position]) {
    cameraPosition = NosmaiCameraPositionBack;
  }

  // if (!sessionPreset) {
    // Use 1280x720 for optimal face detection performance
    // sessionPreset = AVCaptureSessionPreset1280x720;
  // }

  @try {
    NosmaiCameraConfig *config = [[NosmaiCameraConfig alloc] init];
    config.position = cameraPosition;
    config.sessionPreset = sessionPreset;
    config.sessionPreset = AVCaptureSessionPreset1280x720;
    config.frameRate = 30;

    [[NosmaiCore shared].camera updateConfiguration:config];
    [[NosmaiCore shared].camera setDelegate:self];

    result(nil);

  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"CAMERA_CONFIG_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

#pragma mark - Processing Control

- (void)handleStartProcessing:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before starting processing"
                               details:nil]);
    return;
  }

  @try {
    BOOL success = [[NosmaiCore shared].camera startCapture];
    if (success) {
      [[NosmaiSDK sharedInstance] startProcessing];
      [NosmaiCameraPreviewView reattachActivePreviewIfReady];
      result(nil);
    } else {
      result([FlutterError errorWithCode:@"CAMERA_START_ERROR"
                                 message:@"Failed to start camera capture"
                                 details:nil]);
    }
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"PROCESSING_START_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleStopProcessing:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before stopping processing"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] stopProcessing];
    [[NosmaiCore shared].camera stopCapture];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"STOP_PROCESSING_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handlePauseCamera:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before pausing camera"
                               details:nil]);
    return;
  }

  @try {
    // Only stop camera capture - SDK processing stays active
    [[NosmaiCore shared].camera stopCapture];
    NOSMAI_PLUGIN_LOG(@"⏸️ Camera paused successfully");
    result(@YES);
  } @catch (NSException *exception) {
    NOSMAI_PLUGIN_LOG(@"❌ pauseCamera error: %@", exception.reason);
    result([FlutterError errorWithCode:@"PAUSE_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleResumeCamera:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before resuming camera"
                               details:nil]);
    return;
  }

  @try {
    // Only restart camera capture - SDK processing already active
    [[NosmaiCore shared].camera startCapture];
    NOSMAI_PLUGIN_LOG(@"▶️ Camera resumed successfully");
    result(@YES);
  } @catch (NSException *exception) {
    NOSMAI_PLUGIN_LOG(@"❌ resumeCamera error: %@", exception.reason);
    result([FlutterError errorWithCode:@"RESUME_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

#pragma mark - Built-in Filter Applications

- (void)handleApplyBrightnessFilter:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  NSNumber* brightness = call.arguments[@"brightness"];
  if (!brightness) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Brightness value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects applyBrightnessFilter:brightness.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleApplyContrastFilter:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  NSNumber* contrast = call.arguments[@"contrast"];
  if (!contrast) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Contrast value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects applyContrastFilter:contrast.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleApplyRGBFilter:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  NSNumber* red = call.arguments[@"red"];
  NSNumber* green = call.arguments[@"green"];
  NSNumber* blue = call.arguments[@"blue"];

  if (!red || !green || !blue) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"RGB values are required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects applyRGBFilterWithRed:red.floatValue
                                                  green:green.floatValue
                                                   blue:blue.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleApplySkinSmoothing:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  NSNumber* level = call.arguments[@"level"];
  if (!level) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Level value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects applySkinSmoothing:level.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleApplySkinWhitening:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  NSNumber* level = call.arguments[@"level"];
  if (!level) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Level value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects applySkinWhitening:level.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleApplySharpening:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  NSNumber* level = call.arguments[@"level"];
  if (!level) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Level value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects applySharpening:level.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleApplyTeethWhitening:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  NSNumber* intensity = call.arguments[@"intensity"];
  if (!intensity) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Intensity value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects applyTeethWhitening:intensity.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleApplyGrayscaleFilter:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects applyGrayscaleFilter];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleApplyHue:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  NSNumber* hueAngle = call.arguments[@"hueAngle"];
  if (!hueAngle) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Hue angle is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects applyHue:hueAngle.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}


- (void)handleApplyWhiteBalance:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  NSNumber* temperature = call.arguments[@"temperature"];
  NSNumber* tint = call.arguments[@"tint"];

  if (!temperature || !tint) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Temperature and tint are required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects applyWhiteBalanceWithTemperature:temperature.floatValue
                                                              tint:tint.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}


- (void)handleAdjustHSB:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:nil]);
    return;
  }

  NSNumber* hue = call.arguments[@"hue"];
  NSNumber* saturation = call.arguments[@"saturation"];
  NSNumber* brightness = call.arguments[@"brightness"];

  if (!hue || !saturation || !brightness) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Hue, saturation and brightness are required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects adjustHSBWithHue:hue.floatValue
                                        saturation:saturation.floatValue
                                        brightness:brightness.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveBuiltInFilters:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before removing filters"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects removeBuiltInFilters];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveBuiltInFilterByName:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before removing filters"
                               details:nil]);
    return;
  }

  NSString* filterName = call.arguments[@"filterName"];
  if (!filterName) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Filter name is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiCore shared].effects removeBuiltInFilterByName:filterName];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

#pragma mark - Lipstick Methods

- (void)handleApplyLipstick:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying lipstick"
                               details:nil]);
    return;
  }

  NSNumber* styleNum = call.arguments[@"style"];
  NSNumber* intensity = call.arguments[@"intensity"];

  if (!styleNum) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Style is required"
                               details:nil]);
    return;
  }

  @try {
    NosmaiLipstickStyle style = (NosmaiLipstickStyle)styleNum.integerValue;
    // Use default color index 0
    [[NosmaiSDK sharedInstance] applyLipstickWithStyle:style
                                            colorIndex:0];

    if (intensity) {
      [[NosmaiSDK sharedInstance] setLipstickIntensity:intensity.floatValue];
    }

    result(@YES);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"LIPSTICK_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleSetLipstickIntensity:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSNumber* intensity = call.arguments[@"intensity"];
  if (!intensity) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Intensity value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] setLipstickIntensity:intensity.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"LIPSTICK_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveLipstick:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] removeLipstick];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"LIPSTICK_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleHasLipstick:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result(@NO);
    return;
  }

  @try {
    BOOL hasLipstick = [NosmaiSDK sharedInstance].hasLipstick;
    result(@(hasLipstick));
  } @catch (NSException *exception) {
    result(@NO);
  }
}

- (void)handleGetLipstickColors:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result(@[]);
    return;
  }

  @try {
    NSArray<NosmaiMakeupColor *> *colors = [NosmaiSDK sharedInstance].lipstickColors;
    NSMutableArray *colorList = [NSMutableArray array];

    for (NosmaiMakeupColor *color in colors) {
      [colorList addObject:@{
        @"name": color.name ?: @"",
        @"r": @(color.r),
        @"g": @(color.g),
        @"b": @(color.b),
      }];
    }

    result(colorList);
  } @catch (NSException *exception) {
    result(@[]);
  }
}

#pragma mark - Eyeshadow Methods

- (void)handleApplyEyeshadow:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying eyeshadow"
                               details:nil]);
    return;
  }

  NSNumber* styleNum = call.arguments[@"style"];
  NSNumber* intensity = call.arguments[@"intensity"];

  if (!styleNum) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Style is required"
                               details:nil]);
    return;
  }

  @try {
    NosmaiEyeshadowStyle style = (NosmaiEyeshadowStyle)styleNum.integerValue;
    [[NosmaiSDK sharedInstance] applyEyeshadowWithStyle:style
                                             colorIndex:0];

    if (intensity) {
      [[NosmaiSDK sharedInstance] setEyeshadowIntensity:intensity.floatValue];
    }

    result(@YES);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYESHADOW_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleSetEyeshadowIntensity:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSNumber* intensity = call.arguments[@"intensity"];
  if (!intensity) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Intensity value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] setEyeshadowIntensity:intensity.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYESHADOW_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveEyeshadow:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] removeEyeshadow];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYESHADOW_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleHasEyeshadow:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result(@NO);
    return;
  }

  @try {
    BOOL hasEyeshadow = [NosmaiSDK sharedInstance].hasEyeshadow;
    result(@(hasEyeshadow));
  } @catch (NSException *exception) {
    result(@NO);
  }
}

#pragma mark - Blusher Methods

- (void)handleApplyBlusher:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying blusher"
                               details:nil]);
    return;
  }

  NSNumber* styleNum = call.arguments[@"style"];
  NSNumber* intensity = call.arguments[@"intensity"];

  if (!styleNum) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Style is required"
                               details:nil]);
    return;
  }

  @try {
    NosmaiBlusherStyle style = (NosmaiBlusherStyle)styleNum.integerValue;
    [[NosmaiSDK sharedInstance] applyBlusherWithStyle:style
                                           colorIndex:0];

    if (intensity) {
      [[NosmaiSDK sharedInstance] setBlusherIntensity:intensity.floatValue];
    }

    result(@YES);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"BLUSHER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleSetBlusherIntensity:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSNumber* intensity = call.arguments[@"intensity"];
  if (!intensity) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Intensity value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] setBlusherIntensity:intensity.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"BLUSHER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveBlusher:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] removeBlusher];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"BLUSHER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleHasBlusher:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result(@NO);
    return;
  }

  @try {
    BOOL hasBlusher = [NosmaiSDK sharedInstance].hasBlusher;
    result(@(hasBlusher));
  } @catch (NSException *exception) {
    result(@NO);
  }
}

#pragma mark - Eyelash Methods

- (void)handleApplyEyelash:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying eyelash"
                               details:nil]);
    return;
  }

  NSNumber* styleNum = call.arguments[@"style"];
  NSNumber* intensity = call.arguments[@"intensity"];

  if (!styleNum) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Style is required"
                               details:nil]);
    return;
  }

  @try {
    NosmaiEyelashStyle style = (NosmaiEyelashStyle)styleNum.integerValue;
    [[NosmaiSDK sharedInstance] applyEyelashWithStyle:style];

    if (intensity) {
      [[NosmaiSDK sharedInstance] setEyelashIntensity:intensity.floatValue];
    }

    result(@YES);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYELASH_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleSetEyelashIntensity:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSNumber* intensity = call.arguments[@"intensity"];
  if (!intensity) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Intensity value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] setEyelashIntensity:intensity.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYELASH_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveEyelash:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] removeEyelash];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYELASH_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleHasEyelash:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result(@NO);
    return;
  }

  @try {
    BOOL hasEyelash = [NosmaiSDK sharedInstance].hasEyelash;
    result(@(hasEyelash));
  } @catch (NSException *exception) {
    result(@NO);
  }
}

#pragma mark - Eyebrow Methods

- (void)handleApplyEyebrow:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying eyebrow"
                               details:nil]);
    return;
  }

  NSNumber* styleNum = call.arguments[@"style"];
  NSNumber* intensity = call.arguments[@"intensity"];

  if (!styleNum) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Style is required"
                               details:nil]);
    return;
  }

  @try {
    NosmaiEyebrowStyle style = (NosmaiEyebrowStyle)styleNum.integerValue;
    [[NosmaiSDK sharedInstance] applyEyebrowWithStyle:style
                                           colorIndex:0];

    if (intensity) {
      [[NosmaiSDK sharedInstance] setEyebrowIntensity:intensity.floatValue];
    }

    result(@YES);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYEBROW_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleSetEyebrowIntensity:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSNumber* intensity = call.arguments[@"intensity"];
  if (!intensity) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Intensity value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] setEyebrowIntensity:intensity.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYEBROW_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveEyebrow:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] removeEyebrow];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYEBROW_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleHasEyebrow:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result(@NO);
    return;
  }

  @try {
    BOOL hasEyebrow = [NosmaiSDK sharedInstance].hasEyebrow;
    result(@(hasEyebrow));
  } @catch (NSException *exception) {
    result(@NO);
  }
}

#pragma mark - Face Morphing Methods

- (void)handleSetFaceSlimLevel:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSNumber* level = call.arguments[@"level"];
  if (!level) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Level value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] setFaceSlimLevel:level.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"MORPHING_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleSetEyeSizeLevel:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSNumber* level = call.arguments[@"level"];
  if (!level) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Level value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] setEyeSizeLevel:level.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"MORPHING_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleSetNoseSlimLevel:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSNumber* level = call.arguments[@"level"];
  if (!level) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Level value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] setNoseSlimLevel:level.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"MORPHING_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveAllMorphing:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] removeAllMorphing];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"MORPHING_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

#pragma mark - Eye Coloring Methods

- (void)handleSetEyeColor:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before setting eye color"
                               details:nil]);
    return;
  }

  NSNumber* r = call.arguments[@"r"];
  NSNumber* g = call.arguments[@"g"];
  NSNumber* b = call.arguments[@"b"];
  NSNumber* intensity = call.arguments[@"intensity"];

  if (!r || !g || !b) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"RGB values are required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] setEyeColorR:r.floatValue
                                           g:g.floatValue
                                           b:b.floatValue];

    if (intensity) {
      [[NosmaiSDK sharedInstance] setEyeColorIntensity:intensity.floatValue];
    }

    result(@YES);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYE_COLOR_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleSetEyeColorIntensity:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSNumber* intensity = call.arguments[@"intensity"];
  if (!intensity) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Intensity value is required"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] setEyeColorIntensity:intensity.floatValue];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYE_COLOR_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveEyeColoring:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] removeEyeColoring];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EYE_COLOR_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

#pragma mark - Utility Methods

- (void)handleRemoveAllMakeup:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] removeAllMakeup];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"UTILITY_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveAllBeautyEffects:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  @try {
    [[NosmaiSDK sharedInstance] removeAllBeautyEffects];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"UTILITY_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

#pragma mark - File Loading and Camera Control

- (void)updateGameEventHandler {
  NosmaiEffectsEngine *effects = [NosmaiCore shared].effects;
  effects.gameEventHandler = nil;
  if (!self.gameEventsEnabled || !self.isInitialized) return;

  __weak typeof(self) weakSelf = self;
  effects.gameEventHandler = ^(NSDictionary<NSString *, id> *event) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.gameEventsEnabled || !event) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongSelf.channel invokeMethod:@"onGameEvent" arguments:event];
    });
  };
}

- (void)handleSetGameEventListenerEnabled:(FlutterMethodCall*)call
                                   result:(FlutterResult)result {
  self.gameEventsEnabled = [call.arguments[@"enabled"] boolValue];
  [self updateGameEventHandler];
  result(nil);
}

- (void)handleIsGameReady:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result(@NO);
    return;
  }
  result(@([[NosmaiCore shared].effects isGameReady]));
}

- (BOOL)readGameCoordinate:(id)value output:(float*)output {
  if (![value isKindOfClass:[NSNumber class]]) return NO;
  double coordinate = [value doubleValue];
  if (!isfinite(coordinate) || coordinate < 0.0 || coordinate > 1.0) return NO;
  *output = (float)coordinate;
  return YES;
}

- (void)handleSendGameTap:(FlutterMethodCall*)call result:(FlutterResult)result {
  float x = 0.0f;
  float y = 0.0f;
  if (![self readGameCoordinate:call.arguments[@"x"] output:&x] ||
      ![self readGameCoordinate:call.arguments[@"y"] output:&y]) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                               message:@"x and y must be finite values from 0 to 1"
                               details:nil]);
    return;
  }
  result(@([[NosmaiCore shared].effects sendGameTapAtNormalizedX:x y:y]));
}

- (void)handleSendGameInput:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString *name = [call.arguments[@"name"] isKindOfClass:[NSString class]]
      ? [call.arguments[@"name"] stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]]
      : nil;
  float x = 0.0f;
  float y = 0.0f;
  NSNumber *rawValue = [call.arguments[@"value"] isKindOfClass:[NSNumber class]]
      ? call.arguments[@"value"]
      : nil;
  if (name.length == 0 ||
      ![self readGameCoordinate:call.arguments[@"x"] output:&x] ||
      ![self readGameCoordinate:call.arguments[@"y"] output:&y] ||
      !rawValue || !isfinite(rawValue.doubleValue)) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                               message:@"name, normalized x/y, and a finite value are required"
                               details:nil]);
    return;
  }
  result(@([[NosmaiCore shared].effects sendGameInput:name
                                         normalizedX:x
                                                   y:y
                                               value:rawValue.floatValue]));
}


- (void)handleSwitchCamera:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before switching camera"
                               details:nil]);
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      BOOL success = [[NosmaiCore shared].camera switchCamera];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (success) {
          result(@(success));
        } else {
          result([FlutterError errorWithCode:@"CAMERA_SWITCH_FAILED"
                                     message:@"Camera switch operation failed"
                                     details:@{@"reason": @"Switch operation returned false"}]);
        }
      });
    } @catch (NSException *exception) {
      dispatch_async(dispatch_get_main_queue(), ^{
        NSString *errorCode = @"CAMERA_SWITCH_FAILED";
        NSString *errorMessage = exception.reason ?: @"Camera switch failed";

        if ([exception.reason containsString:@"unavailable"] || [exception.reason containsString:@"not found"]) {
          errorCode = @"CAMERA_UNAVAILABLE";
          errorMessage = @"Camera is not available";
        } else if ([exception.reason containsString:@"permission"]) {
          errorCode = @"CAMERA_PERMISSION_DENIED";
          errorMessage = @"Camera permission is required";
        }

        result([FlutterError errorWithCode:errorCode
                                   message:errorMessage
                                   details:@{@"originalError": exception.reason ?: @"Unknown error"}]);
      });
    }
  });
}


- (void)handleRemoveAllFilters:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before removing filters"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  dispatch_semaphore_wait(self.filterOperationSemaphore, DISPATCH_TIME_FOREVER);

	  @try {
	    [[NosmaiCore shared].effects removeAllEffects];
	    dispatch_semaphore_signal(self.filterOperationSemaphore);
	    [self emitPipelineStateToFlutter];
	    result(nil);
  } @catch (NSException *exception) {
    dispatch_semaphore_signal(self.filterOperationSemaphore);
    result([FlutterError errorWithCode:@"REMOVE_FILTERS_ERROR"
                               message:[NSString stringWithFormat:@"Failed to remove filters: %@", exception.reason]
                               details:exception.userInfo.description]);
  }
}

- (void)handleClearAREffect:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

	  @try {
	    [[NosmaiCore shared].effects clearAREffect];
	    [self emitPipelineStateToFlutter];
	    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"CLEAR_AR_EFFECT_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleClearFilter:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

	  @try {
	    [[NosmaiCore shared].effects clearFilter];
	    [self emitPipelineStateToFlutter];
	    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"CLEAR_FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleClearAll:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

	  @try {
	    [[NosmaiCore shared].effects clearAll];
	    [self emitPipelineStateToFlutter];
	    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"CLEAR_ALL_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleCleanup:(FlutterMethodCall*)call result:(FlutterResult)result {
  @try {
    [NosmaiCore shared].effects.gameEventHandler = nil;
    if (self.isInitialized) {
      [[NosmaiCore shared] cleanup];
    }

    [self clearFilterCache];

    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"CLEANUP_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleClearFilterCache:(FlutterMethodCall*)call result:(FlutterResult)result {
  [self clearFilterCache];
  result(nil);
}

- (void)clearFilterCache {
  [self.filterCache removeAllObjects];
  dispatch_barrier_async(self.cacheQueue, ^{
    self.cachedLocalFilters = nil;
    self.lastFilterCacheTime = nil;
  });
}

#pragma mark - Thread-Safe Cache Methods

- (NSArray *)getCachedLocalFilters {
  __block NSArray *filters;
  dispatch_sync(self.cacheQueue, ^{
    filters = self.cachedLocalFilters;
  });
  return filters;
}

- (NSDate *)getLastFilterCacheTime {
  __block NSDate *cacheTime;
  dispatch_sync(self.cacheQueue, ^{
    cacheTime = self.lastFilterCacheTime;
  });
  return cacheTime;
}

- (void)setCachedLocalFilters:(NSArray *)filters withCacheTime:(NSDate *)cacheTime {
  dispatch_barrier_async(self.cacheQueue, ^{
    self.cachedLocalFilters = filters;
    self.lastFilterCacheTime = cacheTime;
  });
}

/// Clear all local filters cache (both global cache and individual filter cache)
- (void)clearLocalFiltersCacheInternal {
  dispatch_barrier_async(self.cacheQueue, ^{
    self.cachedLocalFilters = nil;
    self.lastFilterCacheTime = nil;
  });

  // Recreate filter cache to clear individual filter entries
  self.filterCache = [[NSCache alloc] init];
  self.filterCache.countLimit = 100;
  self.filterCache.totalCostLimit = 50 * 1024 * 1024;
}

/// Handle clearLocalFiltersCache method from Flutter
- (void)handleClearLocalFiltersCache:(FlutterMethodCall*)call result:(FlutterResult)result {
  @try {
    [self clearLocalFiltersCacheInternal];
    result(@YES);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"CACHE_CLEAR_ERROR"
                               message:exception.reason
                               details:nil]);
  }
}

- (void)handleDetachCameraView:(FlutterMethodCall*)call result:(FlutterResult)result {
  @try {
    if (self.isInitialized) {
      dispatch_semaphore_wait(self.cameraStateSemaphore, DISPATCH_TIME_FOREVER);

      BOOL detached = [NosmaiCameraPreviewView detachActivePreview];
      self.isCameraAttached = NO;
      [[NosmaiSDK sharedInstance] setPreviewView:nil];

      if (detached) {
        [self.channel invokeMethod:@"onCameraDetached" arguments:nil];
      }
      dispatch_semaphore_signal(self.cameraStateSemaphore);
    }
    result(nil);
  } @catch (NSException *exception) {
    dispatch_semaphore_signal(self.cameraStateSemaphore);
    result([FlutterError errorWithCode:@"DETACH_CAMERA_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleReinitializePreview:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before reinitializing preview"
                               details:nil]);
    return;
  }

  @try {
    [NosmaiCameraPreviewView reattachActivePreviewIfReady];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"REINIT_PREVIEW_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}




- (void)handleSetPreviewView:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before setting preview view"
                               details:nil]);
    return;
  }

  @try {
    [NosmaiCameraPreviewView reattachActivePreviewIfReady];
    result(nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"SET_PREVIEW_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

#pragma mark - New SDK Features

- (void)handleApplyEffect:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying effects"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  NSString* effectPath = call.arguments[@"effectPath"];

  if (!effectPath || effectPath.length == 0) {
    result([FlutterError errorWithCode:@"INVALID_EFFECT_PATH"
                               message:@"Invalid or missing effect path"
                               details:@"A valid effect path is required to apply filters."]);
    return;
  }

  dispatch_semaphore_wait(self.filterOperationSemaphore, DISPATCH_TIME_FOREVER);

  [[NosmaiCore shared].effects applyEffect:effectPath completion:^(BOOL success, NSError *error) {
    dispatch_semaphore_signal(self.filterOperationSemaphore);

	    if (success) {
	      [self emitPipelineStateToFlutter];
	      result(@YES);
    } else {
      NSString *errorMessage = error ? error.localizedDescription : @"Failed to apply effect";
      NSString *errorDetails = [NSString stringWithFormat:@"Effect path: %@", effectPath];
      result([FlutterError errorWithCode:@"EFFECT_APPLY_FAILED"
                                 message:errorMessage
                                 details:errorDetails]);
    }
  }];
}

- (void)handleApplyFilter:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before applying filters"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  NSString* filterPath = call.arguments[@"filterPath"];

  if (!filterPath || filterPath.length == 0) {
    result([FlutterError errorWithCode:@"INVALID_FILTER_PATH"
                               message:@"Invalid or missing filter path"
                               details:@"A valid filter path is required to apply filters."]);
    return;
  }

  dispatch_semaphore_wait(self.filterOperationSemaphore, DISPATCH_TIME_FOREVER);

  [[NosmaiCore shared].effects applyEffect:filterPath completion:^(BOOL success, NSError *error) {
    dispatch_semaphore_signal(self.filterOperationSemaphore);

	    if (success) {
	      [self emitPipelineStateToFlutter];
	      result(@YES);
    } else {
      NSString *errorMessage = error ? error.localizedDescription : @"Failed to apply filter";
      NSString *errorDetails = [NSString stringWithFormat:@"Filter path: %@", filterPath];
      result([FlutterError errorWithCode:@"FILTER_APPLY_FAILED"
                                 message:errorMessage
                                 details:errorDetails]);
    }
  }];
}

- (NSString *)pipelineModeName:(NSInteger)mode {
  switch (mode) {
    case NosmaiPipelineModeEffectsFilters:
      return @"effectsFilters";
    case NosmaiPipelineModeFiltersBackground:
      return @"filtersBackground";
    case NosmaiPipelineModeBeautyFilters:
      return @"beautyFilters";
    case NosmaiPipelineModeIdle:
    default:
      return @"idle";
  }
}

- (NSDictionary *)dictionaryFromBridgeObject:(id)object {
  if (!object) return nil;
  SEL selector = NSSelectorFromString(@"dictionaryRepresentation");
  if (![object respondsToSelector:selector]) return nil;

  NSDictionary *(*function)(id, SEL) =
      (NSDictionary *(*)(id, SEL))[object methodForSelector:selector];
  id value = function(object, selector);
  return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

- (NSDictionary *)minimalFilterInfoForPath:(NSString *)path filterType:(NSString *)filterType {
  if (path.length == 0) return nil;
  NSString *fileName = [[path lastPathComponent] stringByDeletingPathExtension];
  return @{
    @"id": fileName ?: @"",
    @"name": fileName ?: @"",
    @"displayName": fileName ?: @"",
    @"path": path,
    @"effectPath": path,
    @"filterType": filterType ?: @"effect",
    @"type": @"local",
    @"isDownloaded": @YES
  };
}

- (NSDictionary *)localFilterInfoForPath:(NSString *)path {
  if (path.length == 0) return nil;
  NSString *targetPath = [path stringByStandardizingPath];

  @try {
    NSArray<NSDictionary *> *filters = [self sanitizeFiltersForFlutter:[self getFlutterLocalFilters]];
    for (NSDictionary *filter in filters) {
      NSArray *candidateKeys = @[@"path", @"localPath", @"effectPath"];
      for (NSString *key in candidateKeys) {
        id value = filter[key];
        if (![value isKindOfClass:[NSString class]]) continue;
        NSString *candidatePath = [(NSString *)value stringByStandardizingPath];
        if ([candidatePath isEqualToString:targetPath]) {
          return filter;
        }
      }
    }
  } @catch (NSException *exception) {
    return nil;
  }

  return nil;
}

- (NSDictionary *)activeInfoForSelector:(NSString *)selectorName
                           fallbackPath:(NSString *)path
                             filterType:(NSString *)filterType {
  // Flutter assets are discovered by this bridge and may not be present in the
  // framework's native catalog. Prefer their manifest metadata so a
  // beauty_effect is not downgraded to the SDK's minimal "effect" fallback.
  NSDictionary *localInfo = [self localFilterInfoForPath:path];
  if (localInfo) return localInfo;

  id effects = [NosmaiSDK sharedInstance];
  SEL selector = NSSelectorFromString(selectorName);
  if ([effects respondsToSelector:selector]) {
    id (*function)(id, SEL) = (id (*)(id, SEL))[effects methodForSelector:selector];
    NSDictionary *map = [self dictionaryFromBridgeObject:function(effects, selector)];
    if (map) return map;
  }
  return [self minimalFilterInfoForPath:path filterType:filterType];
}

- (NSDictionary *)pipelineStateMapForFlutter:(NosmaiPipelineState *)state {
  NSMutableDictionary *map = nil;
  NSDictionary *nativeMap = [self dictionaryFromBridgeObject:state];
  if (nativeMap) {
    map = [nativeMap mutableCopy];
  } else {
    NSInteger mode = state ? state.mode : NosmaiPipelineModeIdle;
    NSString *filterPath = state.activeFilterPath;
    NSString *effectPath = state.activeEffectPath;
    BOOL hasManualBackground = state.activeBackgroundConfig != nil;
    BOOL hasBackground = hasManualBackground;
    @try {
      hasBackground = [[NosmaiCore shared].effects isBackgroundSegmentationActive];
    } @catch (NSException *exception) {
      hasBackground = hasManualBackground;
    }

    map = [@{
      @"mode": @(mode),
      @"modeName": [self pipelineModeName:mode],
      @"activeFilterPath": filterPath ?: [NSNull null],
      @"activeEffectPath": effectPath ?: [NSNull null],
      @"activeBackgroundPath": [NSNull null],
      @"activeBackgroundPackagePath": [NSNull null],
      @"hasBackground": @(hasBackground),
      @"backgroundActive": @(hasBackground),
      @"backgroundSource": hasBackground ? @1 : @0,
      @"backgroundSourceName": hasBackground ? @"manual" : @"none",
      @"hasBeautyEffect": @NO,
      @"hasBuiltInBeauty": @([[NosmaiCore shared].effects hasAnyBeautyEffect]),
      @"hasManualBackground": @(hasManualBackground),
      @"hasManualBackgroundConfig": @(hasManualBackground)
    } mutableCopy];
  }

  NSString *activeFilterPath = [map[@"activeFilterPath"] isKindOfClass:[NSString class]]
      ? map[@"activeFilterPath"]
      : nil;
  NSString *activeEffectPath = [map[@"activeEffectPath"] isKindOfClass:[NSString class]]
      ? map[@"activeEffectPath"]
      : nil;
  NSString *activeEffectFallbackType =
      [self normalizeLocalFilterTypeForFlutter:map[@"activeEffectType"]];

  if (!map[@"activeBackgroundPath"] || [map[@"activeBackgroundPath"] isKindOfClass:[NSNull class]]) {
    map[@"activeBackgroundPath"] = map[@"activeBackgroundPackagePath"] ?: [NSNull null];
  }
  if (!map[@"hasBackground"] || [map[@"hasBackground"] isKindOfClass:[NSNull class]]) {
    map[@"hasBackground"] = map[@"backgroundActive"] ?: @NO;
  }
  if (!map[@"hasManualBackground"] || [map[@"hasManualBackground"] isKindOfClass:[NSNull class]]) {
    map[@"hasManualBackground"] = map[@"hasManualBackgroundConfig"] ?: @NO;
  }

  map[@"activeFilterInfo"] =
      [self activeInfoForSelector:@"activeFilterInfo"
                     fallbackPath:activeFilterPath
                       filterType:@"filter"] ?: [NSNull null];
  map[@"activeEffectInfo"] =
      [self activeInfoForSelector:@"activeEffectInfo"
                     fallbackPath:activeEffectPath
                       filterType:activeEffectFallbackType] ?: [NSNull null];
  // Native pipeline dictionaries predate this field. Query the authoritative
  // SDK state on every snapshot instead of treating a missing value as false.
  BOOL hasActiveBuiltInFilters = [[NosmaiSDK sharedInstance] hasActiveBuiltInFilters];
  map[@"hasBuiltInBeauty"] = @(hasActiveBuiltInFilters);
  NSDictionary *activeEffectInfo = [map[@"activeEffectInfo"] isKindOfClass:[NSDictionary class]]
      ? map[@"activeEffectInfo"]
      : nil;
  NSString *activeEffectType = [self normalizeLocalFilterTypeForFlutter:activeEffectInfo[@"filterType"]];
  map[@"hasBeautyEffect"] = @([activeEffectType isEqualToString:@"beauty_effect"]);
  return map;
}

- (void)emitPipelineStateToFlutter {
  if (!self.isInitialized) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      NosmaiPipelineState *state = [[NosmaiCore shared].effects currentPipelineState];
      [self.channel invokeMethod:@"onActiveEffectsChanged"
                       arguments:[self pipelineStateMapForFlutter:state]];
    } @catch (NSException *exception) {
      // State events are best-effort.
    }
  });
}

- (void)handleGetCurrentPipelineState:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before reading active effects"
                               details:nil]);
    return;
  }

  @try {
    NosmaiPipelineState *state = [[NosmaiCore shared].effects currentPipelineState];
    result([self pipelineStateMapForFlutter:state]);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"ACTIVE_EFFECTS_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleGetActiveFilterInfo:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before reading active filter"
                               details:nil]);
    return;
  }

  @try {
    NosmaiPipelineState *state = [[NosmaiCore shared].effects currentPipelineState];
    result([self activeInfoForSelector:@"activeFilterInfo"
                          fallbackPath:state.activeFilterPath
                            filterType:@"filter"]);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"ACTIVE_FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleGetActiveEffectInfo:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before reading active effect"
                               details:nil]);
    return;
  }

  @try {
    NosmaiPipelineState *state = [[NosmaiCore shared].effects currentPipelineState];
    NSDictionary *pipelineState = [self pipelineStateMapForFlutter:state];
    id activeEffectInfo = pipelineState[@"activeEffectInfo"];
    result([activeEffectInfo isKindOfClass:[NSDictionary class]]
               ? activeEffectInfo
               : nil);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"ACTIVE_EFFECT_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleRemoveEffect:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before removing effects"
                               details:nil]);
    return;
  }

  NSDictionary *rawFilter = nil;
  if ([call.arguments isKindOfClass:[NSDictionary class]]) {
    id value = ((NSDictionary *)call.arguments)[@"filter"];
    rawFilter = [value isKindOfClass:[NSDictionary class]]
        ? (NSDictionary *)value
        : (NSDictionary *)call.arguments;
  }

  if (!rawFilter) {
    result([FlutterError errorWithCode:@"INVALID_FILTER"
                               message:@"A filter map is required"
                               details:nil]);
    return;
  }

  @try {
    NSMutableDictionary *filterMap = [rawFilter mutableCopy];
    if (!filterMap[@"filterType"]) {
      id rawType = filterMap[@"sourceType"] ?: filterMap[@"filterCategory"];
      filterMap[@"filterType"] = [self normalizeLocalFilterTypeForFlutter:rawType];
    }
    filterMap[@"filterType"] = [self normalizeLocalFilterTypeForFlutter:filterMap[@"filterType"]];
    NosmaiFilterInfo *info = [NosmaiFilterInfo filterInfoWithDictionary:filterMap];
    [[NosmaiSDK sharedInstance] removeEffectInfo:info];
    [self emitPipelineStateToFlutter];
    result(@YES);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"REMOVE_EFFECT_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)completeCloudDownloadForFilterId:(NSString *)filterId value:(id)value {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSArray *callbacks = nil;
    @synchronized (self) {
      callbacks = [self.pendingCloudDownloadResults[filterId] copy];
      [self.pendingCloudDownloadResults removeObjectForKey:filterId];
    }
    for (id callbackObject in callbacks) {
      FlutterResult callback = (FlutterResult)callbackObject;
      callback(value);
    }
  });
}

- (void)handleDownloadCloudFilter:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before downloading cloud filters"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  NSString* filterId = call.arguments[@"filterId"];

  if (!filterId || filterId.length == 0) {
    result([FlutterError errorWithCode:@"INVALID_FILTER_ID"
                               message:@"Invalid or missing filter ID"
                               details:@"A valid filter ID is required to download cloud filters."]);
    return;
  }

  if (![self isNetworkAvailable]) {
    result([FlutterError errorWithCode:@"NETWORK_UNAVAILABLE"
                               message:@"No internet connection available"
                               details:@"Filter download requires an active internet connection."]);
    return;
  }

  if ([[NosmaiSDK sharedInstance] isCloudFilterDownloaded:filterId]) {
    NSString* localPath = [[NosmaiSDK sharedInstance] getCloudFilterLocalPath:filterId];
    if (!localPath || localPath.length == 0) {
      result([FlutterError errorWithCode:@"DOWNLOAD_PATH_ERROR"
                                 message:@"Filter marked as downloaded but local path is unavailable"
                                 details:@"The filter appears to be downloaded but the file path cannot be found."]);
      return;
    }
    result(@{
      @"success": @YES,
      @"localPath": localPath,
      @"path": localPath
    });
    return;
  }

  @synchronized (self) {
    if (!self.pendingCloudDownloadResults) {
      self.pendingCloudDownloadResults = [NSMutableDictionary dictionary];
    }
    NSMutableArray *callbacks = self.pendingCloudDownloadResults[filterId];
    if (!callbacks) {
      callbacks = [NSMutableArray array];
      self.pendingCloudDownloadResults[filterId] = callbacks;
    }
    [callbacks addObject:[result copy]];
    if (callbacks.count > 1) {
      return;
    }
  }

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    FlutterError *timeout = [FlutterError errorWithCode:@"DOWNLOAD_TIMEOUT"
                                                 message:@"Cloud filter download timed out"
                                                 details:nil];
    [self completeCloudDownloadForFilterId:filterId value:timeout];
  });

  [[NosmaiSDK sharedInstance] downloadCloudFilter:filterId
                                          progress:^(float progress) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.channel invokeMethod:@"onDownloadProgress" arguments:@{
        @"filterId": filterId,
        @"progress": @(progress)
      }];
    });
  }
                                        completion:^(BOOL success, NSString *localPath, NSError *error) {
    id response = nil;
    if (success && localPath && localPath.length > 0) {
      response = @{
        @"success": @YES,
        @"localPath": localPath,
        @"path": localPath
      };
    } else {
      NSString *errorMessage;
      NSString *errorCode;
      NSString *errorDetails;

      if (error) {
        errorMessage = error.localizedDescription;
        errorCode = [NSString stringWithFormat:@"DOWNLOAD_ERROR_%ld", (long)error.code];
        errorDetails = [NSString stringWithFormat:@"Filter ID: %@, Error Code: %ld", filterId, (long)error.code];
      } else if (!localPath || localPath.length == 0) {
        errorMessage = @"Download completed but local path is missing";
        errorCode = @"DOWNLOAD_PATH_MISSING";
        errorDetails = [NSString stringWithFormat:@"Filter ID: %@, Download success but no file path returned", filterId];
      } else {
        errorMessage = @"Unknown download failure";
        errorCode = @"DOWNLOAD_UNKNOWN_ERROR";
        errorDetails = [NSString stringWithFormat:@"Filter ID: %@", filterId];
      }

      response = [FlutterError errorWithCode:errorCode
                                     message:errorMessage
                                     details:errorDetails];
    }
    [self completeCloudDownloadForFilterId:filterId value:response];
  }];
}

- (void)handleRemoveCloudFilter:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSString* filterId = call.arguments[@"filterId"];
  if (!filterId || filterId.length == 0) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Filter ID is required"
                               details:nil]);
    return;
  }

  @try {
    BOOL success = [[NosmaiCore shared].effects removeCloudFilter:filterId];
    result(@(success));
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"REMOVE_CLOUD_FILTER_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleGetCloudFilters:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before getting cloud filters"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  if (![self isNetworkAvailable]) {
    result([FlutterError errorWithCode:@"NETWORK_UNAVAILABLE"
                               message:@"No internet connection available"
                               details:@"Cloud filters require an active internet connection. Please check your network settings and try again."]);
    return;
  }

  // Extract pagination parameters from arguments (all optional for backward compatibility)
  NSDictionary *arguments = call.arguments;
  NSString *filterType = nil;
  NSString *version = nil;
  NSNumber *page = nil;
  NSNumber *limit = nil;
  BOOL fetchAllPages = YES; // Default to YES for backward compatibility

  if (arguments && [arguments isKindOfClass:[NSDictionary class]]) {
    filterType = arguments[@"filterType"];
    version = arguments[@"version"];
    page = arguments[@"page"];
    limit = arguments[@"limit"];
    if (arguments[@"fetchAllPages"] != nil) {
      fetchAllPages = [arguments[@"fetchAllPages"] boolValue];
    }
  }

  if (version.length > 0 && ![version isEqualToString:@"2.0.0"]) {
    result([FlutterError errorWithCode:@"UNSUPPORTED_CLOUD_FILTER_VERSION"
                               message:@"Unsupported cloud filter version"
                               details:version]);
    return;
  }

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSArray<NSDictionary *> *cloudFilters = nil;
    NSDictionary *paginationInfo = nil;

    // The options API must also be used for type-only and fetch-all requests.
    // Falling back merely because page is absent drops filterType on iOS.
    if ([[NosmaiSDK sharedInstance] respondsToSelector:@selector(getCloudFiltersWithOptions:)]) {
      NosmaiCloudFilterRequestOptions *options = [NosmaiCloudFilterRequestOptions defaultOptions];
      options.version = NosmaiCloudFilterVersion2;
      if (filterType) {
        options.filterType = [self normalizeCloudFilterTypeForRequest:filterType];
      }
      options.page = page ? MAX(1, [page integerValue]) : 1;
      options.limit = limit ? MAX(1, [limit integerValue]) : 20;
      options.fetchAllPages = fetchAllPages;

      NSDictionary *paginatedResult = [[NosmaiSDK sharedInstance] getCloudFiltersWithOptions:options];
      cloudFilters = paginatedResult[@"filters"];

      // Extract pagination info
      id paginationData = paginatedResult[@"pagination"];
      if (paginationData && [paginationData isKindOfClass:[NSDictionary class]]) {
        paginationInfo = (NSDictionary *)paginationData;
      } else if (paginationData && [paginationData respondsToSelector:@selector(currentPage)]) {
        // Handle NosmaiCloudFilterPaginationInfo object
        NosmaiCloudFilterPaginationInfo *pagination = paginationData;
        paginationInfo = @{
          @"currentPage": @(pagination.currentPage),
          @"totalPages": @(pagination.totalPages),
          @"totalItems": @(pagination.totalFilters),
          @"itemsPerPage": @(pagination.limit),
          @"hasNextPage": @(pagination.hasNextPage),
          @"hasPreviousPage": @(pagination.hasPreviousPage)
        };
      }
    } else {
      // Fallback to legacy API for backward compatibility
      cloudFilters = [[NosmaiSDK sharedInstance] getCloudFilters];
    }

    if (cloudFilters && cloudFilters.count > 0) {
      NSMutableArray *enhancedFilters = [NSMutableArray array];

      for (NSDictionary *filter in cloudFilters) {
        NSMutableDictionary *enhancedFilter = [filter mutableCopy];

        id pathValue = filter[@"path"];
        id localPathValue = filter[@"localPath"];
        NSString *filterPath = nil;

        if ([pathValue isKindOfClass:[NSString class]]) {
          filterPath = pathValue;
        } else if ([localPathValue isKindOfClass:[NSString class]]) {
          filterPath = localPathValue;
        }

        if (!filterPath || filterPath.length == 0) {
          NSString *filterId = filter[@"id"] ?: filter[@"filterId"];
          NSString *filterName = filter[@"name"];
          NSString *category = filter[@"filterCategory"];

          if (filterId && filterName && category) {
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
            if (paths.count > 0) {
              NSString *cachesDir = paths[0];
              NSString *cloudFiltersDir = [cachesDir stringByAppendingPathComponent:@"NosmaiCloudFilters"];
              NSString *normalizedName = [[filterName lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
              NSArray *possibleFilenames = @[
                [NSString stringWithFormat:@"%@_%@_%@.nosmai", category, normalizedName, filterId],
                [NSString stringWithFormat:@"%@_%@.nosmai", category, filterId],
                [NSString stringWithFormat:@"%@.nosmai", filterId],
                [NSString stringWithFormat:@"special-effects_%@_%@.nosmai", normalizedName, filterId],
              ];

              for (NSString *filename in possibleFilenames) {
                NSString *possiblePath = [cloudFiltersDir stringByAppendingPathComponent:filename];
                if ([[NSFileManager defaultManager] fileExistsAtPath:possiblePath]) {
                  filterPath = possiblePath;
                  break;
                }
              }
            }
          }
        }

        if (filter[@"filterCategory"] && ![filter[@"filterCategory"] isKindOfClass:[NSNull class]]) {
          enhancedFilter[@"filterCategory"] = filter[@"filterCategory"];
        }

        if (enhancedFilter[@"type"]) {
          enhancedFilter[@"originalType"] = enhancedFilter[@"type"];
        }
        enhancedFilter[@"type"] = @"cloud";

        NSString *filterTypeValue = @"effect";
        NSString *rawType = [filter[@"filterType"] isKindOfClass:[NSString class]]
            ? [filter[@"filterType"] lowercaseString]
            : nil;
        NSString *filterCategory =
            [filter[@"filterCategory"] isKindOfClass:[NSString class]]
                ? [filter[@"filterCategory"] lowercaseString]
                : nil;
        NSString *typeSource = rawType.length > 0 ? rawType : filterCategory;

        if ([typeSource isEqualToString:@"filter"] ||
            [typeSource isEqualToString:@"filters"] ||
            [typeSource isEqualToString:@"cloud-filters"] ||
            [typeSource isEqualToString:@"fx-and-filters"]) {
          filterTypeValue = @"filter";
        } else if ([typeSource isEqualToString:@"background"] ||
                   [typeSource isEqualToString:@"backgrounds"] ||
                   [typeSource isEqualToString:@"bg"]) {
          filterTypeValue = @"background";
        } else if ([typeSource isEqualToString:@"beauty_effect"] ||
                   [typeSource isEqualToString:@"beauty-effect"] ||
                   [typeSource isEqualToString:@"beauty-effects"]) {
          filterTypeValue = @"beauty_effect";
        } else if ([typeSource isEqualToString:@"game"] ||
                   [typeSource isEqualToString:@"games"]) {
          filterTypeValue = @"game";
        }
        enhancedFilter[@"filterType"] = filterTypeValue;

        BOOL isDownloaded = NO;

        if (filterPath && [[NSFileManager defaultManager] fileExistsAtPath:filterPath]) {
          isDownloaded = YES;
        }

        if (isDownloaded && filterPath && [[NSFileManager defaultManager] fileExistsAtPath:filterPath]) {
          UIImage *previewImage = [[NosmaiSDK sharedInstance] loadPreviewImageForFilter:filterPath];
          if (previewImage) {
            NSData *imageData = UIImageJPEGRepresentation(previewImage, 0.7);
            if (imageData) {
              NSString *base64String = [imageData base64EncodedStringWithOptions:0];
              enhancedFilter[@"previewImageBase64"] = base64String;
            }
          }
        }

        enhancedFilter[@"isDownloaded"] = @(isDownloaded);
        if (isDownloaded && filterPath) {
          enhancedFilter[@"path"] = filterPath;
          enhancedFilter[@"localPath"] = filterPath;
        }

        [enhancedFilters addObject:enhancedFilter];
      }

      NSArray<NSDictionary *> *sanitizedFilters = [self sanitizeFiltersForFlutter:enhancedFilters];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!sanitizedFilters || sanitizedFilters.count == 0) {
          result([FlutterError errorWithCode:@"CLOUD_FILTER_PROCESSING_FAILED"
                                     message:@"Failed to process cloud filters"
                                     details:@"Cloud filters received but could not be processed properly."]);
          return;
        }

        // Return dictionary with filters and optional pagination info
        NSMutableDictionary *response = [NSMutableDictionary dictionary];
        response[@"filters"] = sanitizedFilters;
        if (paginationInfo) {
          response[@"pagination"] = paginationInfo;
        }
        result(response);
      });
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        // Return empty result with structure for consistency
        result(@{
          @"filters": @[],
          @"pagination": paginationInfo ?: [NSNull null]
        });
      });
    }
  });
}

- (nullable NSString *)normalizeCloudFilterTypeForRequest:(id)rawType {
  if (![rawType isKindOfClass:[NSString class]]) {
    return nil;
  }

  NSString *type = [(NSString *)rawType lowercaseString];
  type = [type stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  type = [type stringByReplacingOccurrencesOfString:@"_" withString:@"-"];

  if (type.length == 0 || [type isEqualToString:@"all"]) {
    return nil;
  }
  if ([type isEqualToString:@"effect"] ||
      [type isEqualToString:@"effects"] ||
      [type isEqualToString:@"special-effect"] ||
      [type isEqualToString:@"special-effects"]) {
    return @"effects";
  }
  if ([type isEqualToString:@"filter"] ||
      [type isEqualToString:@"filters"] ||
      [type isEqualToString:@"fx-and-filter"] ||
      [type isEqualToString:@"fx-and-filters"] ||
      [type isEqualToString:@"cloud-filter"] ||
      [type isEqualToString:@"cloud-filters"]) {
    return @"filter";
  }
  if ([type isEqualToString:@"background"] ||
      [type isEqualToString:@"backgrounds"] ||
      [type isEqualToString:@"bg"]) {
    return @"bg";
  }
  if ([type isEqualToString:@"beauty"] ||
      [type isEqualToString:@"beauty-effect"] ||
      [type isEqualToString:@"beauty-effects"] ||
      [type isEqualToString:@"beautyeffect"]) {
    return @"beauty_effect";
  }
  if ([type isEqualToString:@"game"] ||
      [type isEqualToString:@"games"]) {
    return @"games";
  }

  return [(NSString *)rawType stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)handleGetLocalFilters:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before getting local filters"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  // Check for forceRefresh parameter
  BOOL forceRefresh = NO;
  if (call.arguments && [call.arguments isKindOfClass:[NSDictionary class]]) {
    NSDictionary *args = call.arguments;
    forceRefresh = [args[@"forceRefresh"] boolValue];
  }

  // Clear cache if forceRefresh requested
  if (forceRefresh) {
    [self clearLocalFiltersCacheInternal];
  }

  @try {
    NSArray<NSDictionary *> *allFilters = [self getFlutterLocalFilters];

    if (!allFilters) {
      result(@[]);
      return;
    }

    // Filter by filterType "filter" only (color grading/LUT filters)
    NSArray<NSDictionary *> *filters = [self filterLocalFiltersByType:allFilters filterType:@"filter"];
    NSArray<NSDictionary *> *sanitizedFilters = [self sanitizeFiltersForFlutter:filters];

    result(sanitizedFilters ?: @[]);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_LOAD_ERROR"
                               message:[NSString stringWithFormat:@"Error loading local filters: %@", exception.reason]
                               details:exception.userInfo.description]);
  }
}

- (void)handleGetAllLocalFilters:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before getting local filters"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  BOOL forceRefresh = NO;
  if (call.arguments && [call.arguments isKindOfClass:[NSDictionary class]]) {
    NSDictionary *args = call.arguments;
    forceRefresh = [args[@"forceRefresh"] boolValue];
  }

  if (forceRefresh) {
    [self clearLocalFiltersCacheInternal];
  }

  @try {
    NSArray<NSDictionary *> *allFilters = [self sanitizeFiltersForFlutter:[self getFlutterLocalFilters]];
    NSMutableDictionary *grouped = [@{
      @"filter": [NSMutableArray array],
      @"effect": [NSMutableArray array],
      @"background": [NSMutableArray array],
      @"beauty_effect": [NSMutableArray array],
      @"game": [NSMutableArray array]
    } mutableCopy];

    for (NSDictionary *filterInfo in allFilters) {
      NSString *type = [self normalizeLocalFilterTypeForFlutter:filterInfo[@"filterType"]];
      NSMutableArray *bucket = grouped[type];
      if (!bucket) {
        bucket = [NSMutableArray array];
        grouped[type] = bucket;
      }
      [bucket addObject:filterInfo];
    }

    result(grouped);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_LOAD_ERROR"
                               message:[NSString stringWithFormat:@"Error loading local filters: %@", exception.reason]
                               details:exception.userInfo.description]);
  }
}

- (void)handleGetDebugFilters:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before getting debug filters"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  NSString *requestedType = nil;
  if (call.arguments && [call.arguments isKindOfClass:[NSDictionary class]]) {
    NSDictionary *args = call.arguments;
    id rawType = args[@"filterType"] ?: args[@"type"];
    if ([rawType isKindOfClass:[NSString class]]) {
      NSString *value = [(NSString *)rawType lowercaseString];
      value = [value stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
      if (value.length > 0 && ![value isEqualToString:@"all"]) {
        requestedType = [self normalizeLocalFilterTypeForFlutter:value];
      }
    }
  }

  NosmaiFilterType nativeType = NosmaiFilterTypeUnknown;
  if ([requestedType isEqualToString:@"filter"]) {
    nativeType = NosmaiFilterTypeFilter;
  } else if ([requestedType isEqualToString:@"effect"]) {
    nativeType = NosmaiFilterTypeEffect;
  } else if ([requestedType isEqualToString:@"beauty_effect"]) {
    nativeType = NosmaiFilterTypeBeautyEffect;
  } else if ([requestedType isEqualToString:@"background"]) {
    nativeType = NosmaiFilterTypeBackground;
  } else if ([requestedType isEqualToString:@"game"]) {
    nativeType = NosmaiFilterTypeGame;
  }

  void (^completion)(NSArray<NosmaiFilterInfo *> *, NSError *) =
      ^(NSArray<NosmaiFilterInfo *> *filters, NSError *error) {
    if (error) {
      result([FlutterError errorWithCode:@"DEBUG_FILTER_LOAD_ERROR"
                                 message:error.localizedDescription ?: @"Error loading debug filters"
                                 details:error.userInfo]);
      return;
    }

    @try {
      NSMutableArray<NSDictionary *> *rawFilters =
          [NSMutableArray arrayWithCapacity:filters.count];

      for (NosmaiFilterInfo *filterInfo in filters) {
        NSMutableDictionary *debugInfo =
            [[filterInfo dictionaryRepresentation] mutableCopy];
        if (!debugInfo) {
          debugInfo = [NSMutableDictionary dictionary];
        }

        NSString *path = filterInfo.path;
        if (path.length > 0) {
          debugInfo[@"path"] = path;
        }
        debugInfo[@"filterType"] =
            [self normalizeLocalFilterTypeForFlutter:
                (filterInfo.typeKey ?: debugInfo[@"filterType"])];
        debugInfo[@"type"] = @"local";
        debugInfo[@"isDownloaded"] = @YES;
        [rawFilters addObject:[debugInfo copy]];
      }

      NSArray<NSDictionary *> *sanitizedFilters =
          [self sanitizeFiltersForFlutter:rawFilters];
      NSMutableArray<NSDictionary *> *debugFilters =
          [NSMutableArray arrayWithCapacity:sanitizedFilters.count];
      for (NSDictionary *filterInfo in sanitizedFilters) {
        NSMutableDictionary *debugInfo = [filterInfo mutableCopy];
        debugInfo[@"debug"] = @YES;
        NSString *path = debugInfo[@"path"];
        if (path.length > 0) {
          debugInfo[@"effectPath"] = path;
        }
        [debugFilters addObject:[debugInfo copy]];
      }

      result([debugFilters copy]);
    } @catch (NSException *exception) {
      result([FlutterError errorWithCode:@"DEBUG_FILTER_LOAD_ERROR"
                                 message:[NSString stringWithFormat:@"Error loading debug filters: %@", exception.reason]
                                 details:exception.userInfo.description]);
    }
  };

  @try {
    NosmaiSDK *sdk = [NosmaiSDK sharedInstance];
    if (requestedType) {
      [sdk getDebugFiltersOfType:nativeType completion:completion];
    } else {
      [sdk getDebugFiltersWithCompletion:completion];
    }
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"DEBUG_FILTER_LOAD_ERROR"
                               message:[NSString stringWithFormat:@"Error loading debug filters: %@", exception.reason]
                               details:exception.userInfo.description]);
  }
}

- (void)handleGetLocalEffects:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before getting local effects"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  @try {
    NSArray<NSDictionary *> *allFilters = [self getFlutterLocalFilters];
    NSArray<NSDictionary *> *effects = [self filterLocalFiltersByType:allFilters filterType:@"effect"];
    NSArray<NSDictionary *> *sanitizedEffects = [self sanitizeFiltersForFlutter:effects];
    result(sanitizedEffects);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_LOAD_ERROR"
                               message:[NSString stringWithFormat:@"Error loading local effects: %@", exception.reason]
                               details:exception.userInfo.description]);
  }
}

- (void)handleGetLocalBackgrounds:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before getting local backgrounds"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  @try {
    NSArray<NSDictionary *> *allFilters = [self getFlutterLocalFilters];
    NSArray<NSDictionary *> *backgrounds = [self filterLocalFiltersByType:allFilters filterType:@"background"];
    NSArray<NSDictionary *> *sanitizedBackgrounds = [self sanitizeFiltersForFlutter:backgrounds];
    result(sanitizedBackgrounds);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_LOAD_ERROR"
                               message:[NSString stringWithFormat:@"Error loading local backgrounds: %@", exception.reason]
                               details:exception.userInfo.description]);
  }
}

- (void)handleGetLocalBeautyEffects:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before getting local beauty effects"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  @try {
    NSArray<NSDictionary *> *allFilters = [self getFlutterLocalFilters];
    NSArray<NSDictionary *> *beautyEffects = [self filterLocalFiltersByType:allFilters filterType:@"beauty_effect"];
    NSArray<NSDictionary *> *sanitizedBeautyEffects = [self sanitizeFiltersForFlutter:beautyEffects];
    result(sanitizedBeautyEffects);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_LOAD_ERROR"
                               message:[NSString stringWithFormat:@"Error loading local beauty effects: %@", exception.reason]
                               details:exception.userInfo.description]);
  }
}

- (void)handleGetLocalGames:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before getting local games"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  @try {
    NSArray<NSDictionary *> *allFilters = [self getFlutterLocalFilters];
    NSArray<NSDictionary *> *games =
        [self filterLocalFiltersByType:allFilters filterType:@"game"];
    result([self sanitizeFiltersForFlutter:games]);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FILTER_LOAD_ERROR"
                               message:[NSString stringWithFormat:@"Error loading local games: %@", exception.reason]
                               details:exception.userInfo.description]);
  }
}

#pragma mark - Filter Type Helpers

- (NSArray<NSDictionary *> *)filterLocalFiltersByType:(NSArray<NSDictionary *> *)filters filterType:(NSString *)filterType {
  if (!filters || filters.count == 0) return @[];

  NSMutableArray *filteredResults = [NSMutableArray array];

  for (NSDictionary *filterInfo in filters) {
    NSString *type = filterInfo[@"filterType"] ?: @"effect";
    if ([type isEqualToString:filterType]) {
      [filteredResults addObject:filterInfo];
    }
  }

  return [filteredResults copy];
}

- (NSString *)normalizeLocalFilterTypeForFlutter:(id)rawType {
  if (![rawType isKindOfClass:[NSString class]]) {
    return @"effect";
  }

  NSString *type = [(NSString *)rawType lowercaseString];
  type = [type stringByReplacingOccurrencesOfString:@"-" withString:@"_"];

  if ([type isEqualToString:@"filter"]) {
    return @"filter";
  }
  if ([type isEqualToString:@"background"] || [type isEqualToString:@"bg"]) {
    return @"background";
  }
  if ([type isEqualToString:@"beautyeffect"] ||
      [type isEqualToString:@"beauty_effect"] ||
      [type isEqualToString:@"beauty_effects"] ||
      [type isEqualToString:@"beauty"]) {
    return @"beauty_effect";
  }
  if ([type isEqualToString:@"game"] || [type isEqualToString:@"games"]) {
    return @"game";
  }
  return @"effect";
}

- (void)handleValidateLocalFilters:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before validating local filters"
                               details:@"Please call initWithLicense() first"]);
    return;
  }

  @try {
    NSMutableArray *validationResults = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *basePath = [self getNosmaiFiltersBasePath];

    if (!basePath) {
      // No base path found - return empty results with warning
      result(@[]);
      return;
    }

    NSError *error = nil;
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:basePath error:&error];

    if (error || !contents) {
      result(@[]);
      return;
    }

    for (NSString *folderName in contents) {
      // Skip hidden files
      if ([folderName hasPrefix:@"."]) continue;

      NSString *folderPath = [basePath stringByAppendingPathComponent:folderName];

      BOOL isDirectory = NO;
      if (![fileManager fileExistsAtPath:folderPath isDirectory:&isDirectory] || !isDirectory) {
        continue;
      }

      NSMutableDictionary *validationResult = [NSMutableDictionary dictionary];
      validationResult[@"folderName"] = folderName;
      NSMutableArray *errors = [NSMutableArray array];
      NSMutableArray *warnings = [NSMutableArray array];

      // Check for .nosmai file
      NSString *nosmaiPath = [self findNosmaiFileInFolder:folderPath];
      if (nosmaiPath) {
        validationResult[@"nosmaiPath"] = nosmaiPath;
      } else {
        [errors addObject:@"Missing .nosmai file - filter cannot be loaded"];
      }

      // Check for manifest file
      NSString *manifestPath = [self findManifestFileInFolder:folderPath filterName:folderName];
      if (manifestPath) {
        validationResult[@"manifestPath"] = manifestPath;

        // Validate manifest content
        NSData *jsonData = [NSData dataWithContentsOfFile:manifestPath];
        if (jsonData) {
          NSError *jsonError = nil;
          NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
          if (jsonError) {
            [errors addObject:[NSString stringWithFormat:@"Invalid manifest JSON: %@", jsonError.localizedDescription]];
          } else {
            // Check for recommended fields
            if (!manifest[@"displayName"]) {
              [warnings addObject:@"Missing 'displayName' in manifest - folder name will be used"];
            }
            if (!manifest[@"id"]) {
              [warnings addObject:@"Missing 'id' in manifest - folder name will be used"];
            }
          }
        } else {
          [errors addObject:@"Could not read manifest file"];
        }
      } else {
        [warnings addObject:@"Missing manifest.json - default metadata will be used"];
      }

      // Check for preview image
      NSString *previewPath = [self findPreviewFileInFolder:folderPath filterName:folderName];
      if (previewPath) {
        validationResult[@"previewPath"] = previewPath;
      } else {
        [warnings addObject:@"No preview image found - SDK will attempt to extract from filter"];
      }

      validationResult[@"errors"] = errors;
      validationResult[@"warnings"] = warnings;
      validationResult[@"isValid"] = @(errors.count == 0);

      [validationResults addObject:validationResult];
    }

    result(validationResults);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"VALIDATION_ERROR"
                               message:[NSString stringWithFormat:@"Error validating local filters: %@", exception.reason]
                               details:exception.userInfo.description]);
  }
}

- (NSArray<NSDictionary *> *)getFlutterLocalFilters {
  NSTimeInterval cacheValidDuration = 5 * 60;
  NSDate *now = [NSDate date];

  NSArray *cachedFilters = [self getCachedLocalFilters];
  NSDate *lastCacheTime = [self getLastFilterCacheTime];

  if (cachedFilters && cachedFilters.count > 0 && lastCacheTime &&
      [now timeIntervalSinceDate:lastCacheTime] < cacheValidDuration) {
    return cachedFilters;
  }

  NSMutableArray *localFilters = [NSMutableArray array];

  NSArray *discoveredFilterNames = [self discoverNosmaiFiltersInAssets];


  NSString *basePath = [self getNosmaiFiltersBasePath];

  for (NSString *filterName in discoveredFilterNames) {
    NSString *cacheKey = [NSString stringWithFormat:@"local_filter_%@", filterName];
    NSDictionary *cachedFilterInfo = [self.filterCache objectForKey:cacheKey];

    if (cachedFilterInfo) {
      [localFilters addObject:cachedFilterInfo];
      continue;
    }

    NSString *folderPath = [basePath stringByAppendingPathComponent:filterName];

    // FLEXIBLE: Use helper methods to find files with flexible naming
    NSString *nosmaiPath = [self findNosmaiFileInFolder:folderPath];
    NSString *manifestPath = [self findManifestFileInFolder:folderPath filterName:filterName];
    NSString *previewPath = [self findPreviewFileInFolder:folderPath filterName:filterName];

    // Fallback to Flutter asset lookup if direct path not found
    if (!nosmaiPath) {
      NSString *nosmaiAssetKey = [FlutterDartProject lookupKeyForAsset:[NSString stringWithFormat:@"assets/nosmai_filters/%@/%@.nosmai", filterName, filterName]];
      nosmaiPath = [[NSBundle mainBundle] pathForResource:nosmaiAssetKey ofType:nil];
    }

    if (!nosmaiPath || ![[NSFileManager defaultManager] fileExistsAtPath:nosmaiPath]) {
      NOSMAI_PLUGIN_LOG(@"Warning: No .nosmai file found for filter '%@' in folder or assets", filterName);
      continue;
    }

    NSMutableDictionary *filterInfo = [NSMutableDictionary dictionary];

    if (manifestPath && [[NSFileManager defaultManager] fileExistsAtPath:manifestPath]) {
      NSError *jsonError = nil;
      NSData *jsonData = [NSData dataWithContentsOfFile:manifestPath];
      NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];

      if (!jsonError && manifest) {
        filterInfo[@"id"] = manifest[@"id"] ?: filterName;
        filterInfo[@"name"] = manifest[@"id"] ?: filterName;
        filterInfo[@"displayName"] = manifest[@"displayName"] ?: [self createDisplayNameFromFilterName:filterName];
        filterInfo[@"description"] = manifest[@"description"] ?: @"";
        filterInfo[@"filterType"] = manifest[@"filterType"] ?: @"effect";
        filterInfo[@"version"] = manifest[@"version"] ?: @"1.0.0";
        filterInfo[@"author"] = manifest[@"author"] ?: @"";
        filterInfo[@"tags"] = manifest[@"tags"] ?: @[];
        filterInfo[@"minSDKVersion"] = manifest[@"minSDKVersion"] ?: @"1.0.0";
        filterInfo[@"created"] = manifest[@"created"] ?: @"";
      } else {
        NOSMAI_PLUGIN_LOG(@"Warning: Failed to parse manifest.json for filter '%@': %@", filterName, jsonError.localizedDescription);
        filterInfo[@"id"] = filterName;
        filterInfo[@"name"] = filterName;
        filterInfo[@"displayName"] = [self createDisplayNameFromFilterName:filterName];
        filterInfo[@"description"] = @"";
        filterInfo[@"filterType"] = @"effect";
        filterInfo[@"version"] = @"1.0.0";
        filterInfo[@"author"] = @"";
        filterInfo[@"tags"] = @[];
        filterInfo[@"minSDKVersion"] = @"1.0.0";
        filterInfo[@"created"] = @"";
      }
    } else {
      NOSMAI_PLUGIN_LOG(@"Warning: Missing manifest.json for filter '%@', using defaults", filterName);
      filterInfo[@"id"] = filterName;
      filterInfo[@"name"] = filterName;
      filterInfo[@"displayName"] = [self createDisplayNameFromFilterName:filterName];
      filterInfo[@"description"] = @"";
      filterInfo[@"filterType"] = @"effect";
      filterInfo[@"version"] = @"1.0.0";
      filterInfo[@"author"] = @"";
      filterInfo[@"tags"] = @[];
      filterInfo[@"minSDKVersion"] = @"1.0.0";
      filterInfo[@"created"] = @"";
    }

    filterInfo[@"path"] = nosmaiPath;
    filterInfo[@"effectPath"] = nosmaiPath;

    NSError *error = nil;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:nosmaiPath error:&error];
    if (!error && fileAttributes) {
      filterInfo[@"fileSize"] = fileAttributes[NSFileSize];
    } else {
      filterInfo[@"fileSize"] = @0;
    }

    filterInfo[@"type"] = @"local";
    filterInfo[@"isDownloaded"] = @YES;

    BOOL previewLoaded = NO;

    if (previewPath && [[NSFileManager defaultManager] fileExistsAtPath:previewPath]) {
      UIImage *previewImage = [UIImage imageWithContentsOfFile:previewPath];
      if (previewImage) {
        NSData *imageData = UIImageJPEGRepresentation(previewImage, 0.7);
        if (imageData) {
          NSString *base64String = [imageData base64EncodedStringWithOptions:0];
          filterInfo[@"previewImageBase64"] = base64String;
          filterInfo[@"hasPreview"] = @YES;
          previewLoaded = YES;

          [self.filterCache setObject:[filterInfo copy] forKey:cacheKey cost:imageData.length];
        }
      }
    }

    if (!previewLoaded) {
      UIImage *previewImage = [[NosmaiSDK sharedInstance] loadPreviewImageForFilter:nosmaiPath];
      if (previewImage) {
        NSData *imageData = UIImageJPEGRepresentation(previewImage, 0.7);
        if (imageData) {
          NSString *base64String = [imageData base64EncodedStringWithOptions:0];
          filterInfo[@"previewImageBase64"] = base64String;
          filterInfo[@"hasPreview"] = @YES;

          [self.filterCache setObject:[filterInfo copy] forKey:cacheKey cost:imageData.length];
        }
      } else {
        NOSMAI_PLUGIN_LOG(@"Warning: No preview image available for filter '%@'", filterName);
        filterInfo[@"hasPreview"] = @NO;
        [self.filterCache setObject:[filterInfo copy] forKey:cacheKey cost:1024];
      }
    }

    [localFilters addObject:[filterInfo copy]];
  }

  NSArray *finalFilters = [localFilters copy];
  if (finalFilters.count > 0) {
    [self setCachedLocalFilters:finalFilters withCacheTime:now];
  }

  return finalFilters;
}

- (NSDictionary *)mapFrameworkKeysToPluginKeys:(NSDictionary *)frameworkFilter {
  NSMutableDictionary *pluginFilter = [NSMutableDictionary dictionary];

  NSString *backendId = [frameworkFilter[@"id"] isKindOfClass:[NSString class]]
      ? frameworkFilter[@"id"]
      : nil;
  NSString *filterId = [frameworkFilter[@"filterId"] isKindOfClass:[NSString class]]
      ? frameworkFilter[@"filterId"]
      : nil;
  // The public id must be accepted by download/remove APIs. Preserve the
  // catalog UUID separately for clients that need backend record identity.
  pluginFilter[@"id"] = filterId ?: backendId ?: frameworkFilter[@"name"] ?: @"";
  if (filterId.length > 0) pluginFilter[@"filterId"] = filterId;
  if (backendId.length > 0) pluginFilter[@"backendId"] = backendId;
  pluginFilter[@"name"] = frameworkFilter[@"name"] ?: @"";
  pluginFilter[@"description"] = frameworkFilter[@"description"] ?: @"";
  pluginFilter[@"displayName"] = frameworkFilter[@"displayName"] ?: frameworkFilter[@"name"] ?: @"";

  NSString *path = frameworkFilter[@"path"] ?: frameworkFilter[@"localPath"] ?: @"";
  if (path.length > 0) {
    pluginFilter[@"path"] = path;
  } else {
    pluginFilter[@"path"] = @"";
  }

  pluginFilter[@"fileSize"] = frameworkFilter[@"fileSize"] ?: @0;

  pluginFilter[@"type"] = frameworkFilter[@"type"] ?: @"local";

  NSString *frameworkCategory = frameworkFilter[@"filterCategory"];
  if (frameworkCategory) {
    if ([frameworkCategory isEqualToString:@"beauty-effects"]) {
      pluginFilter[@"filterCategory"] = @"beauty";
    } else if ([frameworkCategory isEqualToString:@"special-effects"]) {
      pluginFilter[@"filterCategory"] = @"effect";
    } else if ([frameworkCategory isEqualToString:@"cloud-filters"] ||
               [frameworkCategory isEqualToString:@"fx-and-filters"]) {
      pluginFilter[@"filterCategory"] = @"filter";
    } else {
      pluginFilter[@"filterCategory"] = @"unknown";
    }
  } else {
    pluginFilter[@"filterCategory"] = @"unknown";
  }

  NSString *filterType = frameworkFilter[@"filterType"] ?: @"effect";

  if ([frameworkFilter[@"type"] isEqualToString:@"cloud"]) {
    NSString *category = frameworkFilter[@"filterCategory"];

    if ([category hasPrefix:@"fx-and-filters"]) {
      filterType = @"filter";
    } else if ([category hasPrefix:@"special-effects"]) {
      filterType = @"effect";
    } else {
    }
  } else {

  }

  pluginFilter[@"filterType"] = filterType;

  pluginFilter[@"isFree"] = frameworkFilter[@"isFree"] ?: @YES;
  pluginFilter[@"isDownloaded"] = frameworkFilter[@"isDownloaded"] ?: @YES;
  pluginFilter[@"previewUrl"] = frameworkFilter[@"previewUrl"] ?: frameworkFilter[@"thumbnailUrl"];
  pluginFilter[@"category"] = frameworkFilter[@"category"];
  pluginFilter[@"downloadCount"] = frameworkFilter[@"downloadCount"] ?: @0;
  pluginFilter[@"price"] = frameworkFilter[@"price"] ?: @0;

  if (frameworkFilter[@"previewImageBase64"]) {
    pluginFilter[@"previewImageBase64"] = frameworkFilter[@"previewImageBase64"];
  }

  // Local filter manifest fields
  if (frameworkFilter[@"version"]) {
    pluginFilter[@"version"] = frameworkFilter[@"version"];
  }
  if (frameworkFilter[@"author"]) {
    pluginFilter[@"author"] = frameworkFilter[@"author"];
  }
  if (frameworkFilter[@"tags"]) {
    pluginFilter[@"tags"] = frameworkFilter[@"tags"];
  }
  if (frameworkFilter[@"minSDKVersion"]) {
    pluginFilter[@"minSDKVersion"] = frameworkFilter[@"minSDKVersion"];
  }
  if (frameworkFilter[@"created"]) {
    pluginFilter[@"created"] = frameworkFilter[@"created"];
  }

  return [pluginFilter copy];
}

- (NSArray<NSDictionary *> *)sanitizeFiltersForFlutter:(NSArray<NSDictionary *> *)filters {
  NSMutableArray *sanitizedFilters = [NSMutableArray array];

  for (NSDictionary *filter in filters) {
    NSDictionary *mappedFilter = [self mapFrameworkKeysToPluginKeys:filter];


    NSMutableDictionary *sanitizedFilter = [NSMutableDictionary dictionary];

    for (NSString *key in mappedFilter.allKeys) {
      id value = mappedFilter[key];

      if ([value isKindOfClass:[NSNull class]]) {
      } else if (value == nil) {
      } else if ([value isKindOfClass:[NSString class]]) {
        NSString *stringValue = (NSString *)value;
        if ([key isEqualToString:@"path"] && stringValue.length > 0) {
        }
        sanitizedFilter[key] = value;
      } else if ([value isKindOfClass:[NSNumber class]] ||
                 [value isKindOfClass:[NSArray class]] ||
                 [value isKindOfClass:[NSDictionary class]] ||
                 [value isKindOfClass:[NSData class]]) {
        sanitizedFilter[key] = value;
      } else if ([value isKindOfClass:[UIImage class]]) {
      } else {
      }
    }

    [sanitizedFilters addObject:[sanitizedFilter copy]];
  }

  return [sanitizedFilters copy];
}



- (void)handleStartRecording:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before starting recording"
                               details:nil]);
    return;
  }

  if (self.isRecording) {
    result([FlutterError errorWithCode:@"ALREADY_RECORDING"
                               message:@"Recording is already in progress"
                               details:nil]);
    return;
  }

  [[NosmaiCore shared] startRecordingWithCompletion:^(BOOL success, NSError *error) {
    if (success) {
      self.isRecording = YES;

      self.recordingProgressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                                      target:self
                                                                    selector:@selector(sendRecordingProgress)
                                                                    userInfo:nil
                                                                     repeats:YES];

      result(@YES);
    } else {
      result([FlutterError errorWithCode:@"RECORDING_ERROR"
                                 message:error ? error.localizedDescription : @"Failed to start recording"
                                 details:nil]);
    }
  }];
}

- (void)handleStopRecording:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before stopping recording"
                               details:nil]);
    return;
  }

  if (!self.isRecording) {
    result([FlutterError errorWithCode:@"NOT_RECORDING"
                               message:@"No recording in progress"
                               details:nil]);
    return;
  }

  [[NosmaiCore shared] stopRecordingWithCompletion:^(NSURL *videoURL, NSError *error) {
    self.isRecording = NO;

    if (self.recordingProgressTimer) {
      [self.recordingProgressTimer invalidate];
      self.recordingProgressTimer = nil;
    }

    if (videoURL && !error) {
      NSTimeInterval duration = [[NosmaiCore shared] currentRecordingDuration];

      NSError *fileError = nil;
      NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:videoURL.path error:&fileError];
      NSNumber *fileSize = fileError ? @0 : fileAttributes[NSFileSize];

      result(@{
        @"success": @YES,
        @"videoPath": videoURL.path,
        @"duration": @(duration),
        @"fileSize": fileSize
      });
    } else {
      result([FlutterError errorWithCode:@"RECORDING_ERROR"
                                 message:error ? error.localizedDescription : @"Failed to stop recording"
                                 details:nil]);
    }
  }];
}

- (void)handleIsRecording:(FlutterMethodCall*)call result:(FlutterResult)result {
  result(@(self.isRecording));
}

- (void)handleGetCurrentRecordingDuration:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  NSTimeInterval duration = [[NosmaiCore shared] currentRecordingDuration];
  result(@(duration));
}


- (void)handleCapturePhoto:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized"
                               details:nil]);
    return;
  }

  [[NosmaiCore shared] capturePhoto:^(UIImage *image, NSError *error) {
    if (image) {
      NSData *imageData = UIImageJPEGRepresentation(image, 0.8);

      NSMutableDictionary *resultDict = [NSMutableDictionary dictionary];
      resultDict[@"success"] = @YES;
      resultDict[@"width"] = @(image.size.width);
      resultDict[@"height"] = @(image.size.height);

      if (imageData) {
        FlutterStandardTypedData *typedData = [FlutterStandardTypedData typedDataWithBytes:imageData];
        resultDict[@"imageData"] = typedData;

        @try {
          NSString *tempDir = NSTemporaryDirectory();
          NSString *fileName = [NSString stringWithFormat:@"nosmai_photo_%ld.jpg",
                                (long)[[NSDate date] timeIntervalSince1970] * 1000];
          NSString *filePath = [tempDir stringByAppendingPathComponent:fileName];

          if ([imageData writeToFile:filePath atomically:YES]) {
            resultDict[@"imagePath"] = filePath;
          } else {
            resultDict[@"imagePath"] = [NSNull null];
          }
        } @catch (NSException *exception) {
          resultDict[@"imagePath"] = [NSNull null];
        }
      } else {
        resultDict[@"imagePath"] = [NSNull null];
      }

      result(resultDict);
    } else {
      NSString *errorMessage = error ? error.localizedDescription : @"Unknown error occurred while capturing photo";
      result(@{
        @"success": @NO,
        @"error": errorMessage
      });
    }
  }];
}

- (void)handleSaveImageToGallery:(FlutterMethodCall*)call result:(FlutterResult)result {
  FlutterStandardTypedData *imageData = call.arguments[@"imageData"];
  NSString *imageName = call.arguments[@"name"];

  if (!imageData || !imageData.data) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Image data is required"
                               details:nil]);
    return;
  }

  UIImage *image = [UIImage imageWithData:imageData.data];
  if (!image) {
    result([FlutterError errorWithCode:@"INVALID_IMAGE"
                               message:@"Could not create image from data"
                               details:nil]);
    return;
  }

  PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
  if (status == PHAuthorizationStatusDenied || status == PHAuthorizationStatusRestricted) {
    result([FlutterError errorWithCode:@"PERMISSION_DENIED"
                               message:@"Photo library access denied"
                               details:nil]);
    return;
  }

  if (status == PHAuthorizationStatusNotDetermined) {
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus authStatus) {
      if (authStatus == PHAuthorizationStatusAuthorized) {
        [self saveImageToPhotosApp:image withName:imageName result:result];
      } else {
        result([FlutterError errorWithCode:@"PERMISSION_DENIED"
                                   message:@"Photo library access denied"
                                   details:nil]);
      }
    }];
    return;
  }

  [self saveImageToPhotosApp:image withName:imageName result:result];
}

- (void)saveImageToPhotosApp:(UIImage *)image withName:(NSString *)name result:(FlutterResult)result {
  [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
    PHAssetChangeRequest *request = [PHAssetChangeRequest creationRequestForAssetFromImage:image];
    if (name) {
      request.creationDate = [NSDate date];
    }
  } completionHandler:^(BOOL success, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (success) {
        result(@{
          @"isSuccess": @YES,
          @"filePath": @"Photos App"
        });
      } else {
        result([FlutterError errorWithCode:@"SAVE_FAILED"
                                   message:error ? error.localizedDescription : @"Failed to save image"
                                   details:nil]);
      }
    });
  }];
}

- (void)handleSaveVideoToGallery:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString *videoPath = call.arguments[@"videoPath"];
  NSString *videoName = call.arguments[@"name"];

  if (!videoPath) {
    result([FlutterError errorWithCode:@"INVALID_ARGUMENTS"
                               message:@"Video path is required"
                               details:nil]);
    return;
  }

  if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
    result([FlutterError errorWithCode:@"FILE_NOT_FOUND"
                               message:@"Video file not found"
                               details:nil]);
    return;
  }

  PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
  if (status == PHAuthorizationStatusDenied || status == PHAuthorizationStatusRestricted) {
    result([FlutterError errorWithCode:@"PERMISSION_DENIED"
                               message:@"Photo library access denied"
                               details:nil]);
    return;
  }

  if (status == PHAuthorizationStatusNotDetermined) {
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus authStatus) {
      if (authStatus == PHAuthorizationStatusAuthorized) {
        [self saveVideoToPhotosApp:videoPath withName:videoName result:result];
      } else {
        result([FlutterError errorWithCode:@"PERMISSION_DENIED"
                                   message:@"Photo library access denied"
                                   details:nil]);
      }
    }];
    return;
  }

  [self saveVideoToPhotosApp:videoPath withName:videoName result:result];
}

- (void)saveVideoToPhotosApp:(NSString *)videoPath withName:(NSString *)name result:(FlutterResult)result {
  NSURL *videoURL = [NSURL fileURLWithPath:videoPath];

  [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
    PHAssetChangeRequest *request = [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:videoURL];
    if (name) {
      request.creationDate = [NSDate date];
    }
  } completionHandler:^(BOOL success, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (success) {
        result(@{
          @"isSuccess": @YES,
          @"filePath": @"Photos App"
        });
      } else {
        result([FlutterError errorWithCode:@"SAVE_FAILED"
                                   message:error ? error.localizedDescription : @"Failed to save video"
                                   details:nil]);
      }
    });
  }];
}

#pragma mark - Delegate Methods

- (void)nosmaiDidChangeState:(NosmaiState)newState {
  [self.channel invokeMethod:@"onStateChanged" arguments:@{@"state": @(newState)}];
}

- (void)nosmaiDidFailWithError:(NSError *)error {
  [self.channel invokeMethod:@"onError" arguments:@{
    @"code": @(error.code),
    @"message": error.localizedDescription
  }];
}

- (void)nosmaiDidUpdateFilters:(NSDictionary<NSString*, NSArray<NSDictionary*>*>*)organizedFilters {


  NSMutableArray *allFilters = [NSMutableArray array];

  for (NSString *filterType in organizedFilters.allKeys) {
    NSArray<NSDictionary*> *filtersOfType = organizedFilters[filterType];
    for (NSDictionary *filter in filtersOfType) {
      NSMutableDictionary *enhancedFilter = [filter mutableCopy];
      [allFilters addObject:enhancedFilter];
    }
  }

  NSArray *sanitizedFilters = [self sanitizeFiltersForFlutter:allFilters];
  [self.channel invokeMethod:@"onFiltersUpdated" arguments:sanitizedFilters];
}

- (void)nosmaiCameraDidStartCapture {
  [self.channel invokeMethod:@"onCameraReady" arguments:nil];
}

- (void)nosmaiCameraDidStopCapture {
  [self.channel invokeMethod:@"onCameraProcessingStopped" arguments:nil];
}

- (void)nosmaiCameraDidSwitchToPosition:(NosmaiCameraPosition)position {
}

- (void)nosmaiCameraDidFailWithError:(NSError *)error {
  [self.channel invokeMethod:@"onError" arguments:@{
    @"code": @"CAMERA_ERROR",
    @"message": error.localizedDescription
  }];
}

- (void)nosmaiCameraDidAttachToView:(UIView *)view {
  dispatch_semaphore_wait(self.cameraStateSemaphore, DISPATCH_TIME_FOREVER);
  self.isCameraAttached = YES;
  dispatch_semaphore_signal(self.cameraStateSemaphore);

  [self.channel invokeMethod:@"onCameraAttached" arguments:nil];
}

- (void)nosmaiCameraDidDetachFromView {
  dispatch_semaphore_wait(self.cameraStateSemaphore, DISPATCH_TIME_FOREVER);
  self.isCameraAttached = NO;
  dispatch_semaphore_signal(self.cameraStateSemaphore);

  [self.channel invokeMethod:@"onCameraDetached" arguments:nil];
}

- (void)nosmaiEffectsDidLoadEffect:(NSString *)effectPath {
}

- (void)nosmaiEffectsDidFailToLoadEffect:(NSString *)effectPath error:(NSError *)error {
  [self.channel invokeMethod:@"onError" arguments:@{
    @"code": @"EFFECT_ERROR",
    @"message": error.localizedDescription
  }];
}

- (void)nosmaiEffectsDidRemoveAllEffects {
}

- (void)nosmaiDidChangeLicenseStatus:(BOOL)isValid status:(NSString*)status {
  @try {
    NSString *statusString = nil;

    if (isValid && [status isEqualToString:@"VALID"]) {
      statusString = @"valid";
    } else if ([status caseInsensitiveCompare:@"EXPIRED"] == NSOrderedSame) {
      statusString = @"expired";
    } else if ([status caseInsensitiveCompare:@"INVALID"] == NSOrderedSame) {
      statusString = @"invalid";
    }

    if (statusString) {
      [self.channel invokeMethod:@"onLicenseStatusChanged" arguments:@{@"status": statusString}];
    }
  } @catch (NSException *exception) {}
}

#pragma mark - Helper Methods

#pragma mark - Flexible File Finding Helpers

/// Find the first .nosmai file in a folder (flexible naming)
- (NSString *)findNosmaiFileInFolder:(NSString *)folderPath {
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSError *error = nil;
  NSArray *contents = [fileManager contentsOfDirectoryAtPath:folderPath error:&error];

  if (error || !contents) return nil;

  for (NSString *fileName in contents) {
    if ([fileName.lowercaseString hasSuffix:@".nosmai"]) {
      return [folderPath stringByAppendingPathComponent:fileName];
    }
  }
  return nil;
}

/// Find manifest file with flexible naming: {name}_manifest.json, manifest.json
- (NSString *)findManifestFileInFolder:(NSString *)folderPath filterName:(NSString *)filterName {
  NSFileManager *fileManager = [NSFileManager defaultManager];

  // Try different naming patterns in order of preference
  NSArray *patterns = @[
    [NSString stringWithFormat:@"%@_manifest.json", filterName],
    @"manifest.json",
    [NSString stringWithFormat:@"%@-manifest.json", filterName],
    [NSString stringWithFormat:@"%@.manifest.json", filterName]
  ];

  for (NSString *pattern in patterns) {
    NSString *path = [folderPath stringByAppendingPathComponent:pattern];
    if ([fileManager fileExistsAtPath:path]) {
      return path;
    }
  }
  return nil;
}

/// Find preview image with flexible naming: {name}_preview.png, preview.png, thumbnail.png, icon.png
- (NSString *)findPreviewFileInFolder:(NSString *)folderPath filterName:(NSString *)filterName {
  NSFileManager *fileManager = [NSFileManager defaultManager];

  // Try different naming patterns and extensions
  NSArray *names = @[
    [NSString stringWithFormat:@"%@_preview", filterName],
    @"preview",
    @"thumbnail",
    @"icon",
    [NSString stringWithFormat:@"%@-preview", filterName],
    filterName
  ];

  NSArray *extensions = @[@"png", @"jpg", @"jpeg", @"webp"];

  for (NSString *name in names) {
    for (NSString *ext in extensions) {
      NSString *fileName = [NSString stringWithFormat:@"%@.%@", name, ext];
      NSString *path = [folderPath stringByAppendingPathComponent:fileName];
      if ([fileManager fileExistsAtPath:path]) {
        return path;
      }
    }
  }
  return nil;
}

/// Get the base path for nosmai_filters folder
- (NSString *)getNosmaiFiltersBasePath {
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *bundlePath = [[NSBundle mainBundle] bundlePath];

  NSArray *potentialPaths = @[
    @"flutter_assets/assets/nosmai_filters",
    @"Frameworks/App.framework/flutter_assets/assets/nosmai_filters",
    @"assets/nosmai_filters"
  ];

  for (NSString *relativePath in potentialPaths) {
    NSString *fullPath = [bundlePath stringByAppendingPathComponent:relativePath];
    if ([fileManager fileExistsAtPath:fullPath]) {
      return fullPath;
    }
  }
  return nil;
}

#pragma mark - Filter Discovery

- (NSArray<NSString *> *)discoverNosmaiFiltersInAssets {
  NSMutableArray *filterNames = [NSMutableArray array];
  NSFileManager *fileManager = [NSFileManager defaultManager];

  NSString *basePath = [self getNosmaiFiltersBasePath];

  if (basePath) {
    NSError *error = nil;
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:basePath error:&error];

    if (!error && contents) {
      for (NSString *folderName in contents) {
        // Skip hidden files/folders
        if ([folderName hasPrefix:@"."]) continue;

        NSString *folderPath = [basePath stringByAppendingPathComponent:folderName];

        BOOL isDirectory = NO;
        if ([fileManager fileExistsAtPath:folderPath isDirectory:&isDirectory] && isDirectory) {
          // FLEXIBLE: Find ANY .nosmai file in the folder (manifest NOT required)
          NSString *nosmaiFile = [self findNosmaiFileInFolder:folderPath];

          if (nosmaiFile) {
            if (![filterNames containsObject:folderName]) {
              [filterNames addObject:folderName];
            }
          }
        }
      }
    }
  }

  // Fallback: search in bundle resources if no filters found
  if (filterNames.count == 0) {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSArray *allPaths = [mainBundle pathsForResourcesOfType:@"nosmai" inDirectory:nil];

    for (NSString *path in allPaths) {
      if ([path containsString:@"nosmai_filters"]) {
        NSArray *components = [path componentsSeparatedByString:@"/"];
        for (NSInteger i = 0; i < components.count - 1; i++) {
          if ([components[i] isEqualToString:@"nosmai_filters"] && i + 1 < components.count) {
            NSString *filterFolderName = components[i + 1];

            if (filterFolderName.length > 0 && ![filterNames containsObject:filterFolderName]) {
              [filterNames addObject:filterFolderName];
            }
            break;
          }
        }
      }
    }
  }

  [filterNames sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

  return [filterNames copy];
}

- (NSString *)createDisplayNameFromFilterName:(NSString *)filterName {
  if (!filterName || filterName.length == 0) {
    return @"Unknown Filter";
  }

  NSString *displayName = filterName;

  displayName = [displayName stringByReplacingOccurrencesOfString:@"_" withString:@" "];
  displayName = [displayName stringByReplacingOccurrencesOfString:@"-" withString:@" "];

  NSArray *words = [displayName componentsSeparatedByString:@" "];
  NSMutableArray *capitalizedWords = [NSMutableArray array];

  for (NSString *word in words) {
    if (word.length > 0) {
      NSString *capitalizedWord = [word stringByReplacingCharactersInRange:NSMakeRange(0,1)
                                                                withString:[[word substringToIndex:1] uppercaseString]];
      [capitalizedWords addObject:capitalizedWord];
    }
  }

  return [capitalizedWords componentsJoinedByString:@" "];
}

#pragma mark - License Feature Methods

- (void)handleIsBeautyEffectEnabled:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before checking license features"
                               details:nil]);
    return;
  }

  @try {
    BOOL isEnabled = [[NosmaiCore shared].effects isBeautyEffectEnabled];
    result(@(isEnabled));
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"LICENSE_CHECK_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleIsCloudFilterEnabled:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before checking license features"
                               details:nil]);
    return;
  }

  @try {
    BOOL isEnabled = [[NosmaiCore shared].effects isCloudFilterEnabled];
    result(@(isEnabled));
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"LICENSE_CHECK_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}


- (void)sendRecordingProgress {
  if (self.isRecording) {
    NSTimeInterval duration = [[NosmaiCore shared] currentRecordingDuration];
    [self.channel invokeMethod:@"onRecordingProgress" arguments:@{
      @"duration": @(duration)
    }];
  }
}

- (BOOL)isNetworkAvailable {
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;

    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr*)&zeroAddress);

    if (reachability != NULL) {
        SCNetworkReachabilityFlags flags;
        if (SCNetworkReachabilityGetFlags(reachability, &flags)) {
            CFRelease(reachability);
            return (flags & kSCNetworkReachabilityFlagsReachable) && !(flags & kSCNetworkReachabilityFlagsConnectionRequired);
        }
        CFRelease(reachability);
    }

    return NO;
}

#pragma mark - NosmaiEffectsDelegate

- (void)nosmaiEffectsDidChangePipelineState:(NosmaiPipelineState *)state {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.channel invokeMethod:@"onActiveEffectsChanged"
                     arguments:[self pipelineStateMapForFlutter:state]];
  });
}

- (void)dealloc {
  [NosmaiCore shared].effects.gameEventHandler = nil;
  if ([NosmaiCore shared].effects.delegate == self) {
    [[NosmaiCore shared].effects setDelegate:nil];
  }
  if (self.recordingProgressTimer) {
    [self.recordingProgressTimer invalidate];
    self.recordingProgressTimer = nil;
  }

  if (self.cameraStateSemaphore) {
    self.cameraStateSemaphore = nil;
  }
  if (self.filterOperationSemaphore) {
    self.filterOperationSemaphore = nil;
  }
  if (self.cacheQueue) {
    self.cacheQueue = nil;
  }

  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Flash and Torch

- (void)handleHasFlash:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK not initialized"
                               details:nil]);
    return;
  }

  @try {
    BOOL hasFlash = [[NosmaiCore shared].camera hasFlash];
    result(@(hasFlash));
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FLASH_ERROR"
                               message:@"Failed to check flash availability"
                               details:exception.reason]);
  }
}

- (void)handleHasTorch:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK not initialized"
                               details:nil]);
    return;
  }

  @try {
    BOOL hasTorch = [[NosmaiCore shared].camera hasTorch];
    result(@(hasTorch));
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"TORCH_ERROR"
                               message:@"Failed to check torch availability"
                               details:exception.reason]);
  }
}

- (void)handleSetFlashMode:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK not initialized"
                               details:nil]);
    return;
  }

  NSString *flashModeString = call.arguments[@"flashMode"];
  if (!flashModeString) {
    result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                               message:@"Flash mode parameter is required"
                               details:nil]);
    return;
  }

  AVCaptureFlashMode flashMode;
  if ([flashModeString isEqualToString:@"on"]) {
    flashMode = AVCaptureFlashModeOn;
  } else if ([flashModeString isEqualToString:@"auto"]) {
    flashMode = AVCaptureFlashModeAuto;
  } else {
    flashMode = AVCaptureFlashModeOff;
  }

  @try {
    BOOL success = [[NosmaiCore shared].camera setFlashMode:flashMode];
    if (success) {
      // Update internal state tracking
      self.currentFlashMode = flashMode;
    }
    result(@(success));
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FLASH_ERROR"
                               message:@"Failed to set flash mode"
                               details:exception.reason]);
  }
}

- (void)handleSetTorchMode:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK not initialized"
                               details:nil]);
    return;
  }

  NSString *torchModeString = call.arguments[@"torchMode"];
  if (!torchModeString) {
    result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                               message:@"Torch mode parameter is required"
                               details:nil]);
    return;
  }

  AVCaptureTorchMode torchMode;
  if ([torchModeString isEqualToString:@"on"]) {
    torchMode = AVCaptureTorchModeOn;
  } else if ([torchModeString isEqualToString:@"auto"]) {
    torchMode = AVCaptureTorchModeAuto;
  } else {
    torchMode = AVCaptureTorchModeOff;
  }

  @try {
    BOOL success = [[NosmaiCore shared].camera setTorchMode:torchMode];
    if (success) {
      // Update internal state tracking
      self.currentTorchMode = torchMode;
    }
    result(@(success));
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"TORCH_ERROR"
                               message:@"Failed to set torch mode"
                               details:exception.reason]);
  }
}

- (void)handleGetFlashMode:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK not initialized"
                               details:nil]);
    return;
  }

  @try {
    // Check if device has flash capability
    BOOL hasFlash = [[NosmaiCore shared].camera hasFlash];
    if (!hasFlash) {
      result(@"off");
      return;
    }

    // Return internally tracked flash mode (NosmaiCamera doesn't provide getter)
    NSString *modeString;
    switch (self.currentFlashMode) {
      case AVCaptureFlashModeOn:
        modeString = @"on";
        break;
      case AVCaptureFlashModeAuto:
        modeString = @"auto";
        break;
      case AVCaptureFlashModeOff:
      default:
        modeString = @"off";
        break;
    }

    result(modeString);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"FLASH_ERROR"
                               message:@"Failed to get flash mode"
                               details:exception.reason]);
  }
}

- (void)handleGetTorchMode:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK not initialized"
                               details:nil]);
    return;
  }

  @try {
    // Check if device has torch capability
    BOOL hasTorch = [[NosmaiCore shared].camera hasTorch];
    if (!hasTorch) {
      result(@"off");
      return;
    }

    // Return internally tracked torch mode (NosmaiCamera doesn't provide getter)
    NSString *modeString;
    switch (self.currentTorchMode) {
      case AVCaptureTorchModeOn:
        modeString = @"on";
        break;
      case AVCaptureTorchModeAuto:
        modeString = @"auto";
        break;
      case AVCaptureTorchModeOff:
      default:
        modeString = @"off";
        break;
    }

    result(modeString);
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"TORCH_ERROR"
                               message:@"Failed to get torch mode"
                               details:exception.reason]);
  }
}

#pragma mark - Effect Parameter Control

- (void)handleGetEffectParameters:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK not initialized"
                               details:nil]);
    return;
  }

  @try {
    // Get parameters from active effect using NosmaiSDK
    NSArray<NSDictionary*>* parameters = [[NosmaiSDK sharedInstance] getEffectParameters];

    if (parameters == nil) {
      // No effect is currently active or no parameters available
      result(@[]);
      return;
    }

    // Convert NSArray to format expected by Flutter
    NSMutableArray* flutterParameters = [NSMutableArray arrayWithCapacity:parameters.count];

    for (NSDictionary* param in parameters) {
      NSMutableDictionary* flutterParam = [NSMutableDictionary dictionary];

      NSArray<NSString*>* supportedKeys = @[
        @"name", @"type", @"displayName", @"description", @"currentValue",
        @"defaultValue", @"hasRange", @"minValue", @"maxValue", @"options",
        @"passId"
      ];
      for (NSString* key in supportedKeys) {
        if (param[key] != nil) {
          flutterParam[key] = param[key];
        }
      }

      [flutterParameters addObject:flutterParam];
    }

    result(flutterParameters);

  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EFFECT_PARAMETER_ERROR"
                               message:@"Failed to get effect parameters"
                               details:exception.reason]);
  }
}

- (void)handleGetEffectParameterValue:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK not initialized"
                               details:nil]);
    return;
  }

  NSString* parameterName = call.arguments[@"parameterName"];
  if (parameterName == nil || [parameterName length] == 0) {
    result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                               message:@"Parameter name is required"
                               details:nil]);
    return;
  }

  @try {
    // Get parameter value from active effect using NosmaiSDK
    float value = [[NosmaiSDK sharedInstance] getEffectParameterValue:parameterName];

    if (!isfinite(value)) {
      result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                                 message:[NSString stringWithFormat:
                                     @"Parameter '%@' was not found", parameterName]
                                 details:nil]);
    } else {
      result(@(value));
    }

  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EFFECT_PARAMETER_ERROR"
                               message:@"Failed to get effect parameter value"
                               details:exception.reason]);
  }
}

- (void)handleSetEffectParameter:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK not initialized"
                               details:nil]);
    return;
  }

  NSString* parameterName = call.arguments[@"parameterName"];
  NSNumber* valueNumber = call.arguments[@"value"];

  if (parameterName == nil || [parameterName length] == 0) {
    result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                               message:@"Parameter name is required"
                               details:nil]);
    return;
  }

  if (valueNumber == nil) {
    result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                               message:@"Parameter value is required"
                               details:nil]);
    return;
  }

  @try {
    // Convert NSNumber to float
    float value = [valueNumber floatValue];

    // Set parameter value using NosmaiSDK
    BOOL success = [[NosmaiSDK sharedInstance] setEffectParameter:parameterName value:value];

    // Return success status
    result(@(success));

  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EFFECT_PARAMETER_ERROR"
                               message:@"Failed to set effect parameter"
                               details:exception.reason]);
  }
}

- (void)handleSetEffectParameterString:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK not initialized"
                               details:nil]);
    return;
  }

  NSString* parameterName = call.arguments[@"parameterName"];
  NSString* value = call.arguments[@"value"];

  if (parameterName == nil || [parameterName length] == 0) {
    result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                               message:@"Parameter name is required"
                               details:nil]);
    return;
  }

  if (value == nil) {
    result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                               message:@"Parameter value is required"
                               details:nil]);
    return;
  }

  @try {
    // Set string parameter value using NosmaiSDK
    BOOL success = [[NosmaiSDK sharedInstance] setEffectParameter:parameterName stringValue:value];

    // Return success status
    result(@(success));

  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"EFFECT_PARAMETER_ERROR"
                               message:@"Failed to set effect parameter string"
                               details:exception.reason]);
  }
}

#pragma mark - Test Filter Method

#pragma mark - External Pixel Buffer Processing

// Static instance for external processing
static NosmaiExternalProcessor *_externalProcessor = nil;
static dispatch_once_t onceToken;
static BOOL isOffscreenInitialized = NO;

// Shared CIContext for GPU-accelerated manual flip (created once, reused for performance)
static CIContext *_sharedFlipCIContext = nil;
static dispatch_once_t _flipCIContextOnceToken;

#pragma mark - Manual Mirror Transform Helper

+ (CIContext *)sharedFlipCIContext {
    dispatch_once(&_flipCIContextOnceToken, ^{
        _sharedFlipCIContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,  // Use GPU
            kCIContextPriorityRequestLow: @NO    // High priority
        }];
        NOSMAI_PLUGIN_LOG(@"✅ Created shared CIContext for manual flip (GPU-accelerated)");
    });
    return _sharedFlipCIContext;
}

+ (CVPixelBufferRef)flipPixelBufferHorizontally:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) {
        return NULL;
    }

    @autoreleasepool {
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        if (!ciImage) {
            NOSMAI_PLUGIN_LOG(@"⚠️ Failed to create CIImage from pixelBuffer");
            return NULL;
        }

        // Apply horizontal flip transform
        CGAffineTransform transform = CGAffineTransformMakeScale(-1.0, 1.0);
        transform = CGAffineTransformTranslate(transform, -ciImage.extent.size.width, 0);
        CIImage *flippedImage = [ciImage imageByApplyingTransform:transform];

        // Create new pixel buffer
        CVPixelBufferRef flippedBuffer = NULL;
        CVReturn status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            NULL,
            &flippedBuffer
        );

        if (status != kCVReturnSuccess || !flippedBuffer) {
            NOSMAI_PLUGIN_LOG(@"⚠️ Failed to create flipped CVPixelBuffer: %d", (int)status);
            return NULL;
        }

        // GPU render
        [[self sharedFlipCIContext] render:flippedImage toCVPixelBuffer:flippedBuffer];
        return flippedBuffer;  // Caller must release
    }
}

#pragma mark - New External Processing Implementation

+ (BOOL)processExternalPixelBuffer:(CVPixelBufferRef)pixelBuffer shouldFlip:(BOOL)shouldFlip {
    if (!pixelBuffer) {
        return NO;
    }

    NosmaiSDK *sdk = [NosmaiSDK sharedInstance];
    if (!sdk) {
        return NO;
    }

    // Initialize offscreen mode on first frame
    if (!isOffscreenInitialized) {
        BOOL offscreenSuccess = [sdk initializeOffscreenWithWidth:720 height:1280];
        if (!offscreenSuccess) {
            return NO;
        }
        [sdk setProcessingMode:NosmaiProcessingModeOffscreen];
        [sdk setLiveFrameOutputEnabled:YES];
        isOffscreenInitialized = YES;
        NOSMAI_PLUGIN_LOG(@"✅ Nosmai offscreen mode initialized");
    }

    // Lazy init external processor
    dispatch_once(&onceToken, ^{
        _externalProcessor = [[NosmaiExternalProcessor alloc] init];
    });

    @try {
        CVPixelBufferRef bufferToProcess = pixelBuffer;
        CVPixelBufferRef flippedBuffer = NULL;

        // STEP 1: Manual flip if needed (front camera un-mirror)
        if (shouldFlip) {
            flippedBuffer = [self flipPixelBufferHorizontally:pixelBuffer];
            if (flippedBuffer) {
                bufferToProcess = flippedBuffer;
            }
        }

        // STEP 2: Create CMSampleBuffer
        CMSampleBufferRef sampleBuffer = NULL;
        CMSampleTimingInfo timingInfo = {
            .duration = CMTimeMake(1, 30),
            .presentationTimeStamp = CMTimeMake(0, 1),
            .decodeTimeStamp = kCMTimeInvalid
        };

        CMVideoFormatDescriptionRef formatDescription = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, bufferToProcess, &formatDescription);

        OSStatus status = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault,
            bufferToProcess,
            true,
            NULL,
            NULL,
            formatDescription,
            &timingInfo,
            &sampleBuffer
        );

        if (formatDescription) {
            CFRelease(formatDescription);
        }

        if (status != noErr || !sampleBuffer) {
            if (flippedBuffer) CVPixelBufferRelease(flippedBuffer);
            return NO;
        }

        // STEP 3: Process with Nosmai (ALWAYS mirror:NO since we manually flipped)
        BOOL processSuccess = [sdk processSampleBuffer:sampleBuffer mirror:NO];
        CFRelease(sampleBuffer);

        if (!processSuccess) {
            if (flippedBuffer) CVPixelBufferRelease(flippedBuffer);
            return NO;
        }

        // STEP 4: Wait for callback
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC);
        long result = dispatch_semaphore_wait(_externalProcessor.frameSemaphore, timeout);

        if (result != 0) {
            if (flippedBuffer) CVPixelBufferRelease(flippedBuffer);
            return NO;
        }

        // STEP 5: Copy back to original buffer
        if (_externalProcessor.lastProcessedBuffer) {
            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            CVPixelBufferLockBaseAddress(_externalProcessor.lastProcessedBuffer, 0);

            void *srcBaseAddress = CVPixelBufferGetBaseAddress(_externalProcessor.lastProcessedBuffer);
            void *dstBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
            size_t srcBytesPerRow = CVPixelBufferGetBytesPerRow(_externalProcessor.lastProcessedBuffer);
            size_t dstBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
            size_t height = CVPixelBufferGetHeight(pixelBuffer);

            for (size_t row = 0; row < height; row++) {
                memcpy(dstBaseAddress + row * dstBytesPerRow,
                       srcBaseAddress + row * srcBytesPerRow,
                       MIN(srcBytesPerRow, dstBytesPerRow));
            }

            CVPixelBufferUnlockBaseAddress(_externalProcessor.lastProcessedBuffer, 0);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        }

        // Cleanup
        if (flippedBuffer) {
            CVPixelBufferRelease(flippedBuffer);
        }

        return YES;

    } @catch (NSException *exception) {
        return NO;
    }
}

#pragma mark - Backward Compatible Method

+ (BOOL)processExternalPixelBuffer:(CVPixelBufferRef)pixelBuffer mirror:(BOOL)mirror {
    // Redirect to new implementation
    return [self processExternalPixelBuffer:pixelBuffer shouldFlip:mirror];
}

#pragma mark - Reset External Frame Mode

+ (void)resetExternalFrameMode {
    NOSMAI_PLUGIN_LOG(@"🔄 Resetting external frame mode...");

    // Reset offscreen initialization flag
    isOffscreenInitialized = NO;

    // Reset dispatch_once token to allow re-initialization
    onceToken = 0;

    // Clean up external processor
    if (_externalProcessor) {
        if (_externalProcessor.lastProcessedBuffer) {
            CVPixelBufferRelease(_externalProcessor.lastProcessedBuffer);
            _externalProcessor.lastProcessedBuffer = NULL;
        }
        _externalProcessor = nil;
    }

    // Reset SDK processing mode back to live camera mode
    NosmaiSDK *sdk = [NosmaiSDK sharedInstance];
    if (sdk) {
        [sdk setProcessingMode:NosmaiProcessingModeLive];
        [sdk setLiveFrameOutputEnabled:NO];
        [sdk setCVPixelBufferCallback:nil];
        NOSMAI_PLUGIN_LOG(@"✅ SDK reset to live camera mode");
    }

    NOSMAI_PLUGIN_LOG(@"✅ External frame mode reset complete");
}

#pragma mark - Background Segmentation Methods

- (void)handleIsAdvancedFiltersEnabled:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before checking license features"
                               details:nil]);
    return;
  }

  @try {
    BOOL isEnabled = [[NosmaiCore shared].effects isAdvancedFiltersEnabled];
    result(@(isEnabled));
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"LICENSE_CHECK_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleSetBackgroundSegmentation:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before setting background segmentation"
                               details:nil]);
    return;
  }

  @try {
    NSDictionary *arguments = call.arguments;
    NSString *mode = arguments[@"mode"];

    if (!mode) {
      result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                                 message:@"Background segmentation mode is required"
                                 details:nil]);
      return;
    }

    NosmaiBackgroundSegmentationConfig *config = [[NosmaiBackgroundSegmentationConfig alloc] init];

    if ([mode isEqualToString:@"color"]) {
      config.mode = NosmaiBackgroundSegmentationModeColor;

      // Extract color components
      NSNumber *red = arguments[@"colorRed"];
      NSNumber *green = arguments[@"colorGreen"];
      NSNumber *blue = arguments[@"colorBlue"];
      NSNumber *alpha = arguments[@"colorAlpha"];

      if (red && green && blue) {
        CGFloat r = [red floatValue];
        CGFloat g = [green floatValue];
        CGFloat b = [blue floatValue];
        CGFloat a = alpha ? [alpha floatValue] : 1.0;

        config.replacementColor = [UIColor colorWithRed:r green:g blue:b alpha:a];
      } else {
        result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                                   message:@"Color values (colorRed, colorGreen, colorBlue) are required for color mode"
                                   details:nil]);
        return;
      }
    } else if ([mode isEqualToString:@"image"]) {
      config.mode = NosmaiBackgroundSegmentationModeImage;

      FlutterStandardTypedData *imageData = arguments[@"imageData"];
      if (imageData) {
        UIImage *image = [UIImage imageWithData:imageData.data];
        if (image) {
          config.replacementImage = image;
        } else {
          result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                                     message:@"Failed to create image from provided data"
                                     details:nil]);
          return;
        }
      } else {
        result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                                   message:@"Image data is required for image mode"
                                   details:nil]);
        return;
      }
    } else if ([mode isEqualToString:@"video"]) {
      config.mode = NosmaiBackgroundSegmentationModeVideo;

      NSString *videoPath = arguments[@"videoPath"];
      if (videoPath && videoPath.length > 0) {
        config.replacementVideoURL = [NSURL fileURLWithPath:videoPath];
      } else {
        result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                                   message:@"Video path is required for video mode"
                                   details:nil]);
        return;
      }
    } else {
      result([FlutterError errorWithCode:@"INVALID_PARAMETER"
                                 message:[NSString stringWithFormat:@"Unknown background segmentation mode: %@", mode]
                                 details:nil]);
      return;
    }

	    // Apply the configuration
	    [[NosmaiCore shared].effects setBackgroundSegmentation:config];
	    [self emitPipelineStateToFlutter];
	    result(@(YES));

  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"BACKGROUND_SEGMENTATION_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

- (void)handleClearBackgroundSegmentation:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (!self.isInitialized) {
    result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                               message:@"SDK must be initialized before clearing background segmentation"
                               details:nil]);
    return;
  }

	  @try {
	    [[NosmaiCore shared].effects clearBackgroundSegmentation];
	    [self emitPipelineStateToFlutter];
	    result(@(YES));
  } @catch (NSException *exception) {
    result([FlutterError errorWithCode:@"BACKGROUND_SEGMENTATION_CLEAR_ERROR"
                               message:exception.reason
                               details:exception.userInfo]);
  }
}

@end

#pragma mark - NosmaiExternalProcessor Implementation

@implementation NosmaiExternalProcessor

- (instancetype)init {
    self = [super init];
    if (self) {
        _isInitialized = YES;
        _lastProcessedBuffer = NULL;
        _frameSemaphore = dispatch_semaphore_create(0);

        // Set callback to receive processed frames
        NosmaiSDK *sdk = [NosmaiSDK sharedInstance];
        __weak typeof(self) weakSelf = self;
        [sdk setCVPixelBufferCallback:^(CVPixelBufferRef processedBuffer, double timestamp) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (processedBuffer) {
                CVPixelBufferRetain(processedBuffer);
                if (strongSelf.lastProcessedBuffer) {
                    CVPixelBufferRelease(strongSelf.lastProcessedBuffer);
                }
                strongSelf.lastProcessedBuffer = processedBuffer;
                dispatch_semaphore_signal(strongSelf.frameSemaphore);
            }
        }];
    }
    return self;
}

- (BOOL)processPixelBuffer:(CVPixelBufferRef)pixelBuffer mirror:(BOOL)mirror {
    if (!_isInitialized) {
        return NO;
    }

    @try {
        // Create CMSampleBuffer from CVPixelBuffer
        CMSampleBufferRef sampleBuffer = NULL;
        CMSampleTimingInfo timingInfo = {
            .duration = CMTimeMake(1, 30),
            .presentationTimeStamp = CMTimeMake(0, 1),
            .decodeTimeStamp = kCMTimeInvalid
        };

        CMVideoFormatDescriptionRef formatDescription = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);

        OSStatus status = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer,
            true,
            NULL,
            NULL,
            formatDescription,
            &timingInfo,
            &sampleBuffer
        );

        if (formatDescription) {
            CFRelease(formatDescription);
        }

        if (status != noErr || !sampleBuffer) {
            return NO;
        }

        // Process through NosmaiSDK
        NosmaiSDK *sdk = [NosmaiSDK sharedInstance];
        BOOL processSuccess = [sdk processSampleBuffer:sampleBuffer mirror:mirror];
        CFRelease(sampleBuffer);

        if (!processSuccess) {
            return NO;
        }

        // Wait for processed frame from callback (50ms timeout)
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC);
        long result = dispatch_semaphore_wait(self.frameSemaphore, timeout);

        if (result != 0) {
            return NO;
        }

        // Copy processed frame back to original buffer (no flip needed)
        if (self.lastProcessedBuffer) {
            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            CVPixelBufferLockBaseAddress(self.lastProcessedBuffer, 0);

            void *srcBaseAddress = CVPixelBufferGetBaseAddress(self.lastProcessedBuffer);
            void *dstBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
            size_t srcBytesPerRow = CVPixelBufferGetBytesPerRow(self.lastProcessedBuffer);
            size_t dstBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
            size_t height = CVPixelBufferGetHeight(pixelBuffer);

            for (size_t row = 0; row < height; row++) {
                memcpy(dstBaseAddress + row * dstBytesPerRow,
                       srcBaseAddress + row * srcBytesPerRow,
                       MIN(srcBytesPerRow, dstBytesPerRow));
            }

            CVPixelBufferUnlockBaseAddress(self.lastProcessedBuffer, 0);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

            return YES;
        }

        return NO;
    } @catch (NSException *exception) {
        return NO;
    }
}

- (void)dealloc {
    [[NosmaiSDK sharedInstance] setCVPixelBufferCallback:nil];
    if (_lastProcessedBuffer) {
        CVPixelBufferRelease(_lastProcessedBuffer);
        _lastProcessedBuffer = NULL;
    }
}

@end
