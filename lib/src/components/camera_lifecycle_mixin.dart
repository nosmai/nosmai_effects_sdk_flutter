import 'package:flutter/widgets.dart';
import '../../nosmai_effects_sdk.dart';

/// Simple mixin for managing Nosmai camera lifecycle in Flutter screens
///
/// This mixin handles proper camera initialization and cleanup.
/// Use this mixin in your camera screen's State class to ensure smooth camera operations.
///
/// Example usage:
/// ```dart
/// class CameraScreenState extends State<CameraScreen>
///     with NosmaiCameraLifecycleMixin {
///
///   @override
///   Widget build(BuildContext context) {
///     return Scaffold(
///       appBar: AppBar(
///         leading: IconButton(
///           icon: Icon(Icons.arrow_back),
///           onPressed: () async {
///             await cleanupBeforeNavigation();
///             Navigator.pop(context);
///           },
///         ),
///       ),
///       body: NosmaiCameraPreview(
///         onInitialized: onCameraInitialized,
///         onError: onCameraError,
///       ),
///     );
///   }
/// }
/// ```
mixin NosmaiCameraLifecycleMixin<T extends StatefulWidget> on State<T> {
  late final NosmaiFlutter _nosmaiFlutter;
  bool _isScreenActive = true;

  @override
  void initState() {
    super.initState();
    _nosmaiFlutter = NosmaiFlutter.instance;
    _isScreenActive = true;
  }

  @override
  void dispose() {
    // NosmaiCameraPreview's native PlatformView owns final disposal. Starting
    // another async global cleanup here can stop a newly-created preview.
    _isScreenActive = false;
    super.dispose();
  }

  /// Called when the camera is successfully initialized
  void onCameraInitialized() {}

  /// Called when the camera encounters an error
  void onCameraError(String error) {}

  /// Call this method before navigating away from the camera screen
  Future<void> cleanupBeforeNavigation() async {
    if (!_isScreenActive) return;

    _isScreenActive = false;

    try {
      if (_nosmaiFlutter.isInitialized) {
        if (_nosmaiFlutter.isProcessing) {
          await _nosmaiFlutter.stopProcessing();
        }
        await _nosmaiFlutter.detachCameraView();
      }
    } catch (e) {
      // Ignore cleanup errors
    }
  }

  /// Get current camera state
  bool get isScreenActive => _isScreenActive;
}
