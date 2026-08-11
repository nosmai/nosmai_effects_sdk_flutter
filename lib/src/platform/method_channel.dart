import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../types/enums.dart';
import '../types/models.dart';
import '../types/errors.dart';
import 'platform_interface.dart';
import '../core/nosmai_api.dart';

/// Internal camera state notifier for communication between platform and widgets
class CameraStateNotifierImpl {
  static final CameraStateNotifierImpl _instance =
      CameraStateNotifierImpl._internal();
  static CameraStateNotifierImpl get instance => _instance;
  CameraStateNotifierImpl._internal();

  final List<Function()> _attachedCallbacks = [];
  final List<Function()> _detachedCallbacks = [];
  final List<Function()> _readyCallbacks = [];
  final List<Function()> _processingStoppedCallbacks = [];

  void addAttachedCallback(Function() callback) {
    _attachedCallbacks.add(callback);
  }

  void removeAttachedCallback(Function() callback) {
    _attachedCallbacks.remove(callback);
  }

  void addDetachedCallback(Function() callback) {
    _detachedCallbacks.add(callback);
  }

  void removeDetachedCallback(Function() callback) {
    _detachedCallbacks.remove(callback);
  }

  void addReadyCallback(Function() callback) {
    _readyCallbacks.add(callback);
  }

  void removeReadyCallback(Function() callback) {
    _readyCallbacks.remove(callback);
  }

  void addProcessingStoppedCallback(Function() callback) {
    _processingStoppedCallbacks.add(callback);
  }

  void removeProcessingStoppedCallback(Function() callback) {
    _processingStoppedCallbacks.remove(callback);
  }

  void notifyCameraAttached() {
    for (final callback in _attachedCallbacks) {
      try {
        callback();
      } catch (e) {
        // Error in camera attached callback - continue with other callbacks
      }
    }
  }

  void notifyCameraDetached() {
    for (final callback in _detachedCallbacks) {
      try {
        callback();
      } catch (e) {
        // Error in camera detached callback - continue with other callbacks
      }
    }
  }

  void notifyCameraReady() {
    for (final callback in _readyCallbacks) {
      try {
        callback();
      } catch (e) {
        // Error in camera ready callback - continue with other callbacks
      }
    }
  }

  void notifyCameraProcessingStopped() {
    for (final callback in _processingStoppedCallbacks) {
      try {
        callback();
      } catch (e) {
        // Error in camera processing stopped callback - continue with other callbacks
      }
    }
  }
}

/// Expose camera state notifier for use in other files
class CameraStateNotifier {
  static CameraStateNotifierImpl get instance =>
      CameraStateNotifierImpl.instance;
}

/// An implementation of [NosmaiFlutterPlatform] that uses method channels.
class MethodChannelNosmaiFlutter extends NosmaiFlutterPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('nosmai_camera_sdk');

  List<String>? _cachedAssetPaths;
  Future<List<String>>? _assetPathsLoad;

  /// Constructor that sets up method call handler for callbacks
  MethodChannelNosmaiFlutter() {
    methodChannel.setMethodCallHandler(_handleMethodCall);
  }

  Future<List<String>> _loadFlutterAssetPaths() {
    final cached = _cachedAssetPaths;
    if (cached != null) return Future.value(cached);

    final pending = _assetPathsLoad;
    if (pending != null) return pending;

    final load = AssetManifest.loadFromAssetBundle(rootBundle).then((manifest) {
      final paths = List<String>.unmodifiable(manifest.listAssets());
      _cachedAssetPaths = paths;
      return paths;
    }).catchError((Object error) {
      throw PlatformException(
        code: 'ASSET_MANIFEST_ERROR',
        message: 'Unable to read the Flutter asset manifest.',
      );
    }).whenComplete(() {
      _assetPathsLoad = null;
    });
    _assetPathsLoad = load;
    return load;
  }

  /// Handle method calls from native platform (callbacks)
  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onError':
        final Map<String, dynamic> args =
            Map<String, dynamic>.from(call.arguments);
        final err = NosmaiError.fromMap(args);
        NosmaiFlutter.dispatchNativeError(err);
        break;
      case 'onDownloadProgress':
        final Map<String, dynamic> args =
            Map<String, dynamic>.from(call.arguments);
        final progress = NosmaiDownloadProgress.fromMap(args);
        NosmaiFlutter.dispatchNativeDownloadProgress(progress);
        break;
      case 'onRecordingProgress':
        try {
          final Map<String, dynamic> args =
              Map<String, dynamic>.from(call.arguments);
          final duration = (args['duration'] as num?)?.toDouble();
          if (duration != null) {
            NosmaiFlutter.dispatchNativeRecordingProgress(duration);
          }
        } catch (_) {
          // ignore malformed callback
        }
        break;
      case 'onStateChanged':
        // Handle SDK state changes
        break;
      case 'onCameraAttached':
        // Camera successfully attached - notify camera preview widgets
        CameraStateNotifierImpl.instance.notifyCameraAttached();
        break;
      case 'onCameraDetached':
        // Camera detached - notify camera preview widgets
        CameraStateNotifierImpl.instance.notifyCameraDetached();
        break;
      case 'onCameraReady':
        // Camera is ready for processing
        CameraStateNotifierImpl.instance.notifyCameraReady();
        break;
      case 'onCameraProcessingStopped':
        // Camera processing stopped
        CameraStateNotifierImpl.instance.notifyCameraProcessingStopped();
        break;
      case 'onLicenseStatusChanged':
        try {
          final Map<String, dynamic> args =
              Map<String, dynamic>.from(call.arguments);
          final statusString = args['status'] as String?;
          if (statusString != null) {
            NosmaiLicenseStatus status;
            switch (statusString.toLowerCase()) {
              case 'valid':
                status = NosmaiLicenseStatus.valid;
                break;
              case 'expired':
                status = NosmaiLicenseStatus.expired;
                break;
              case 'invalid':
                status = NosmaiLicenseStatus.invalid;
                break;
              default:
                return;
            }
            NosmaiFlutter.dispatchNativeLicenseStatus(status);
          }
        } catch (_) {}
        break;
      case 'onActiveEffectsChanged':
      case 'onPipelineStateChanged':
        try {
          final Map<String, dynamic> args =
              Map<String, dynamic>.from(call.arguments);
          NosmaiFlutter.dispatchNativeActiveEffects(
            NosmaiActiveEffects.fromMap(args),
          );
        } catch (_) {
          // ignore malformed callback
        }
        break;
    }
  }

  @override
  Future<String?> getPlatformVersion() async {
    final version =
        await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  @override
  Future<bool> initWithLicense(String licenseKey) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('initWithLicense', {
        'licenseKey': licenseKey,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> configureCamera({
    required NosmaiCameraPosition position,
    String? sessionPreset,
  }) async {
    try {
      await methodChannel.invokeMethod('configureCamera', {
        'position': position.name,
        'sessionPreset': sessionPreset ?? 'AVCaptureSessionPresetHigh',
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> startProcessing() async {
    try {
      await methodChannel.invokeMethod('startProcessing');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> stopProcessing() async {
    try {
      await methodChannel.invokeMethod('stopProcessing');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<bool> switchCamera() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('switchCamera');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> removeAllFilters() async {
    try {
      await methodChannel.invokeMethod('removeAllFilters');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> clearAREffect() async {
    try {
      await methodChannel.invokeMethod('clearAREffect');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> clearFilter() async {
    try {
      await methodChannel.invokeMethod('clearFilter');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> clearAll() async {
    try {
      await methodChannel.invokeMethod('clearAll');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> setPreviewView() async {
    try {
      await methodChannel.invokeMethod('setPreviewView');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> cleanup() async {
    try {
      await methodChannel.invokeMethod('cleanup');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<bool> pauseCamera() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('pauseCamera');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> resumeCamera() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('resumeCamera');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  // New Advanced Features Implementation
  @override
  Future<bool> applyEffect(String effectPath) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('applyEffect', {
        'effectPath': effectPath,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> applyFilter(String filterPath) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('applyFilter', {
        'filterPath': filterPath,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<NosmaiActiveEffects> getActiveEffects() async {
    try {
      final result = await methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('getActiveEffects');
      if (result == null) return NosmaiActiveEffects.idle();
      return NosmaiActiveEffects.fromMap(Map<String, dynamic>.from(result));
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<NosmaiFilter?> getActiveFilterInfo() async {
    try {
      final result = await methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('getActiveFilterInfo');
      if (result == null) return null;
      return NosmaiFilter.fromMap(Map<String, dynamic>.from(result));
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<NosmaiFilter?> getActiveEffectInfo() async {
    try {
      final result = await methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('getActiveEffectInfo');
      if (result == null) return null;
      return NosmaiFilter.fromMap(Map<String, dynamic>.from(result));
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> removeEffect(NosmaiFilter filter) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('removeEffect', {
        'filter': filter.toMap(),
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> getCloudFiltersWithOptions({
    NosmaiCloudFilterType? filterType,
    NosmaiCloudFilterVersion version = NosmaiCloudFilterVersion.v2,
    int? page,
    int? limit,
    bool fetchAllPages = true,
  }) async {
    try {
      final Map<String, dynamic> arguments = {
        'fetchAllPages': fetchAllPages,
        'version': version.apiValue,
      };

      if (filterType != null) {
        arguments['filterType'] = filterType.apiValue;
      }
      if (page != null) {
        arguments['page'] = page;
      }
      if (limit != null) {
        arguments['limit'] = limit;
      }

      final result = await methodChannel.invokeMethod<Map<dynamic, dynamic>>(
          'getCloudFilters', arguments);

      if (result == null) {
        return {'filters': [], 'pagination': null};
      }

      return Map<String, dynamic>.from(result);
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<List<dynamic>> getCloudFilters() async {
    try {
      // Call with fetchAllPages=true for backward compatibility
      final result = await getCloudFiltersWithOptions(fetchAllPages: true);
      final filters = result['filters'];
      if (filters is List) {
        return filters;
      }
      return [];
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> downloadCloudFilter(String filterId) async {
    try {
      final result = await methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('downloadCloudFilter', {
        'filterId': filterId,
      });
      return Map<String, dynamic>.from(result ?? {});
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> removeCloudFilter(String filterId) async {
    try {
      final result =
          await methodChannel.invokeMethod<bool>('removeCloudFilter', {
        'filterId': filterId,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<List<dynamic>> getLocalFilters({bool forceRefresh = false}) async {
    try {
      final assetPaths = await _loadFlutterAssetPaths();
      final result = await methodChannel.invokeMethod<List<dynamic>>(
        'getLocalFilters',
        {
          'forceRefresh': forceRefresh,
          'assetPaths': assetPaths,
        },
      );
      return result ?? [];
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<Map<String, List<dynamic>>> getAllLocalFilters(
      {bool forceRefresh = false}) async {
    try {
      final assetPaths = await _loadFlutterAssetPaths();
      final result = await methodChannel.invokeMethod<Map<dynamic, dynamic>>(
        'getAllLocalFilters',
        {
          'forceRefresh': forceRefresh,
          'assetPaths': assetPaths,
        },
      );
      if (result == null) return {};
      return result.map(
        (key, value) => MapEntry(
          key.toString(),
          value is List ? List<dynamic>.from(value) : <dynamic>[],
        ),
      );
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<List<dynamic>> getDebugFilters({NosmaiLocalFilterType? type}) async {
    try {
      final assetPaths = await _loadFlutterAssetPaths();
      final result = await methodChannel.invokeMethod<List<dynamic>>(
        'getDebugFilters',
        {
          'filterType': type?.value,
          'assetPaths': assetPaths,
        },
      );
      return result ?? [];
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<List<dynamic>> getLocalEffects() async {
    try {
      final assetPaths = await _loadFlutterAssetPaths();
      final result = await methodChannel.invokeMethod<List<dynamic>>(
        'getLocalEffects',
        {'assetPaths': assetPaths},
      );
      return result ?? [];
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<List<dynamic>> getLocalBackgrounds() async {
    try {
      final assetPaths = await _loadFlutterAssetPaths();
      final result = await methodChannel.invokeMethod<List<dynamic>>(
        'getLocalBackgrounds',
        {'assetPaths': assetPaths},
      );
      return result ?? [];
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<List<dynamic>> getLocalBeautyEffects() async {
    try {
      final assetPaths = await _loadFlutterAssetPaths();
      final result = await methodChannel.invokeMethod<List<dynamic>>(
        'getLocalBeautyEffects',
        {'assetPaths': assetPaths},
      );
      return result ?? [];
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> clearLocalFiltersCache() async {
    try {
      final result =
          await methodChannel.invokeMethod<bool>('clearLocalFiltersCache');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<List<dynamic>> validateLocalFilters() async {
    try {
      final assetPaths = await _loadFlutterAssetPaths();
      final result = await methodChannel.invokeMethod<List<dynamic>>(
        'validateLocalFilters',
        {'assetPaths': assetPaths},
      );
      return result ?? [];
    } catch (_) {
      rethrow;
    }
  }

  // Recording Features Implementation
  @override
  Future<bool> startRecording() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('startRecording');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> stopRecording() async {
    try {
      final result = await methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('stopRecording');
      return Map<String, dynamic>.from(result ?? {});
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> isRecording() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('isRecording');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<double> getCurrentRecordingDuration() async {
    try {
      final result = await methodChannel
          .invokeMethod<double>('getCurrentRecordingDuration');
      return result ?? 0.0;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> capturePhoto() async {
    try {
      final result = await methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('capturePhoto');
      return Map<String, dynamic>.from(result ?? {});
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> saveImageToGallery(List<int> imageData,
      {String? name}) async {
    try {
      final result = await methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('saveImageToGallery', {
        'imageData': Uint8List.fromList(imageData),
        'name': name ?? 'nosmai_photo_${DateTime.now().millisecondsSinceEpoch}',
      });
      return Map<String, dynamic>.from(result ?? {});
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> saveVideoToGallery(String videoPath,
      {String? name}) async {
    try {
      final result = await methodChannel
          .invokeMethod<Map<dynamic, dynamic>>('saveVideoToGallery', {
        'videoPath': videoPath,
        'name': name ?? 'nosmai_video_${DateTime.now().millisecondsSinceEpoch}',
      });
      return Map<String, dynamic>.from(result ?? {});
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> clearFilterCache() async {
    try {
      await methodChannel.invokeMethod('clearFilterCache');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> detachCameraView() async {
    try {
      await methodChannel.invokeMethod('detachCameraView');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> reinitializePreview() async {
    try {
      await methodChannel.invokeMethod('reinitializePreview');
    } catch (e) {
      rethrow;
    }
  }

  // Built-in Filter Methods Implementation
  @override
  Future<void> applyBrightnessFilter(double brightness) async {
    try {
      await methodChannel.invokeMethod('applyBrightnessFilter', {
        'brightness': brightness,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> applyContrastFilter(double contrast) async {
    try {
      await methodChannel.invokeMethod('applyContrastFilter', {
        'contrast': contrast,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> applyRGBFilter(
      {required double red,
      required double green,
      required double blue}) async {
    try {
      await methodChannel.invokeMethod('applyRGBFilter', {
        'red': red,
        'green': green,
        'blue': blue,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> applySkinSmoothing(double level) async {
    try {
      await methodChannel.invokeMethod('applySkinSmoothing', {
        'level': level,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> applySkinWhitening(double level) async {
    try {
      await methodChannel.invokeMethod('applySkinWhitening', {
        'level': level,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> applySharpening(double level) async {
    try {
      await methodChannel.invokeMethod('applySharpening', {
        'level': level,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> applyTeethWhitening(double intensity) async {
    try {
      await methodChannel.invokeMethod('applyTeethWhitening', {
        'intensity': intensity,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> applyGrayscaleFilter() async {
    try {
      await methodChannel.invokeMethod('applyGrayscaleFilter');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> applyHue(double hueAngle) async {
    try {
      await methodChannel.invokeMethod('applyHue', {
        'hueAngle': hueAngle,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> applyWhiteBalance(
      {required double temperature, required double tint}) async {
    try {
      await methodChannel.invokeMethod('applyWhiteBalance', {
        'temperature': temperature,
        'tint': tint,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> adjustHSB(
      {required double hue,
      required double saturation,
      required double brightness}) async {
    try {
      await methodChannel.invokeMethod('adjustHSB', {
        'hue': hue,
        'saturation': saturation,
        'brightness': brightness,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> removeBuiltInFilters() async {
    try {
      await methodChannel.invokeMethod('removeBuiltInFilters');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> removeBuiltInFilterByName(String filterName) async {
    try {
      await methodChannel.invokeMethod('removeBuiltInFilterByName', {
        'filterName': filterName,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<bool> isBeautyEffectEnabled() async {
    try {
      final result =
          await methodChannel.invokeMethod<bool>('isBeautyEffectEnabled');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> isCloudFilterEnabled() async {
    try {
      final result =
          await methodChannel.invokeMethod<bool>('isCloudFilterEnabled');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  // Flash and Torch Methods
  @override
  Future<bool> hasFlash() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('hasFlash');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> hasTorch() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('hasTorch');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> setFlashMode(NosmaiFlashMode flashMode) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('setFlashMode', {
        'flashMode': flashMode.name,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> setTorchMode(NosmaiTorchMode torchMode) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('setTorchMode', {
        'torchMode': torchMode.name,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<NosmaiFlashMode> getFlashMode() async {
    try {
      final result = await methodChannel.invokeMethod<String>('getFlashMode');
      switch (result) {
        case 'on':
          return NosmaiFlashMode.on;
        case 'auto':
          return NosmaiFlashMode.auto;
        case 'off':
        default:
          return NosmaiFlashMode.off;
      }
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<NosmaiTorchMode> getTorchMode() async {
    try {
      final result = await methodChannel.invokeMethod<String>('getTorchMode');
      switch (result) {
        case 'on':
          return NosmaiTorchMode.on;
        case 'auto':
          return NosmaiTorchMode.auto;
        case 'off':
        default:
          return NosmaiTorchMode.off;
      }
    } catch (_) {
      rethrow;
    }
  }

  // Effect Parameter Control Methods
  @override
  Future<List<dynamic>> getEffectParameters() async {
    try {
      final result = await methodChannel
          .invokeMethod<List<dynamic>>('getEffectParameters');
      return result ?? [];
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<double> getEffectParameterValue(String parameterName) async {
    try {
      final result =
          await methodChannel.invokeMethod<double>('getEffectParameterValue', {
        'parameterName': parameterName,
      });
      return result ?? 0.0;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> setEffectParameter(String parameterName, double value) async {
    try {
      final result =
          await methodChannel.invokeMethod<bool>('setEffectParameter', {
        'parameterName': parameterName,
        'value': value,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> setEffectParameterString(
      String parameterName, String value) async {
    try {
      final result =
          await methodChannel.invokeMethod<bool>('setEffectParameterString', {
        'parameterName': parameterName,
        'value': value,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  // Android Texture-based preview helpers
  @override
  Future<int?> createPreviewTexture({double? width, double? height}) async {
    try {
      final result = await methodChannel.invokeMethod<int>('createTexture', {
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      });
      return result;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> setRenderSurface(int textureId,
      {required double width, required double height}) async {
    try {
      final result =
          await methodChannel.invokeMethod<bool>('setRenderSurface', {
        'textureId': textureId,
        'width': width,
        'height': height,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> clearRenderSurface(int textureId) async {
    try {
      await methodChannel.invokeMethod('clearRenderSurface', {
        'textureId': textureId,
      });
    } catch (_) {
      rethrow;
    }
  }

  // Background Segmentation Methods
  @override
  Future<bool> isAdvancedFiltersEnabled() async {
    try {
      final result =
          await methodChannel.invokeMethod<bool>('isAdvancedFiltersEnabled');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> setBackgroundSegmentation(
      NosmaiBackgroundSegmentationConfig config) async {
    try {
      final result = await methodChannel.invokeMethod<bool>(
          'setBackgroundSegmentation', config.toMap());
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<bool> clearBackgroundSegmentation() async {
    try {
      final result =
          await methodChannel.invokeMethod<bool>('clearBackgroundSegmentation');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  // Lipstick Methods

  @override
  Future<bool> applyLipstick({
    required NosmaiLipstickStyle style,
    double intensity = 0.5,
  }) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('applyLipstick', {
        'style': style.value,
        'intensity': intensity,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> setLipstickIntensity(double intensity) async {
    try {
      await methodChannel.invokeMethod('setLipstickIntensity', {
        'intensity': intensity,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> removeLipstick() async {
    try {
      await methodChannel.invokeMethod('removeLipstick');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<bool> hasLipstick() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('hasLipstick');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getLipstickColors() async {
    try {
      final result =
          await methodChannel.invokeMethod<List<dynamic>>('getLipstickColors');
      if (result == null) return [];
      return result
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    } catch (_) {
      rethrow;
    }
  }

  // Eyeshadow Methods

  @override
  Future<bool> applyEyeshadow({
    required NosmaiEyeshadowStyle style,
    double intensity = 0.5,
  }) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('applyEyeshadow', {
        'style': style.value,
        'intensity': intensity,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> setEyeshadowIntensity(double intensity) async {
    try {
      await methodChannel.invokeMethod('setEyeshadowIntensity', {
        'intensity': intensity,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> removeEyeshadow() async {
    try {
      await methodChannel.invokeMethod('removeEyeshadow');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<bool> hasEyeshadow() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('hasEyeshadow');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  // Blusher Methods

  @override
  Future<bool> applyBlusher({
    required NosmaiBlusherStyle style,
    double intensity = 0.5,
  }) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('applyBlusher', {
        'style': style.value,
        'intensity': intensity,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> setBlusherIntensity(double intensity) async {
    try {
      await methodChannel.invokeMethod('setBlusherIntensity', {
        'intensity': intensity,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> removeBlusher() async {
    try {
      await methodChannel.invokeMethod('removeBlusher');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<bool> hasBlusher() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('hasBlusher');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  // Eyelash Methods

  @override
  Future<bool> applyEyelash({
    required NosmaiEyelashStyle style,
    double intensity = 0.5,
  }) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('applyEyelash', {
        'style': style.value,
        'intensity': intensity,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> setEyelashIntensity(double intensity) async {
    try {
      await methodChannel.invokeMethod('setEyelashIntensity', {
        'intensity': intensity,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> removeEyelash() async {
    try {
      await methodChannel.invokeMethod('removeEyelash');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<bool> hasEyelash() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('hasEyelash');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  // Eyebrow Methods

  @override
  Future<bool> applyEyebrow({
    required NosmaiEyebrowStyle style,
    double intensity = 0.5,
  }) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('applyEyebrow', {
        'style': style.value,
        'intensity': intensity,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> setEyebrowIntensity(double intensity) async {
    try {
      await methodChannel.invokeMethod('setEyebrowIntensity', {
        'intensity': intensity,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> removeEyebrow() async {
    try {
      await methodChannel.invokeMethod('removeEyebrow');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<bool> hasEyebrow() async {
    try {
      final result = await methodChannel.invokeMethod<bool>('hasEyebrow');
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  // Face Morphing Methods

  @override
  Future<void> setFaceSlimLevel(double level) async {
    try {
      await methodChannel.invokeMethod('setFaceSlimLevel', {
        'level': level,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> setEyeSizeLevel(double level) async {
    try {
      await methodChannel.invokeMethod('setEyeSizeLevel', {
        'level': level,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> setNoseSlimLevel(double level) async {
    try {
      await methodChannel.invokeMethod('setNoseSlimLevel', {
        'level': level,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> removeAllMorphing() async {
    try {
      await methodChannel.invokeMethod('removeAllMorphing');
    } catch (e) {
      rethrow;
    }
  }

  // Eye Coloring Methods

  @override
  Future<bool> setEyeColor({
    required double r,
    required double g,
    required double b,
    double intensity = 0.5,
  }) async {
    try {
      final result = await methodChannel.invokeMethod<bool>('setEyeColor', {
        'r': r,
        'g': g,
        'b': b,
        'intensity': intensity,
      });
      return result ?? false;
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> setEyeColorIntensity(double intensity) async {
    try {
      await methodChannel.invokeMethod('setEyeColorIntensity', {
        'intensity': intensity,
      });
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> removeEyeColoring() async {
    try {
      await methodChannel.invokeMethod('removeEyeColoring');
    } catch (e) {
      rethrow;
    }
  }

  // Utility Methods

  @override
  Future<void> removeAllMakeup() async {
    try {
      await methodChannel.invokeMethod('removeAllMakeup');
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<void> removeAllBeautyEffects() async {
    try {
      await methodChannel.invokeMethod('removeAllBeautyEffects');
    } catch (e) {
      rethrow;
    }
  }
}
