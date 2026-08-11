/// Nosmai Flutter Plugin Core API
///
/// This file contains the main NosmaiFlutter class and core API methods.
library;

import 'dart:async';
import 'package:flutter/services.dart';

import '../types/enums.dart';
import '../types/models.dart';
import '../types/errors.dart';
import '../platform/platform_interface.dart';

/// Main NosmaiFlutter class that provides the public API
class NosmaiFlutter {
  /// Private constructor to prevent direct instantiation
  NosmaiFlutter._();

  /// Singleton instance
  static final NosmaiFlutter _instance = NosmaiFlutter._();

  /// Get the shared instance
  static NosmaiFlutter get instance => _instance;

  /// Stream controller for error events (lazy initialization)
  StreamController<NosmaiError>? _errorController;

  /// Stream controller for download progress events (lazy initialization)
  StreamController<NosmaiDownloadProgress>? _downloadProgressController;

  /// Stream controller for recording progress events (lazy initialization)
  StreamController<double>? _recordingProgressController;

  /// Stream controller for license status events (lazy initialization)
  StreamController<NosmaiLicenseStatus>? _licenseStatusController;

  /// Stream controller for active .nosmai package snapshots
  StreamController<NosmaiActiveEffects>? _activeEffectsController;

  /// Whether the SDK has been initialized
  bool _isInitialized = false;

  /// Whether processing is currently active
  bool _isProcessing = false;

  /// Whether recording is currently active
  bool _isRecording = false;

  /// Whether the instance has been disposed
  bool _isDisposed = false;

  /// List of active async operations to cancel on dispose
  final List<Future> _activeOperations = [];

  /// Last pagination info from cloud filters request
  static NosmaiPaginationInfo? _lastPaginationInfo;

  /// Camera switch throttling
  static bool _isCameraSwitching = false;
  static DateTime? _lastSwitchTime;

  /// Stream of error events
  Stream<NosmaiError> get onError {
    _errorController ??= StreamController<NosmaiError>.broadcast();
    return _errorController!.stream;
  }

  /// Stream of download progress events
  Stream<NosmaiDownloadProgress> get onDownloadProgress {
    _downloadProgressController ??=
        StreamController<NosmaiDownloadProgress>.broadcast();
    return _downloadProgressController!.stream;
  }

  /// Stream of recording progress events (duration in seconds)
  Stream<double> get onRecordingProgress {
    _recordingProgressController ??= StreamController<double>.broadcast();
    return _recordingProgressController!.stream;
  }

  /// Stream of license status events
  Stream<NosmaiLicenseStatus> get onLicenseStatusChanged {
    _licenseStatusController ??=
        StreamController<NosmaiLicenseStatus>.broadcast();
    return _licenseStatusController!.stream;
  }

  /// Stream of currently active `.nosmai` packages.
  ///
  /// Use this to keep selected filter/effect/background UI in sync with the
  /// native SDK.
  Stream<NosmaiActiveEffects> get onActiveEffectsChanged {
    _activeEffectsController ??=
        StreamController<NosmaiActiveEffects>.broadcast();
    return _activeEffectsController!.stream;
  }

  // Internal dispatchers for native callbacks
  static void dispatchNativeError(NosmaiError error) {
    final inst = NosmaiFlutter.instance;
    if (inst._isDisposed) return;
    inst._errorController ??= StreamController<NosmaiError>.broadcast();
    inst._errorController!.add(error);
  }

  static void dispatchNativeDownloadProgress(NosmaiDownloadProgress progress) {
    final inst = NosmaiFlutter.instance;
    if (inst._isDisposed) return;
    inst._downloadProgressController ??=
        StreamController<NosmaiDownloadProgress>.broadcast();
    inst._downloadProgressController!.add(progress);
  }

  static void dispatchNativeRecordingProgress(double durationSeconds) {
    final inst = NosmaiFlutter.instance;
    if (inst._isDisposed) return;
    inst._recordingProgressController ??= StreamController<double>.broadcast();
    inst._recordingProgressController!.add(durationSeconds);
  }

  static void dispatchNativeLicenseStatus(NosmaiLicenseStatus status) {
    final inst = NosmaiFlutter.instance;
    if (inst._isDisposed) return;
    inst._licenseStatusController ??=
        StreamController<NosmaiLicenseStatus>.broadcast();
    inst._licenseStatusController!.add(status);
  }

  static void dispatchNativeActiveEffects(NosmaiActiveEffects state) {
    final inst = NosmaiFlutter.instance;
    if (inst._isDisposed) return;
    inst._activeEffectsController ??=
        StreamController<NosmaiActiveEffects>.broadcast();
    inst._activeEffectsController!.add(state);
  }

  /// Whether the SDK is initialized
  bool get isInitialized => _isInitialized;

  /// Whether processing is active
  bool get isProcessing => _isProcessing;

  /// Whether recording is active
  bool get isRecording => _isRecording;

  /// Get the last pagination info from cloud filters request
  ///
  /// Returns null if no paginated request has been made yet.
  /// Use this after calling [getCloudFilters] with pagination parameters.
  NosmaiPaginationInfo? get lastPaginationInfo => _lastPaginationInfo;

  /// Initialize the SDK
  ///
  /// [licenseKey] - Your Nosmai SDK license key
  ///
  /// Returns true if initialization was successful, false otherwise.
  static Future<bool> initialize(String licenseKey) async {
    final instance = NosmaiFlutter.instance;

    // Reset instance state if needed
    if (instance._isDisposed) {
      instance._isDisposed = false;
      instance._isInitialized = false;
      instance._isProcessing = false;
      instance._isRecording = false;
      instance._activeOperations.clear();
    }

    // Initialization is intentionally idempotent. Camera/live screens may both
    // ensure the SDK is ready while a previous PlatformView is still finishing
    // its asynchronous detach. Cleaning up here used to let that old teardown
    // race with (and stop) the new preview, producing an intermittent black
    // screen. Call cleanup() explicitly only when a real context reset is needed.
    if (instance._isInitialized) return true;

    try {
      final success = await instance._trackOperation(
          NosmaiFlutterPlatform.instance.initWithLicense(licenseKey));

      instance._isInitialized = success;

      if (success) {
        _preloadEssentialFilters();
      }

      return success;
    } catch (e) {
      instance._errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to initialize SDK',
        details: e.toString(),
        originalError: e,
      ));
      return false;
    }
  }

  static void _preloadEssentialFilters() {
    Future.microtask(() async {
      try {
        final instance = NosmaiFlutter.instance;
        await instance.getLocalFilters();
      } catch (e) {
        // Filter pre-loading failed
      }
    });
  }

  /// Configure camera with position and optional session preset
  Future<void> configureCamera({
    required NosmaiCameraPosition position,
    String? sessionPreset,
  }) async {
    _checkInitialized();

    try {
      await NosmaiFlutterPlatform.instance.configureCamera(
        position: position,
        sessionPreset: sessionPreset,
      );
    } on PlatformException catch (e) {
      throw NosmaiError.camera(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Camera configuration failed',
        details: e.details?.toString(),
      );
    } catch (e, stackTrace) {
      throw NosmaiError.general(
        type: NosmaiErrorType.cameraConfigurationFailed,
        message: 'Failed to configure camera: ${e.toString()}',
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Start video processing
  Future<void> startProcessing() async {
    _checkInitialized();

    if (_isProcessing) {
      return;
    }

    try {
      await _trackOperation(NosmaiFlutterPlatform.instance.startProcessing());
      _isProcessing = true;
    } catch (e) {
      rethrow;
    }
  }

  /// Stop video processing
  Future<void> stopProcessing() async {
    if (_isDisposed) {
      return;
    }

    if (!_isProcessing) {
      return;
    }

    try {
      await _trackOperation(NosmaiFlutterPlatform.instance.stopProcessing());
      _isProcessing = false;
    } catch (e) {
      _isProcessing = false;
      rethrow;
    }
  }

  /// Apply any external `.nosmai` package.
  ///
  /// This is the unified production apply method for `filter`, `effect`,
  /// `beauty_effect`, and `background` packages. The native SDK reads the
  /// internal manifest and routes the package to the correct render slot.
  ///
  /// Use the returned value for the apply result, and use
  /// [onActiveEffectsChanged] / [getActiveEffects] to update selected UI.
  ///
  /// [effectPath] - Local path or bundled asset path to the `.nosmai` package.
  ///
  /// Returns true if successful, false otherwise.
  Future<bool> applyEffect(String effectPath) async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.applyEffect(effectPath);
  }

  /// Legacy alias for applying external `.nosmai` packages.
  ///
  /// Prefer [applyEffect] for new code. This method is kept for source
  /// compatibility and routes through the same native unified package path.
  ///
  /// [filterPath] - Path to the .nosmai filter file
  ///
  /// Returns true if successful, false otherwise.
  Future<bool> applyFilter(String filterPath) async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.applyFilter(filterPath);
  }

  /// Read the currently active `.nosmai` packages.
  ///
  /// Call this once when opening a screen, then keep the UI updated with
  /// [onActiveEffectsChanged].
  Future<NosmaiActiveEffects> getActiveEffects() async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.getActiveEffects();
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to get active effects',
        details: e.details?.toString(),
      );
    } catch (_) {
      rethrow;
    }
  }

  /// Active color-filter slot metadata, if available.
  Future<NosmaiFilter?> getActiveFilterInfo() async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.getActiveFilterInfo();
  }

  /// Active AR slot metadata. This may be an `effect` or `beauty_effect`.
  Future<NosmaiFilter?> getActiveEffectInfo() async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.getActiveEffectInfo();
  }

  /// Active beauty package metadata, if the active AR slot is `beauty_effect`.
  Future<NosmaiFilter?> getActiveBeautyEffectInfo() async {
    final activeEffect = await getActiveEffectInfo();
    if (activeEffect == null) return null;
    return activeEffect.isBeautyEffect ? activeEffect : null;
  }

  /// Remove a specific external package using its manifest type.
  ///
  /// The native SDK chooses the matching slot from [filter.sourceType].
  Future<bool> removeEffect(NosmaiFilter filter) async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.removeEffect(filter);
  }

  /// Get list of available cloud filters with optional pagination support
  ///
  /// **Pagination Parameters (all optional - backward compatible):**
  /// - [filterType]: Filter by type using [NosmaiCloudFilterType] enum (null = all types)
  /// - [version]: Cloud filter compatibility version (default: version 2)
  /// - [page]: Page number to fetch (null = fetch all pages, legacy behavior)
  /// - [limit]: Number of items per page (default: 20)
  /// - [fetchAllPages]: If true, fetches all pages at once (default: true for backward compatibility)
  ///
  /// **Backward Compatibility:**
  /// When called without any parameters, behaves exactly like before - fetches all filters.
  ///
  /// **Pagination Info:**
  /// After calling with pagination params, access [lastPaginationInfo] to get
  /// pagination metadata (currentPage, totalPages, hasNextPage, etc.)
  ///
  /// **Example Usage:**
  /// ```dart
  /// // Legacy usage (unchanged) - fetches all filters
  /// final allFilters = await nosmai.getCloudFilters();
  ///
  /// // New paginated usage - fetch page 1 with 20 items
  /// final page1 = await nosmai.getCloudFilters(
  ///   filterType: NosmaiCloudFilterType.effects,
  ///   page: 1,
  ///   limit: 20,
  /// );
  /// final pagination = nosmai.lastPaginationInfo;
  /// if (pagination?.hasNextPage == true) {
  ///   final page2 = await nosmai.getCloudFilters(
  ///     filterType: NosmaiCloudFilterType.effects,
  ///     page: 2,
  ///     limit: 20,
  ///   );
  /// }
  ///
  /// // Filter by type
  /// final effects = await nosmai.getCloudFilters(
  ///   filterType: NosmaiCloudFilterType.effects,
  ///   page: 1,
  /// );
  /// final filters = await nosmai.getCloudFilters(
  ///   filterType: NosmaiCloudFilterType.filter,
  ///   page: 1,
  /// );
  /// final backgrounds = await nosmai.getCloudFilters(
  ///   filterType: NosmaiCloudFilterType.background,
  ///   page: 1,
  /// );
  /// final beautyEffects = await nosmai.getCloudFilters(
  ///   filterType: NosmaiCloudFilterType.beautyEffect,
  ///   page: 1,
  /// );
  /// ```
  Future<List<NosmaiFilter>> getCloudFilters({
    NosmaiCloudFilterType? filterType,
    NosmaiCloudFilterVersion version = NosmaiCloudFilterVersion.v2,
    int? page,
    int? limit,
    bool? fetchAllPages,
  }) async {
    _checkInitialized();
    try {
      // Determine fetchAllPages: default to true only when no pagination params provided
      final bool shouldFetchAll = fetchAllPages ?? (page == null);

      final Map<String, dynamic> result =
          await NosmaiFlutterPlatform.instance.getCloudFiltersWithOptions(
        filterType: filterType,
        version: version,
        page: page,
        limit: limit,
        fetchAllPages: shouldFetchAll,
      );

      // Parse pagination info if present
      if (result['pagination'] != null) {
        _lastPaginationInfo = NosmaiPaginationInfo.fromMap(
            Map<String, dynamic>.from(result['pagination']));
      } else if (page != null) {
        // Clear pagination info if paginated request but no info returned
        _lastPaginationInfo = null;
      }

      // Parse filters
      final filtersData = result['filters'];
      if (filtersData is List) {
        return filtersData
            .map((filter) =>
                NosmaiFilter.fromMap(Map<String, dynamic>.from(filter)))
            .toList();
      }

      return [];
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to get cloud filters',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.networkError,
        message: 'Failed to get cloud filters',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Download a cloud filter
  Future<Map<String, dynamic>> downloadCloudFilter(String filterId) async {
    _checkInitialized();
    try {
      final result =
          await NosmaiFlutterPlatform.instance.downloadCloudFilter(filterId);

      return result;
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to download cloud filter',
        details: e.details?.toString(),
      );
    }
  }

  /// Remove a downloaded cloud filter from local storage
  ///
  /// [filterId] - The filter ID to remove
  ///
  /// Returns true if successful, false otherwise.
  ///
  /// Example:
  /// ```dart
  /// final success = await nosmai.removeCloudFilter('filter_123');
  /// if (success) {
  ///   print('Filter removed');
  /// }
  /// ```
  Future<bool> removeCloudFilter(String filterId) async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.removeCloudFilter(filterId);
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to remove cloud filter',
        details: e.details?.toString(),
      );
    }
  }

  /// Get production local .nosmai filters.
  ///
  /// Flutter production filters should use the manifest-based structure:
  /// `assets/nosmai_filters/{filter_name}/`.
  ///
  /// [forceRefresh] - If true, clears the cache and reloads filters from disk
  Future<List<NosmaiFilter>> getLocalFilters(
      {bool forceRefresh = false}) async {
    _checkInitialized();
    try {
      final List<dynamic> filters =
          await NosmaiFlutterPlatform.instance.getLocalFilters(
        forceRefresh: forceRefresh,
      );

      final filterList = filters
          .map((filter) =>
              NosmaiFilter.fromMap(Map<String, dynamic>.from(filter)))
          .toList();

      return filterList;
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to get local filters',
        details: e.details?.toString(),
      );
    }
  }

  /// Get all production local .nosmai filters grouped by filterType.
  ///
  /// Keys are usually `filter`, `effect`, `background`, and `beauty_effect`.
  Future<Map<String, List<NosmaiFilter>>> getAllLocalFilters(
      {bool forceRefresh = false}) async {
    _checkInitialized();
    try {
      final grouped = await NosmaiFlutterPlatform.instance.getAllLocalFilters(
        forceRefresh: forceRefresh,
      );

      return grouped.map(
        (type, filters) => MapEntry(
          type,
          filters
              .map((filter) =>
                  NosmaiFilter.fromMap(Map<String, dynamic>.from(filter)))
              .toList(),
        ),
      );
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to get all local filters',
        details: e.details?.toString(),
      );
    }
  }

  /// Development-only discovery for bundled debug .nosmai filters.
  ///
  /// This is useful while testing loose `.nosmai` assets, usually under
  /// `assets/filters/`. It does not require the production manifest/preview
  /// folder structure.
  ///
  /// Pass `type: null` to receive all debug filters. Production apps should use
  /// [getLocalFilters], [getLocalEffects], [getLocalBackgrounds],
  /// [getLocalBeautyEffects], or [getAllLocalFilters].
  Future<List<NosmaiFilter>> getDebugFilters({
    NosmaiLocalFilterType? type,
  }) async {
    _checkInitialized();
    try {
      final List<dynamic> filters =
          await NosmaiFlutterPlatform.instance.getDebugFilters(type: type);
      return filters
          .map((filter) =>
              NosmaiFilter.fromMap(Map<String, dynamic>.from(filter)))
          .toList();
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to get debug filters',
        details: e.details?.toString(),
      );
    }
  }

  /// Get list of local AR effects (masks, 3D overlays, etc.)
  ///
  /// Returns only filters with filterType "effect".
  /// These are typically interactive AR effects that respond to face tracking.
  ///
  /// Example:
  /// ```dart
  /// final effects = await NosmaiFlutter.instance.getLocalEffects();
  /// for (final effect in effects) {
  ///   print('Effect: ${effect.displayName}');
  /// }
  /// ```
  Future<List<NosmaiFilter>> getLocalEffects() async {
    _checkInitialized();
    try {
      final List<dynamic> effects =
          await NosmaiFlutterPlatform.instance.getLocalEffects();

      return effects
          .map((effect) =>
              NosmaiFilter.fromMap(Map<String, dynamic>.from(effect)))
          .toList();
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to get local effects',
        details: e.details?.toString(),
      );
    }
  }

  /// Get list of local background filters
  ///
  /// Returns only filters with filterType "background".
  /// These are background replacement/blur effects.
  ///
  /// Example:
  /// ```dart
  /// final backgrounds = await NosmaiFlutter.instance.getLocalBackgrounds();
  /// for (final bg in backgrounds) {
  ///   print('Background: ${bg.displayName}');
  /// }
  /// ```
  Future<List<NosmaiFilter>> getLocalBackgrounds() async {
    _checkInitialized();
    try {
      final List<dynamic> backgrounds =
          await NosmaiFlutterPlatform.instance.getLocalBackgrounds();

      return backgrounds
          .map((bg) => NosmaiFilter.fromMap(Map<String, dynamic>.from(bg)))
          .toList();
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to get local backgrounds',
        details: e.details?.toString(),
      );
    }
  }

  /// Get list of local beauty effects
  ///
  /// Returns only filters with filterType "beauty_effect".
  /// These are preset beauty filter combinations.
  ///
  /// Example:
  /// ```dart
  /// final beautyEffects = await NosmaiFlutter.instance.getLocalBeautyEffects();
  /// for (final beauty in beautyEffects) {
  ///   print('Beauty Effect: ${beauty.displayName}');
  /// }
  /// ```
  Future<List<NosmaiFilter>> getLocalBeautyEffects() async {
    _checkInitialized();
    try {
      final List<dynamic> beautyEffects =
          await NosmaiFlutterPlatform.instance.getLocalBeautyEffects();

      return beautyEffects
          .map((beauty) =>
              NosmaiFilter.fromMap(Map<String, dynamic>.from(beauty)))
          .toList();
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to get local beauty effects',
        details: e.details?.toString(),
      );
    }
  }

  /// Clear the local filters cache
  ///
  /// Call this method to force reload filters on the next [getLocalFilters] call.
  /// Useful during development or when filter assets have been updated.
  Future<bool> clearLocalFiltersCache() async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.clearLocalFiltersCache();
    } catch (_) {
      rethrow;
    }
  }

  /// Validate local filters and return detailed error/warning information
  ///
  /// Use this method to debug why filters may not be loading correctly.
  /// Returns a list of validation results for each filter folder found.
  ///
  /// Example:
  /// ```dart
  /// final results = await nosmaiFlutter.validateLocalFilters();
  /// for (final result in results) {
  ///   if (!result.isValid) {
  ///     print('❌ ${result.folderName}: ${result.errors}');
  ///   } else if (result.warnings.isNotEmpty) {
  ///     print('⚠️ ${result.folderName}: ${result.warnings}');
  ///   } else {
  ///     print('✅ ${result.folderName}: OK');
  ///   }
  /// }
  /// ```
  Future<List<FilterValidationResult>> validateLocalFilters() async {
    _checkInitialized();
    try {
      final List<dynamic> results =
          await NosmaiFlutterPlatform.instance.validateLocalFilters();

      return results
          .map((result) =>
              FilterValidationResult.fromMap(Map<String, dynamic>.from(result)))
          .toList();
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to validate local filters',
        details: e.details?.toString(),
      );
    }
  }

  /// Clear filter cache (both Flutter memory and native cache)
  Future<void> clearCache() async {
    try {
      await NosmaiFlutterPlatform.instance.clearFilterCache();
    } catch (_) {
      rethrow;
    }
  }

  /// Switch camera position
  ///
  /// Switches between front and back camera with built-in protection against
  /// rapid switching that could cause crashes.
  ///
  /// Returns true if camera switch was performed, false if ignored.
  Future<bool> switchCamera() async {
    const throttleDuration = Duration(milliseconds: 500);
    _checkInitialized();

    // Check if camera switching is in progress - silently ignore
    if (_isCameraSwitching) {
      return false;
    }

    // Check throttle timing - silently ignore rapid taps
    final now = DateTime.now();
    if (_lastSwitchTime != null &&
        now.difference(_lastSwitchTime!) < throttleDuration) {
      return false;
    }

    // Set switching state
    _isCameraSwitching = true;
    _lastSwitchTime = now;

    try {
      // Perform the camera switch directly
      final success = await NosmaiFlutterPlatform.instance.switchCamera();
      if (!success) {
        throw NosmaiError.camera(
          type: NosmaiErrorType.cameraSwitchFailed,
          message: 'Camera switch operation failed',
          details: 'The camera switch operation was unsuccessful',
        );
      }
      return true;
    } on PlatformException catch (e) {
      throw NosmaiError.camera(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Camera switch failed',
        details: e.details?.toString(),
      );
    } catch (e, stackTrace) {
      if (e is NosmaiError) rethrow;
      throw NosmaiError.general(
        type: NosmaiErrorType.cameraSwitchFailed,
        message: 'Failed to switch camera: ${e.toString()}',
        originalError: e,
        stackTrace: stackTrace,
      );
    } finally {
      // Always reset switching state
      _isCameraSwitching = false;
    }
  }

  /// Whether a camera switch operation is currently in progress
  static bool get isCameraSwitching => _isCameraSwitching;

  /// Remove all applied filters (AR effects + regular filters)
  /// Does NOT clear beauty effects or background segmentation
  Future<void> removeAllFilters() async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.removeAllFilters();
  }

  /// Clear only the AR effect
  ///
  /// Keeps regular filter, beauty effects, and background segmentation intact.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.clearAREffect();
  /// ```
  Future<void> clearAREffect() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.clearAREffect();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to clear AR effect',
        details: e.details?.toString(),
      );
    }
  }

  /// Clear only the regular filter
  ///
  /// Keeps AR effect, beauty effects, and background segmentation intact.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.clearFilter();
  /// ```
  Future<void> clearFilter() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.clearFilter();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to clear filter',
        details: e.details?.toString(),
      );
    }
  }

  /// Clear everything - Nuclear option
  ///
  /// Clears ALL: AR effects, regular filters, beauty effects, and background segmentation.
  /// Use this when you want to completely reset the visual pipeline.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.clearAll();
  /// ```
  Future<void> clearAll() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.clearAll();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to clear all effects',
        details: e.details?.toString(),
      );
    }
  }

  /// Clean up and release all resources
  Future<void> cleanup() async {
    if (_isDisposed) return;

    // ✅ DON'T set _isDisposed here - this is called during re-initialization
    // Only dispose() should set _isDisposed = true

    try {
      if (_isRecording) {
        await stopRecording().catchError((e) {
          return NosmaiRecordingResult(
              success: false, videoPath: null, duration: 0.0, fileSize: 0);
        });
      }

      if (_isProcessing) {
        await stopProcessing().catchError((e) {
          // Processing stop failed during cleanup
        });
      }

      if (_isInitialized) {
        await NosmaiFlutterPlatform.instance.cleanup().catchError((e) {
          // Platform cleanup failed during cleanup - ignore error
        });
      }

      _isInitialized = false;
      _isProcessing = false;
      _isRecording = false;
      _activeOperations.clear();
    } catch (e) {
      // Cleanup error ignored
    }
  }

  /// Pause camera hardware
  ///
  /// Only stops the camera hardware while keeping SDK processing active.
  /// This is faster than cleanup() and allows instant resume.
  /// Use this for temporary tab switches (e.g., navigation between tabs).
  ///
  /// Returns true if paused successfully, false otherwise.
  Future<bool> pauseCamera() async {
    _checkInitialized();

    try {
      final result = await NosmaiFlutterPlatform.instance.pauseCamera();
      return result == true;
    } catch (_) {
      rethrow;
    }
  }

  /// Resume camera hardware
  ///
  /// Only restarts the camera hardware, SDK processing already active.
  /// This provides instant camera restart after pauseCamera().
  /// Use this when returning to camera tab after temporary navigation.
  ///
  /// Returns true if resumed successfully, false otherwise.
  Future<bool> resumeCamera() async {
    _checkInitialized();

    try {
      final result = await NosmaiFlutterPlatform.instance.resumeCamera();
      return result == true;
    } catch (_) {
      rethrow;
    }
  }

  /// Start video recording
  Future<bool> startRecording() async {
    _checkInitialized();

    if (_isRecording) {
      return true;
    }

    final success =
        await _trackOperation(NosmaiFlutterPlatform.instance.startRecording());

    if (success) {
      _isRecording = true;
    }

    return success;
  }

  /// Stop video recording
  Future<NosmaiRecordingResult> stopRecording() async {
    _checkInitialized();

    if (!_isRecording) {
      return const NosmaiRecordingResult(
        success: false,
        duration: 0,
        fileSize: 0,
        error: 'Not currently recording',
      );
    }

    try {
      final result =
          await _trackOperation(NosmaiFlutterPlatform.instance.stopRecording());

      _isRecording = false;

      final recordingResult =
          NosmaiRecordingResult.fromMap(Map<String, dynamic>.from(result));

      // Recording stopped

      return recordingResult;
    } catch (e) {
      _isRecording = false;
      return NosmaiRecordingResult(
        success: false,
        duration: 0,
        fileSize: 0,
        error: e.toString(),
      );
    }
  }

  /// Capture photo with applied filters
  Future<NosmaiPhotoResult> capturePhoto() async {
    _checkInitialized();
    try {
      final result = await NosmaiFlutterPlatform.instance.capturePhoto();
      return NosmaiPhotoResult.fromMap(result);
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to capture photo',
        details: e.toString(),
        originalError: e,
      ));
      return NosmaiPhotoResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Detach camera view (for navigation cleanup)
  Future<void> detachCameraView() async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.detachCameraView();
  }

  /// Reinitialize the preview (useful for navigation recovery)
  Future<void> reinitializePreview() async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.reinitializePreview();
  }

  /// Save image data to device gallery
  Future<Map<String, dynamic>> saveImageToGallery(List<int> imageData,
      {String? name}) async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance
        .saveImageToGallery(imageData, name: name);
  }

  /// Save video file to device gallery
  Future<Map<String, dynamic>> saveVideoToGallery(String videoPath,
      {String? name}) async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance
        .saveVideoToGallery(videoPath, name: name);
  }

  // Built-in Filter Methods
  /// Apply brightness filter
  Future<void> applySkinSmoothing(double level) async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.applySkinSmoothing(level);
  }

  /// Apply skin whitening filter
  Future<void> applySkinWhitening(double level) async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.applySkinWhitening(level);
  }

  /// Apply brightness filter
  Future<void> applyBrightnessFilter(double brightness) async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.applyBrightnessFilter(brightness);
  }

  /// Apply contrast filter
  Future<void> applyContrastFilter(double contrast) async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.applyContrastFilter(contrast);
  }

  /// Apply RGB filter
  Future<void> applyRGBFilter(
      {required double red,
      required double green,
      required double blue}) async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance
        .applyRGBFilter(red: red, green: green, blue: blue);
  }

  /// Apply sharpening filter
  Future<void> applySharpening(double level) async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.applySharpening(level);
  }

  /// Apply teeth whitening filter.
  ///
  /// [intensity] ranges 0.0 (off) to 1.0 (full). Uses MediaPipe inner-lip
  /// landmarks. Pass 0.0 to remove the effect.
  Future<void> applyTeethWhitening(double intensity) async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.applyTeethWhitening(intensity);
  }

  /// Apply grayscale filter
  Future<void> applyGrayscaleFilter() async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.applyGrayscaleFilter();
  }

  /// Apply hue filter
  Future<void> applyHue(double hueAngle) async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.applyHue(hueAngle);
  }

  /// Apply white balance filter
  Future<void> applyWhiteBalance(
      {required double temperature, required double tint}) async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance
        .applyWhiteBalance(temperature: temperature, tint: tint);
  }

  /// Adjust HSB (Hue, Saturation, Brightness)
  Future<void> adjustHSB(
      {required double hue,
      required double saturation,
      required double brightness}) async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance
        .adjustHSB(hue: hue, saturation: saturation, brightness: brightness);
  }

  /// Remove all built-in filters
  Future<void> removeBuiltInFilters() async {
    _checkInitialized();
    await NosmaiFlutterPlatform.instance.removeBuiltInFilters();
  }

  /// Check if beauty filters are enabled
  Future<bool> isBeautyFilterEnabled() async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.isBeautyEffectEnabled();
  }

  /// Check if cloud filters are enabled/available
  Future<bool> isCloudFilterEnabled() async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.isCloudFilterEnabled();
  }

  // Flash and Torch Methods
  Future<bool> hasFlash() async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.hasFlash();
  }

  Future<bool> hasTorch() async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.hasTorch();
  }

  Future<bool> setFlashMode(NosmaiFlashMode flashMode) async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.setFlashMode(flashMode);
  }

  Future<bool> setTorchMode(NosmaiTorchMode torchMode) async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.setTorchMode(torchMode);
  }

  Future<NosmaiFlashMode> getFlashMode() async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.getFlashMode();
  }

  Future<NosmaiTorchMode> getTorchMode() async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.getTorchMode();
  }

  // Background Segmentation Methods

  /// Check if advanced filters (background segmentation) are enabled in the license
  ///
  /// Returns true if background segmentation features are available with the current license.
  /// Use this to check before calling any background segmentation methods.
  ///
  /// Example:
  /// ```dart
  /// if (await nosmai.isAdvancedFiltersEnabled()) {
  ///   await nosmai.setBackgroundSegmentation(
  ///     NosmaiBackgroundSegmentationConfig.color(Colors.green),
  ///   );
  /// }
  /// ```
  Future<bool> isAdvancedFiltersEnabled() async {
    _checkInitialized();
    return await NosmaiFlutterPlatform.instance.isAdvancedFiltersEnabled();
  }

  /// Apply background segmentation with the given configuration
  ///
  /// Replaces the background with a solid color, image, or video.
  /// Use [NosmaiBackgroundSegmentationConfig] factory constructors for easy setup.
  ///
  /// Returns true if successful, false otherwise.
  ///
  /// **Available modes:**
  /// - `NosmaiBackgroundSegmentationConfig.color(Color)` - Solid color background
  /// - `NosmaiBackgroundSegmentationConfig.image(Uint8List)` - Image background
  /// - `NosmaiBackgroundSegmentationConfig.video(String)` - Video background
  ///
  /// Example:
  /// ```dart
  /// // Color background
  /// await nosmai.setBackgroundSegmentation(
  ///   NosmaiBackgroundSegmentationConfig.color(Colors.green),
  /// );
  ///
  /// // Image background
  /// final imageBytes = await loadImageBytes();
  /// await nosmai.setBackgroundSegmentation(
  ///   NosmaiBackgroundSegmentationConfig.image(imageBytes),
  /// );
  ///
  /// // Video background
  /// await nosmai.setBackgroundSegmentation(
  ///   NosmaiBackgroundSegmentationConfig.video('/path/to/video.mp4'),
  /// );
  /// ```
  Future<bool> setBackgroundSegmentation(
      NosmaiBackgroundSegmentationConfig config) async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance
          .setBackgroundSegmentation(config);
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set background segmentation',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to set background segmentation',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Clear/disable background segmentation
  Future<bool> clearBackgroundSegmentation() async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.clearBackgroundSegmentation();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to clear background segmentation',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to clear background segmentation',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  // Lipstick Methods

  /// Apply lipstick with style and color index
  ///
  /// Applies lipstick effect with the specified style and color from
  /// Apply lipstick with specified style
  ///
  /// [style] - Lipstick texture style (classic, matte, natural)
  /// [intensity] - Opacity/intensity from 0.0 to 1.0 (default: 0.5)
  ///
  /// Returns true if successful, false otherwise.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.applyLipstick(
  ///   style: NosmaiLipstickStyle.matte,
  ///   intensity: 0.8,
  /// );
  /// ```
  Future<bool> applyLipstick({
    required NosmaiLipstickStyle style,
    double intensity = 0.5,
  }) async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.applyLipstick(
        style: style,
        intensity: intensity.clamp(0.0, 1.0),
      );
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to apply lipstick',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to apply lipstick',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Set lipstick intensity/opacity
  ///
  /// Adjusts the intensity of currently applied lipstick.
  ///
  /// [intensity] - Value from 0.0 (invisible) to 1.0 (full)
  ///
  /// Example:
  /// ```dart
  /// await nosmai.setLipstickIntensity(0.5);
  /// ```
  Future<void> setLipstickIntensity(double intensity) async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance
          .setLipstickIntensity(intensity.clamp(0.0, 1.0));
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set lipstick intensity',
        details: e.details?.toString(),
      );
    }
  }

  /// Remove lipstick effect
  ///
  /// Removes the currently applied lipstick effect.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.removeLipstick();
  /// ```
  Future<void> removeLipstick() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.removeLipstick();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to remove lipstick',
        details: e.details?.toString(),
      );
    }
  }

  /// Check if lipstick is currently applied
  ///
  /// Returns true if lipstick effect is active.
  ///
  /// Example:
  /// ```dart
  /// if (await nosmai.hasLipstick()) {
  ///   print('Lipstick is applied');
  /// }
  /// ```
  Future<bool> hasLipstick() async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.hasLipstick();
    } catch (_) {
      rethrow;
    }
  }

  /// Get available predefined lipstick colors (for reference only)
  ///
  /// Returns a list of available lipstick colors in the SDK.
  /// Note: The default color is automatically applied with [applyLipstick].
  ///
  /// Each color contains:
  /// - 'name': Color name (String)
  /// - 'r', 'g', 'b': RGB values (0.0 - 1.0)
  ///
  /// Example:
  /// ```dart
  /// final colors = await nosmai.getLipstickColors();
  /// for (var i = 0; i < colors.length; i++) {
  ///   print('Color $i: ${colors[i]['name']}');
  /// }
  /// ```
  Future<List<Map<String, dynamic>>> getLipstickColors() async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.getLipstickColors();
    } catch (_) {
      rethrow;
    }
  }

  // Eyeshadow Methods

  /// Apply eyeshadow with specified style
  ///
  /// [style] - Eyeshadow style (smokey, shimmer, natural)
  /// [intensity] - Opacity/intensity from 0.0 to 1.0 (default: 0.5)
  ///
  /// Returns true if successful, false otherwise.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.applyEyeshadow(
  ///   style: NosmaiEyeshadowStyle.smokey,
  ///   intensity: 0.6,
  /// );
  /// ```
  Future<bool> applyEyeshadow({
    required NosmaiEyeshadowStyle style,
    double intensity = 0.5,
  }) async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.applyEyeshadow(
        style: style,
        intensity: intensity.clamp(0.0, 1.0),
      );
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to apply eyeshadow',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to apply eyeshadow',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Set eyeshadow intensity
  ///
  /// [intensity] - Value from 0.0 (invisible) to 1.0 (full)
  Future<void> setEyeshadowIntensity(double intensity) async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance
          .setEyeshadowIntensity(intensity.clamp(0.0, 1.0));
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set eyeshadow intensity',
        details: e.details?.toString(),
      );
    }
  }

  /// Remove eyeshadow effect
  Future<void> removeEyeshadow() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.removeEyeshadow();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to remove eyeshadow',
        details: e.details?.toString(),
      );
    }
  }

  /// Check if eyeshadow is currently applied
  Future<bool> hasEyeshadow() async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.hasEyeshadow();
    } catch (_) {
      rethrow;
    }
  }

  // Blusher Methods

  /// Apply blusher with specified style
  ///
  /// [style] - Blusher style (round, contour, natural)
  /// [intensity] - Opacity/intensity from 0.0 to 1.0 (default: 0.5)
  ///
  /// Returns true if successful, false otherwise.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.applyBlusher(
  ///   style: NosmaiBlusherStyle.natural,
  ///   intensity: 0.5,
  /// );
  /// ```
  Future<bool> applyBlusher({
    required NosmaiBlusherStyle style,
    double intensity = 0.5,
  }) async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.applyBlusher(
        style: style,
        intensity: intensity.clamp(0.0, 1.0),
      );
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to apply blusher',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to apply blusher',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Set blusher intensity
  ///
  /// [intensity] - Value from 0.0 (invisible) to 1.0 (full)
  Future<void> setBlusherIntensity(double intensity) async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance
          .setBlusherIntensity(intensity.clamp(0.0, 1.0));
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set blusher intensity',
        details: e.details?.toString(),
      );
    }
  }

  /// Remove blusher effect
  Future<void> removeBlusher() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.removeBlusher();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to remove blusher',
        details: e.details?.toString(),
      );
    }
  }

  /// Check if blusher is currently applied
  Future<bool> hasBlusher() async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.hasBlusher();
    } catch (_) {
      rethrow;
    }
  }

  // Eyelash Methods

  /// Apply eyelash with specified style
  ///
  /// [style] - Eyelash style (natural, dramatic, wispy)
  /// [intensity] - Opacity/intensity from 0.0 to 1.0 (default: 0.5)
  ///
  /// Returns true if successful, false otherwise.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.applyEyelash(
  ///   style: NosmaiEyelashStyle.dramatic,
  ///   intensity: 0.8,
  /// );
  /// ```
  Future<bool> applyEyelash({
    required NosmaiEyelashStyle style,
    double intensity = 0.5,
  }) async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.applyEyelash(
        style: style,
        intensity: intensity.clamp(0.0, 1.0),
      );
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to apply eyelash',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to apply eyelash',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Set eyelash intensity
  ///
  /// [intensity] - Value from 0.0 (invisible) to 1.0 (full)
  Future<void> setEyelashIntensity(double intensity) async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance
          .setEyelashIntensity(intensity.clamp(0.0, 1.0));
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set eyelash intensity',
        details: e.details?.toString(),
      );
    }
  }

  /// Remove eyelash effect
  Future<void> removeEyelash() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.removeEyelash();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to remove eyelash',
        details: e.details?.toString(),
      );
    }
  }

  /// Check if eyelash is currently applied
  Future<bool> hasEyelash() async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.hasEyelash();
    } catch (_) {
      rethrow;
    }
  }

  // Eyebrow Methods

  /// Apply eyebrow with specified style
  ///
  /// [style] - Eyebrow style (natural, bold, arched)
  /// [intensity] - Opacity/intensity from 0.0 to 1.0 (default: 0.5)
  ///
  /// Returns true if successful, false otherwise.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.applyEyebrow(
  ///   style: NosmaiEyebrowStyle.bold,
  ///   intensity: 0.7,
  /// );
  /// ```
  Future<bool> applyEyebrow({
    required NosmaiEyebrowStyle style,
    double intensity = 0.5,
  }) async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.applyEyebrow(
        style: style,
        intensity: intensity.clamp(0.0, 1.0),
      );
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to apply eyebrow',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to apply eyebrow',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Set eyebrow intensity
  ///
  /// [intensity] - Value from 0.0 (invisible) to 1.0 (full)
  Future<void> setEyebrowIntensity(double intensity) async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance
          .setEyebrowIntensity(intensity.clamp(0.0, 1.0));
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set eyebrow intensity',
        details: e.details?.toString(),
      );
    }
  }

  /// Remove eyebrow effect
  Future<void> removeEyebrow() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.removeEyebrow();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to remove eyebrow',
        details: e.details?.toString(),
      );
    }
  }

  /// Check if eyebrow is currently applied
  Future<bool> hasEyebrow() async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.hasEyebrow();
    } catch (_) {
      rethrow;
    }
  }

  // Face Morphing Methods

  /// Set face slim level
  ///
  /// [level] - 0.0 (none) to 1.0 (maximum slimming)
  ///
  /// Example:
  /// ```dart
  /// await nosmai.setFaceSlimLevel(0.3);
  /// ```
  Future<void> setFaceSlimLevel(double level) async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance
          .setFaceSlimLevel(level.clamp(0.0, 1.0));
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set face slim level',
        details: e.details?.toString(),
      );
    }
  }

  /// Set eye size level
  ///
  /// [level] - 0.0 (normal) to 1.0 (maximum enlargement)
  ///
  /// Example:
  /// ```dart
  /// await nosmai.setEyeSizeLevel(0.4);
  /// ```
  Future<void> setEyeSizeLevel(double level) async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance
          .setEyeSizeLevel(level.clamp(0.0, 1.0));
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set eye size level',
        details: e.details?.toString(),
      );
    }
  }

  /// Set nose slim level
  ///
  /// [level] - 0.0 (none) to 1.0 (maximum slimming)
  ///
  /// Example:
  /// ```dart
  /// await nosmai.setNoseSlimLevel(0.2);
  /// ```
  Future<void> setNoseSlimLevel(double level) async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance
          .setNoseSlimLevel(level.clamp(0.0, 1.0));
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set nose slim level',
        details: e.details?.toString(),
      );
    }
  }

  /// Remove all face morphing effects
  ///
  /// Resets face slim, eye size, nose slim, and all morphing to default.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.removeAllMorphing();
  /// ```
  Future<void> removeAllMorphing() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.removeAllMorphing();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to remove morphing',
        details: e.details?.toString(),
      );
    }
  }

  // Eye Coloring Methods

  /// Set eye color using Flutter Color
  ///
  /// [color] - Flutter Color (e.g., Colors.blue, Color(0xFF2196F3))
  /// [intensity] - 0.0 (none) to 1.0 (full), default 0.5
  ///
  /// Example:
  /// ```dart
  /// // Blue eyes
  /// await nosmai.setEyeColor(Colors.blue);
  ///
  /// // Green eyes with custom intensity
  /// await nosmai.setEyeColor(Colors.green, intensity: 0.7);
  ///
  /// // Custom color
  /// await nosmai.setEyeColor(Color(0xFF8B4513)); // Hazel
  /// ```
  Future<bool> setEyeColor(Color color, {double intensity = 0.5}) async {
    _checkInitialized();
    try {
      return await NosmaiFlutterPlatform.instance.setEyeColor(
        r: color.r,
        g: color.g,
        b: color.b,
        intensity: intensity.clamp(0.0, 1.0),
      );
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set eye color',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to set eye color',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Set eye color intensity
  ///
  /// [intensity] - 0.0 (none) to 1.0 (full)
  ///
  /// Example:
  /// ```dart
  /// await nosmai.setEyeColorIntensity(0.6);
  /// ```
  Future<void> setEyeColorIntensity(double intensity) async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance
          .setEyeColorIntensity(intensity.clamp(0.0, 1.0));
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set eye color intensity',
        details: e.details?.toString(),
      );
    }
  }

  /// Remove eye coloring effect
  ///
  /// Example:
  /// ```dart
  /// await nosmai.removeEyeColoring();
  /// ```
  Future<void> removeEyeColoring() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.removeEyeColoring();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to remove eye coloring',
        details: e.details?.toString(),
      );
    }
  }

  // Utility Methods

  /// Remove all makeup effects
  ///
  /// Removes lipstick, eyeshadow, blusher, eyelash, and eyebrow.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.removeAllMakeup();
  /// ```
  Future<void> removeAllMakeup() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.removeAllMakeup();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to remove all makeup',
        details: e.details?.toString(),
      );
    }
  }

  /// Remove all beauty effects
  ///
  /// Removes all makeup + face morphing + eye coloring.
  ///
  /// Example:
  /// ```dart
  /// await nosmai.removeAllBeautyEffects();
  /// ```
  Future<void> removeAllBeautyEffects() async {
    _checkInitialized();
    try {
      await NosmaiFlutterPlatform.instance.removeAllBeautyEffects();
    } on PlatformException catch (e) {
      throw NosmaiError.general(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to remove all beauty effects',
        details: e.details?.toString(),
      );
    }
  }

  // Effect Parameter Control Methods
  /// Get all available parameters for the currently loaded effect
  ///
  /// Returns a list of [FilterParameter] objects containing metadata about
  /// each adjustable parameter in the active .nosmai filter.
  ///
  /// Returns an empty list if:
  /// - No effect is currently active
  /// - The active effect has no adjustable parameters
  /// - An error occurs during retrieval
  ///
  /// Example:
  /// ```dart
  /// final params = await nosmai.getEffectParameters();
  /// for (var param in params) {
  ///   print('Parameter: ${param.name}, Type: ${param.type}, Default: ${param.defaultValue}');
  /// }
  /// ```
  Future<List<FilterParameter>> getEffectParameters() async {
    _checkInitialized();
    try {
      final List<dynamic> parameters =
          await NosmaiFlutterPlatform.instance.getEffectParameters();
      return parameters
          .map((param) =>
              FilterParameter.fromMap(Map<String, dynamic>.from(param)))
          .toList();
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to get effect parameters',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to get effect parameters',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Get the current value of a specific parameter in the active effect
  ///
  /// Returns the current float value of the specified parameter.
  /// Throws [NosmaiError] if the parameter is not found or no effect is active.
  ///
  /// [parameterName] The name of the parameter to query
  ///
  /// Example:
  /// ```dart
  /// final intensity = await nosmai.getEffectParameterValue('intensity');
  /// print('Current intensity: $intensity');
  /// ```
  Future<double> getEffectParameterValue(String parameterName) async {
    _checkInitialized();
    try {
      final value = await NosmaiFlutterPlatform.instance
          .getEffectParameterValue(parameterName);
      return value;
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to get effect parameter value',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to get effect parameter value',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Set a float parameter value for the currently loaded effect
  ///
  /// Updates the specified parameter with a new value in real-time.
  /// The change is applied immediately to the active filter.
  ///
  /// Returns true if successful, false if:
  /// - Parameter is not found
  /// - No effect is currently active
  /// - Parameter type is not float
  /// - An error occurs during update
  ///
  /// [parameterName] The name of the parameter to set
  /// [value] The float value to set
  ///
  /// Example:
  /// ```dart
  /// // Set intensity to 0.8
  /// final success = await nosmai.setEffectParameter('intensity', 0.8);
  /// if (success) {
  ///   print('Parameter updated successfully');
  /// }
  /// ```
  Future<bool> setEffectParameter(String parameterName, double value) async {
    _checkInitialized();
    try {
      final success = await NosmaiFlutterPlatform.instance
          .setEffectParameter(parameterName, value);
      return success;
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set effect parameter',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to set effect parameter',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Set a string parameter value for the currently loaded effect
  ///
  /// Updates the specified string parameter with a new value in real-time.
  /// This is useful for text overlays, captions, and other string-based parameters.
  /// The change is applied immediately to the active filter.
  ///
  /// Returns true if successful, false if:
  /// - Parameter is not found
  /// - No effect is currently active
  /// - Parameter type is not string
  /// - An error occurs during update
  ///
  /// [parameterName] The name of the parameter to set
  /// [value] The string value to set
  ///
  /// Example:
  /// ```dart
  /// // Set header text to "Hello World"
  /// final success = await nosmai.setEffectParameterString('headerText', 'Hello World');
  /// if (success) {
  ///   print('Text updated successfully');
  /// }
  /// ```
  Future<bool> setEffectParameterString(
      String parameterName, String value) async {
    _checkInitialized();
    try {
      final success = await NosmaiFlutterPlatform.instance
          .setEffectParameterString(parameterName, value);
      return success;
    } on PlatformException catch (e) {
      throw NosmaiError.filter(
        type: _parseErrorType(e.code),
        message: e.message ?? 'Failed to set effect parameter string',
        details: e.details?.toString(),
      );
    } catch (e) {
      _errorController?.add(NosmaiError.general(
        type: NosmaiErrorType.platformError,
        message: 'Failed to set effect parameter string',
        details: e.toString(),
        originalError: e,
      ));
      rethrow;
    }
  }

  /// Dispose of stream controllers and clean up all resources
  void dispose() {
    if (_isDisposed) return;

    _isDisposed = true;

    unawaited(_performAsyncCleanup());

    _errorController?.close();
    _downloadProgressController?.close();
    _recordingProgressController?.close();
    _licenseStatusController?.close();
    _activeEffectsController?.close();

    _errorController = null;
    _downloadProgressController = null;
    _recordingProgressController = null;
    _licenseStatusController = null;
    _activeEffectsController = null;
  }

  /// Internal async cleanup
  Future<void> _performAsyncCleanup() async {
    final platform = NosmaiFlutterPlatform.instance;

    if (_isRecording) {
      try {
        await platform.stopRecording().timeout(const Duration(seconds: 5));
      } catch (_) {
        // Continue cleanup even if recording shutdown fails.
      }
    }

    if (_isProcessing) {
      try {
        await platform.stopProcessing().timeout(const Duration(seconds: 3));
      } catch (_) {
        // Continue cleanup even if processing shutdown fails.
      }
    }

    if (_isInitialized) {
      try {
        await platform.cleanup().timeout(const Duration(seconds: 5));
      } catch (_) {
        // Native cleanup is best-effort during dispose.
      }
    }

    _isInitialized = false;
    _isProcessing = false;
    _isRecording = false;
    _activeOperations.clear();
  }

  /// Check if SDK is initialized and not disposed
  void _checkInitialized() {
    if (_isDisposed) {
      throw NosmaiError.general(
        type: NosmaiErrorType.stateError,
        message: 'NosmaiFlutter instance has been disposed',
        details:
            'Call NosmaiFlutter.initialize() again to reinitialize the SDK',
      );
    }
    if (!_isInitialized) {
      throw NosmaiError.general(
        type: NosmaiErrorType.sdkNotInitialized,
        message: 'NosmaiFlutter must be initialized before use',
        details: 'Call NosmaiFlutter.initialize() first to initialize the SDK',
      );
    }
  }

  /// Internal helper to track async operations
  Future<T> _trackOperation<T>(Future<T> operation) {
    if (_isDisposed) {
      return Future.error(
          StateError('Cannot perform operation on disposed instance'));
    }

    _activeOperations.add(operation);

    return operation.whenComplete(() {
      _activeOperations.remove(operation);
    });
  }

  /// Helper function to parse error type from platform error code
  NosmaiErrorType _parseErrorType(String code) {
    switch (code.toUpperCase()) {
      case 'INVALID_LICENSE':
      case 'LICENSE_INVALID':
        return NosmaiErrorType.invalidLicense;
      case 'LICENSE_EXPIRED':
        return NosmaiErrorType.licenseExpired;
      case 'CAMERA_PERMISSION_DENIED':
        return NosmaiErrorType.cameraPermissionDenied;
      case 'CAMERA_UNAVAILABLE':
        return NosmaiErrorType.cameraUnavailable;
      case 'CAMERA_CONFIG_ERROR':
      case 'CAMERA_CONFIGURATION_FAILED':
        return NosmaiErrorType.cameraConfigurationFailed;
      case 'CAMERA_SWITCH_ERROR':
      case 'CAMERA_SWITCH_FAILED':
        return NosmaiErrorType.cameraSwitchFailed;
      case 'FILTER_NOT_FOUND':
        return NosmaiErrorType.filterNotFound;
      case 'FILTER_LOAD_ERROR':
        return NosmaiErrorType.filterLoadFailed;
      case 'FILTER_DOWNLOAD_ERROR':
      case 'DOWNLOAD_ERROR':
      case 'DOWNLOAD_PATH_ERROR':
      case 'DOWNLOAD_PATH_MISSING':
      case 'DOWNLOAD_UNKNOWN_ERROR':
        return NosmaiErrorType.filterDownloadFailed;
      case 'RECORDING_PERMISSION_DENIED':
        return NosmaiErrorType.recordingPermissionDenied;
      case 'RECORDING_STORAGE_FULL':
        return NosmaiErrorType.recordingStorageFull;
      case 'RECORDING_FAILED':
        return NosmaiErrorType.recordingWriteFailed;
      case 'RECORDING_IN_PROGRESS':
        return NosmaiErrorType.recordingInProgress;
      case 'NOT_INITIALIZED':
        return NosmaiErrorType.sdkNotInitialized;
      case 'OPERATION_TIMEOUT':
        return NosmaiErrorType.operationTimeout;
      case 'PLATFORM_ERROR':
        return NosmaiErrorType.platformError;
      case 'NETWORK_ERROR':
      case 'NETWORK_UNAVAILABLE':
        return NosmaiErrorType.networkError;
      case 'FILTER_DISCOVERY_FAILED':
      case 'FILTER_PROCESSING_FAILED':
      case 'CLOUD_FILTER_PROCESSING_FAILED':
      case 'CLOUD_FILTERS_NOT_AVAILABLE':
        return NosmaiErrorType.filterLoadFailed;
      case 'INVALID_FILTER_ID':
      case 'INVALID_EFFECT_PATH':
        return NosmaiErrorType.invalidParameter;
      case 'EFFECT_APPLY_FAILED':
      case 'REMOVE_FILTERS_ERROR':
        return NosmaiErrorType.filterLoadFailed;
      case 'INVALID_PARAMETER':
        return NosmaiErrorType.invalidParameter;
      default:
        return NosmaiErrorType.unknown;
    }
  }
}
