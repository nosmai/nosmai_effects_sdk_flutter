import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import '../types/enums.dart';
import '../types/models.dart';
import 'method_channel.dart';

/// The interface that implementations of nosmai_effects_sdk must implement.
abstract class NosmaiFlutterPlatform extends PlatformInterface {
  /// Constructs a NosmaiFlutterPlatform.
  NosmaiFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static NosmaiFlutterPlatform _instance = MethodChannelNosmaiFlutter();

  /// The default instance of [NosmaiFlutterPlatform] to use.
  static NosmaiFlutterPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NosmaiFlutterPlatform] when
  /// they register themselves.
  static set instance(NosmaiFlutterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Initialize the SDK with a license key
  Future<bool> initWithLicense(String licenseKey) {
    throw UnimplementedError('initWithLicense() has not been implemented.');
  }

  /// Configure camera with position and session preset
  Future<void> configureCamera({
    required NosmaiCameraPosition position,
    String? sessionPreset,
  }) {
    throw UnimplementedError('configureCamera() has not been implemented.');
  }

  /// Start video processing
  Future<void> startProcessing() {
    throw UnimplementedError('startProcessing() has not been implemented.');
  }

  /// Stop video processing
  Future<void> stopProcessing() {
    throw UnimplementedError('stopProcessing() has not been implemented.');
  }

  /// Switch camera between front and back
  Future<bool> switchCamera() {
    throw UnimplementedError('switchCamera() has not been implemented.');
  }

  /// Remove all applied filters (AR effects + regular filters)
  Future<void> removeAllFilters() {
    throw UnimplementedError('removeAllFilters() has not been implemented.');
  }

  /// Clear only the AR effect (keeps regular filter, beauty, background)
  Future<void> clearAREffect() {
    throw UnimplementedError('clearAREffect() has not been implemented.');
  }

  /// Clear only the regular filter (keeps AR effect, beauty, background)
  Future<void> clearFilter() {
    throw UnimplementedError('clearFilter() has not been implemented.');
  }

  /// Clear everything - AR effects, filters, beauty, background (nuclear option)
  Future<void> clearAll() {
    throw UnimplementedError('clearAll() has not been implemented.');
  }

  /// Set preview view (iOS only)
  Future<void> setPreviewView() {
    throw UnimplementedError('setPreviewView() has not been implemented.');
  }

  /// Cleanup resources
  Future<void> cleanup() {
    throw UnimplementedError('cleanup() has not been implemented.');
  }

  /// Pause camera hardware
  Future<bool> pauseCamera() {
    throw UnimplementedError('pauseCamera() has not been implemented.');
  }

  /// Resume camera hardware
  Future<bool> resumeCamera() {
    throw UnimplementedError('resumeCamera() has not been implemented.');
  }

  /// Get platform version
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  // New Advanced Features

  /// Apply any external `.nosmai` package through native manifest routing.
  Future<bool> applyEffect(String effectPath) {
    throw UnimplementedError('applyEffect() has not been implemented.');
  }

  /// Legacy alias for applying external `.nosmai` packages.
  Future<bool> applyFilter(String filterPath) {
    throw UnimplementedError('applyFilter() has not been implemented.');
  }

  /// Read the currently active `.nosmai` packages.
  Future<NosmaiActiveEffects> getActiveEffects() {
    throw UnimplementedError('getActiveEffects() has not been implemented.');
  }

  /// Active color-filter slot metadata, if available.
  Future<NosmaiFilter?> getActiveFilterInfo() {
    throw UnimplementedError('getActiveFilterInfo() has not been implemented.');
  }

  /// Active AR slot metadata. This may be an effect or beauty_effect.
  Future<NosmaiFilter?> getActiveEffectInfo() {
    throw UnimplementedError('getActiveEffectInfo() has not been implemented.');
  }

  /// Remove a specific external package using its manifest type.
  Future<bool> removeEffect(NosmaiFilter filter) {
    throw UnimplementedError('removeEffect() has not been implemented.');
  }

  /// Get cloud filters with optional pagination support
  ///
  /// [filterType] - Filter by type using [NosmaiCloudFilterType] enum (null = all types)
  /// [page] - Page number (null = fetch all pages for backward compatibility)
  /// [limit] - Items per page (default: 20)
  /// [fetchAllPages] - If true, fetches all pages (default: true for backward compatibility)
  ///
  /// Returns a Map containing:
  /// - 'filters': List of filter data
  /// - 'pagination': Pagination info (only when page is specified)
  Future<Map<String, dynamic>> getCloudFiltersWithOptions({
    NosmaiCloudFilterType? filterType,
    NosmaiCloudFilterVersion version = NosmaiCloudFilterVersion.v2,
    int? page,
    int? limit,
    bool fetchAllPages = true,
  }) {
    throw UnimplementedError(
        'getCloudFiltersWithOptions() has not been implemented.');
  }

  /// Get cloud filters (backward compatible - fetches all filters)
  Future<List<dynamic>> getCloudFilters() {
    throw UnimplementedError('getCloudFilters() has not been implemented.');
  }

  Future<Map<String, dynamic>> downloadCloudFilter(String filterId) {
    throw UnimplementedError('downloadCloudFilter() has not been implemented.');
  }

  /// Remove a downloaded cloud filter from local storage
  Future<bool> removeCloudFilter(String filterId) {
    throw UnimplementedError('removeCloudFilter() has not been implemented.');
  }

  /// Get production local filters from the manifest-based asset structure.
  Future<List<dynamic>> getLocalFilters({bool forceRefresh = false}) {
    throw UnimplementedError('getLocalFilters() has not been implemented.');
  }

  /// Get all production local filters grouped by filterType.
  Future<Map<String, List<dynamic>>> getAllLocalFilters(
      {bool forceRefresh = false}) {
    throw UnimplementedError('getAllLocalFilters() has not been implemented.');
  }

  /// Development-only debug discovery for bundled loose .nosmai filters.
  Future<List<dynamic>> getDebugFilters({NosmaiLocalFilterType? type}) {
    throw UnimplementedError('getDebugFilters() has not been implemented.');
  }

  /// Get local effects (AR effects, masks, etc.) with filterType "effect"
  Future<List<dynamic>> getLocalEffects() {
    throw UnimplementedError('getLocalEffects() has not been implemented.');
  }

  /// Get local backgrounds with filterType "background"
  Future<List<dynamic>> getLocalBackgrounds() {
    throw UnimplementedError('getLocalBackgrounds() has not been implemented.');
  }

  /// Get local beauty effects with filterType "beauty_effect"
  Future<List<dynamic>> getLocalBeautyEffects() {
    throw UnimplementedError(
        'getLocalBeautyEffects() has not been implemented.');
  }

  /// Clear the local filters cache
  Future<bool> clearLocalFiltersCache() {
    throw UnimplementedError(
        'clearLocalFiltersCache() has not been implemented.');
  }

  /// Validate local filters and return detailed error/warning information
  Future<List<dynamic>> validateLocalFilters() {
    throw UnimplementedError(
        'validateLocalFilters() has not been implemented.');
  }

  // Recording Features
  Future<bool> startRecording() {
    throw UnimplementedError('startRecording() has not been implemented.');
  }

  Future<Map<String, dynamic>> stopRecording() {
    throw UnimplementedError('stopRecording() has not been implemented.');
  }

  Future<bool> isRecording() {
    throw UnimplementedError('isRecording() has not been implemented.');
  }

  Future<double> getCurrentRecordingDuration() {
    throw UnimplementedError(
        'getCurrentRecordingDuration() has not been implemented.');
  }

  /// Capture photo with applied filters
  Future<Map<String, dynamic>> capturePhoto() {
    throw UnimplementedError('capturePhoto() has not been implemented.');
  }

  /// Save image data to device gallery
  Future<Map<String, dynamic>> saveImageToGallery(List<int> imageData,
      {String? name}) {
    throw UnimplementedError('saveImageToGallery() has not been implemented.');
  }

  /// Save video file to device gallery
  Future<Map<String, dynamic>> saveVideoToGallery(String videoPath,
      {String? name}) {
    throw UnimplementedError('saveVideoToGallery() has not been implemented.');
  }

  /// Clear native filter cache
  Future<void> clearFilterCache() {
    throw UnimplementedError('clearFilterCache() has not been implemented.');
  }

  /// Detach camera from current view (for navigation cleanup)
  Future<void> detachCameraView() {
    throw UnimplementedError('detachCameraView() has not been implemented.');
  }

  /// Reinitialize the preview (useful for navigation recovery)
  Future<void> reinitializePreview() {
    throw UnimplementedError('reinitializePreview() has not been implemented.');
  }

  // Built-in Filter Methods
  Future<void> applyBrightnessFilter(double brightness) {
    throw UnimplementedError(
        'applyBrightnessFilter() has not been implemented.');
  }

  Future<void> applyContrastFilter(double contrast) {
    throw UnimplementedError('applyContrastFilter() has not been implemented.');
  }

  Future<void> applyRGBFilter(
      {required double red, required double green, required double blue}) {
    throw UnimplementedError('applyRGBFilter() has not been implemented.');
  }

  Future<void> applySkinSmoothing(double level) {
    throw UnimplementedError('applySkinSmoothing() has not been implemented.');
  }

  Future<void> applySkinWhitening(double level) {
    throw UnimplementedError('applySkinWhitening() has not been implemented.');
  }

  Future<void> applySharpening(double level) {
    throw UnimplementedError('applySharpening() has not been implemented.');
  }

  Future<void> applyTeethWhitening(double intensity) {
    throw UnimplementedError('applyTeethWhitening() has not been implemented.');
  }

  Future<void> applyGrayscaleFilter() {
    throw UnimplementedError(
        'applyGrayscaleFilter() has not been implemented.');
  }

  Future<void> applyHue(double hueAngle) {
    throw UnimplementedError('applyHue() has not been implemented.');
  }

  Future<void> applyWhiteBalance(
      {required double temperature, required double tint}) {
    throw UnimplementedError('applyWhiteBalance() has not been implemented.');
  }

  Future<void> adjustHSB(
      {required double hue,
      required double saturation,
      required double brightness}) {
    throw UnimplementedError('adjustHSB() has not been implemented.');
  }

  Future<void> removeBuiltInFilters() {
    throw UnimplementedError(
        'removeBuiltInFilters() has not been implemented.');
  }

  Future<void> removeBuiltInFilterByName(String filterName) {
    throw UnimplementedError(
        'removeBuiltInFilterByName() has not been implemented.');
  }

  // License feature availability methods
  Future<bool> isBeautyEffectEnabled() {
    throw UnimplementedError(
        'isBeautyEffectEnabled() has not been implemented.');
  }

  Future<bool> isCloudFilterEnabled() {
    throw UnimplementedError(
        'isCloudFilterEnabled() has not been implemented.');
  }

  // Flash and Torch Methods
  Future<bool> hasFlash() {
    throw UnimplementedError('hasFlash() has not been implemented.');
  }

  Future<bool> hasTorch() {
    throw UnimplementedError('hasTorch() has not been implemented.');
  }

  Future<bool> setFlashMode(NosmaiFlashMode flashMode) {
    throw UnimplementedError('setFlashMode() has not been implemented.');
  }

  Future<bool> setTorchMode(NosmaiTorchMode torchMode) {
    throw UnimplementedError('setTorchMode() has not been implemented.');
  }

  Future<NosmaiFlashMode> getFlashMode() {
    throw UnimplementedError('getFlashMode() has not been implemented.');
  }

  Future<NosmaiTorchMode> getTorchMode() {
    throw UnimplementedError('getTorchMode() has not been implemented.');
  }

  // Effect Parameter Control Methods
  /// Get all available parameters for the currently loaded effect
  Future<List<dynamic>> getEffectParameters() {
    throw UnimplementedError('getEffectParameters() has not been implemented.');
  }

  /// Get the current value of a specific parameter
  Future<double> getEffectParameterValue(String parameterName) {
    throw UnimplementedError(
        'getEffectParameterValue() has not been implemented.');
  }

  /// Set a float parameter value for the currently loaded effect
  Future<bool> setEffectParameter(String parameterName, double value) {
    throw UnimplementedError('setEffectParameter() has not been implemented.');
  }

  /// Set a string parameter value for the currently loaded effect
  Future<bool> setEffectParameterString(String parameterName, String value) {
    throw UnimplementedError(
        'setEffectParameterString() has not been implemented.');
  }

  // Android Texture-based preview helpers (no-ops on iOS)
  /// Create a native SurfaceTexture and return its textureId (Android only)
  Future<int?> createPreviewTexture({double? width, double? height}) {
    throw UnimplementedError(
        'createPreviewTexture() has not been implemented.');
  }

  /// Bind the Surface from the given textureId to the SDK renderer (Android only)
  Future<bool> setRenderSurface(int textureId,
      {required double width, required double height}) {
    throw UnimplementedError('setRenderSurface() has not been implemented.');
  }

  /// Clear the current render surface and release the texture (Android only)
  Future<void> clearRenderSurface(int textureId) {
    throw UnimplementedError('clearRenderSurface() has not been implemented.');
  }

  // Background Segmentation Methods

  /// Check if advanced filters (background segmentation) are enabled in the license
  Future<bool> isAdvancedFiltersEnabled() {
    throw UnimplementedError(
        'isAdvancedFiltersEnabled() has not been implemented.');
  }

  /// Apply background segmentation with the given configuration
  Future<bool> setBackgroundSegmentation(
      NosmaiBackgroundSegmentationConfig config) {
    throw UnimplementedError(
        'setBackgroundSegmentation() has not been implemented.');
  }

  /// Clear/disable background segmentation.
  Future<bool> clearBackgroundSegmentation() {
    throw UnimplementedError(
        'clearBackgroundSegmentation() has not been implemented.');
  }

  // Lipstick Methods

  /// Apply lipstick with style
  Future<bool> applyLipstick({
    required NosmaiLipstickStyle style,
    double intensity = 0.5,
  }) {
    throw UnimplementedError('applyLipstick() has not been implemented.');
  }

  /// Set lipstick intensity
  Future<void> setLipstickIntensity(double intensity) {
    throw UnimplementedError(
        'setLipstickIntensity() has not been implemented.');
  }

  /// Remove lipstick effect
  Future<void> removeLipstick() {
    throw UnimplementedError('removeLipstick() has not been implemented.');
  }

  /// Check if lipstick is currently applied
  Future<bool> hasLipstick() {
    throw UnimplementedError('hasLipstick() has not been implemented.');
  }

  /// Get available lipstick colors
  Future<List<Map<String, dynamic>>> getLipstickColors() {
    throw UnimplementedError('getLipstickColors() has not been implemented.');
  }

  // Eyeshadow Methods

  /// Apply eyeshadow with style
  Future<bool> applyEyeshadow({
    required NosmaiEyeshadowStyle style,
    double intensity = 0.5,
  }) {
    throw UnimplementedError('applyEyeshadow() has not been implemented.');
  }

  /// Set eyeshadow intensity
  Future<void> setEyeshadowIntensity(double intensity) {
    throw UnimplementedError(
        'setEyeshadowIntensity() has not been implemented.');
  }

  /// Remove eyeshadow effect
  Future<void> removeEyeshadow() {
    throw UnimplementedError('removeEyeshadow() has not been implemented.');
  }

  /// Check if eyeshadow is currently applied
  Future<bool> hasEyeshadow() {
    throw UnimplementedError('hasEyeshadow() has not been implemented.');
  }

  // Blusher Methods

  /// Apply blusher with style
  Future<bool> applyBlusher({
    required NosmaiBlusherStyle style,
    double intensity = 0.5,
  }) {
    throw UnimplementedError('applyBlusher() has not been implemented.');
  }

  /// Set blusher intensity
  Future<void> setBlusherIntensity(double intensity) {
    throw UnimplementedError('setBlusherIntensity() has not been implemented.');
  }

  /// Remove blusher effect
  Future<void> removeBlusher() {
    throw UnimplementedError('removeBlusher() has not been implemented.');
  }

  /// Check if blusher is currently applied
  Future<bool> hasBlusher() {
    throw UnimplementedError('hasBlusher() has not been implemented.');
  }

  // Eyelash Methods

  /// Apply eyelash with style
  Future<bool> applyEyelash({
    required NosmaiEyelashStyle style,
    double intensity = 0.5,
  }) {
    throw UnimplementedError('applyEyelash() has not been implemented.');
  }

  /// Set eyelash intensity
  Future<void> setEyelashIntensity(double intensity) {
    throw UnimplementedError('setEyelashIntensity() has not been implemented.');
  }

  /// Remove eyelash effect
  Future<void> removeEyelash() {
    throw UnimplementedError('removeEyelash() has not been implemented.');
  }

  /// Check if eyelash is currently applied
  Future<bool> hasEyelash() {
    throw UnimplementedError('hasEyelash() has not been implemented.');
  }

  // Eyebrow Methods

  /// Apply eyebrow with style
  Future<bool> applyEyebrow({
    required NosmaiEyebrowStyle style,
    double intensity = 0.5,
  }) {
    throw UnimplementedError('applyEyebrow() has not been implemented.');
  }

  /// Set eyebrow intensity
  Future<void> setEyebrowIntensity(double intensity) {
    throw UnimplementedError('setEyebrowIntensity() has not been implemented.');
  }

  /// Remove eyebrow effect
  Future<void> removeEyebrow() {
    throw UnimplementedError('removeEyebrow() has not been implemented.');
  }

  /// Check if eyebrow is currently applied
  Future<bool> hasEyebrow() {
    throw UnimplementedError('hasEyebrow() has not been implemented.');
  }

  // Face Morphing Methods

  /// Set face slim level (0.0 - 1.0)
  Future<void> setFaceSlimLevel(double level) {
    throw UnimplementedError('setFaceSlimLevel() has not been implemented.');
  }

  /// Set eye size level (0.0 - 1.0)
  Future<void> setEyeSizeLevel(double level) {
    throw UnimplementedError('setEyeSizeLevel() has not been implemented.');
  }

  /// Set nose slim level (0.0 - 1.0)
  Future<void> setNoseSlimLevel(double level) {
    throw UnimplementedError('setNoseSlimLevel() has not been implemented.');
  }

  /// Remove all face morphing effects
  Future<void> removeAllMorphing() {
    throw UnimplementedError('removeAllMorphing() has not been implemented.');
  }

  // Eye Coloring Methods

  /// Set eye color with RGB values (0.0 - 1.0)
  Future<bool> setEyeColor({
    required double r,
    required double g,
    required double b,
    double intensity = 0.5,
  }) {
    throw UnimplementedError('setEyeColor() has not been implemented.');
  }

  /// Set eye color intensity (0.0 - 1.0)
  Future<void> setEyeColorIntensity(double intensity) {
    throw UnimplementedError(
        'setEyeColorIntensity() has not been implemented.');
  }

  /// Remove eye coloring effect
  Future<void> removeEyeColoring() {
    throw UnimplementedError('removeEyeColoring() has not been implemented.');
  }

  // Utility Methods

  /// Remove all makeup (lipstick, eyeshadow, blusher, eyelash, eyebrow)
  Future<void> removeAllMakeup() {
    throw UnimplementedError('removeAllMakeup() has not been implemented.');
  }

  /// Remove all beauty effects (makeup + morphing + eye coloring)
  Future<void> removeAllBeautyEffects() {
    throw UnimplementedError(
        'removeAllBeautyEffects() has not been implemented.');
  }
}
