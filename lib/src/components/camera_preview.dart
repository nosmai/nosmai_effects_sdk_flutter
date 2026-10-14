import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../nosmai_effects_sdk.dart';
import '../platform/method_channel.dart';
import '../platform/platform_interface.dart';

/// Normalized details for a tap inside [NosmaiCameraPreview].
class NosmaiGameTapDetails {
  const NosmaiGameTapDetails({
    required this.normalizedX,
    required this.normalizedY,
    required this.localPosition,
    required this.previewSize,
  });

  /// Horizontal preview position from 0 (left) to 1 (right).
  final double normalizedX;

  /// Vertical preview position from 0 (top) to 1 (bottom).
  final double normalizedY;

  /// Tap position in logical pixels relative to the preview.
  final Offset localPosition;

  /// Logical size of the tappable preview.
  final Size previewSize;
}

/// Overrides automatic game-tap forwarding for a camera preview.
typedef NosmaiGameTapCallback = FutureOr<void> Function(
    NosmaiGameTapDetails tap);

class NosmaiCameraPreview extends StatefulWidget {
  const NosmaiCameraPreview({
    super.key,
    this.width,
    this.height,
    this.onInitialized,
    this.onError,
    this.controller,
    this.enableGameTapHandling = true,
    this.onGameTap,
  });

  final double? width;
  final double? height;
  final VoidCallback? onInitialized;
  final Function(String error)? onError;
  final NosmaiCameraPreviewController? controller;

  /// Whether this preview should capture taps for interactive game packages.
  ///
  /// Enabled by default. Set to false when the host needs the native preview to
  /// receive touches directly.
  final bool enableGameTapHandling;

  /// Optional custom game-tap handler.
  ///
  /// When null, the preview automatically checks [NosmaiFlutter.isGameReady]
  /// and forwards normalized coordinates through [NosmaiFlutter.sendGameTap].
  /// When supplied, only this callback runs; the host decides whether and when
  /// to forward the tap.
  final NosmaiGameTapCallback? onGameTap;

  @override
  State<NosmaiCameraPreview> createState() => _NosmaiCameraPreviewState();
}

class NosmaiCameraPreviewController {
  _NosmaiCameraPreviewState? _state;

  void _attach(_NosmaiCameraPreviewState state) {
    _state = state;
  }

  void _detach() {
    _state = null;
  }

  /// Manually reinitialize the camera preview
  Future<void> reinitialize() async {
    await _state?.reinitialize();
  }

  /// Check if camera is currently initializing
  bool get isInitializing => _state?._isInitializing ?? false;

  /// Check if camera is initialized
  bool get isInitialized => _state?._isInitialized ?? false;

  /// Get current error if any
  String? get currentError => _state?._initError;
}

class _NosmaiCameraPreviewState extends State<NosmaiCameraPreview>
    with WidgetsBindingObserver {
  bool _isInitializing = false;
  bool _isInitialized = false;
  String? _initError;
  late final NosmaiFlutter _nosmaiFlutter;
  static int _viewCounter = 0;
  late final String _viewKey;
  bool _notifiedInitialized = false;
  bool _iosPreviewStartRequested = false;
  Completer<void>? _readyCompleter;
  int? _androidTextureId;
  int _androidCreationGeneration = 0;
  bool _androidPreviewVisible = false;
  bool _androidPaused = false;
  Timer? _androidReadyTimer;

  Future<void> _releaseAndroidTexture(int id) async {
    try {
      await NosmaiFlutterPlatform.instance.clearRenderSurface(id);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'nosmai_effects_sdk',
          context: ErrorDescription('while releasing a camera preview texture'),
        ),
      );
    }
  }

  void _setAndroidPreviewError(String message) {
    if (!mounted) return;
    _androidReadyTimer?.cancel();
    final textureId = _androidTextureId;
    _androidTextureId = null;
    if (textureId != null) unawaited(_releaseAndroidTexture(textureId));
    final ready = _readyCompleter;
    _readyCompleter = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError(message));
    }
    setState(() {
      _androidPreviewVisible = false;
      _isInitializing = false;
      _isInitialized = false;
      _initError = message;
    });
    widget.onError?.call(message);
  }

  void _handleNativePreviewState(int textureId, bool visible, String? error) {
    if (!mounted || textureId != _androidTextureId) return;
    if (error != null) {
      _setAndroidPreviewError(error);
      return;
    }
    setState(() {
      _androidPreviewVisible = visible && !_androidPaused;
      if (_androidPreviewVisible) {
        _androidReadyTimer?.cancel();
        _initError = null;
      }
    });
  }

  Future<void> _initializeAndroidTexture() async {
    final generation = ++_androidCreationGeneration;
    int? allocated;
    try {
      if (mounted) {
        setState(() {
          _isInitializing = true;
          _isInitialized = false;
          _androidPreviewVisible = false;
          _initError = null;
        });
      }
      final platform = NosmaiFlutterPlatform.instance;
      allocated = await platform.createPreviewTexture(width: 720, height: 1280);
      if (allocated == null) {
        throw StateError('Camera texture allocation failed.');
      }
      if (!mounted || generation != _androidCreationGeneration) {
        await _releaseAndroidTexture(allocated);
        return;
      }
      setState(() {
        _androidTextureId = allocated;
      });
      if (_androidPaused) await _nosmaiFlutter.pauseCamera();
      final bound = await platform.setRenderSurface(
        allocated,
        width: 720,
        height: 1280,
      );
      if (!mounted || generation != _androidCreationGeneration) return;
      if (!bound) throw StateError('Camera output could not be attached.');
      // Native creates the same camera/filter pipeline and defers camera opening
      // until its GPU sink is bound. Readiness follows a successful output swap.
      if (!_notifiedInitialized && !_androidPaused) {
        _androidReadyTimer = Timer(const Duration(seconds: 12), () {
          _setAndroidPreviewError('Camera preview did not become ready.');
        });
      }
    } catch (error) {
      if (allocated != null &&
          mounted &&
          generation == _androidCreationGeneration) {
        await _releaseAndroidTexture(allocated);
        _androidTextureId = null;
      }
      if (!mounted || generation != _androidCreationGeneration) return;
      _setAndroidPreviewError('Failed to start camera preview: $error');
    }
  }

  void _handleNativeCameraReady() {
    if (!mounted || _notifiedInitialized) return;
    if (defaultTargetPlatform == TargetPlatform.android &&
        (!_androidPreviewVisible || _androidPaused)) {
      return;
    }
    _androidReadyTimer?.cancel();
    _notifiedInitialized = true;
    final readyCompleter = _readyCompleter;
    _readyCompleter = null;
    if (readyCompleter != null && !readyCompleter.isCompleted) {
      readyCompleter.complete();
    }
    setState(() {
      _isInitialized = true;
      _isInitializing = false;
      _initError = null;
    });
    widget.onInitialized?.call();
  }

  @override
  void initState() {
    super.initState();
    _nosmaiFlutter = NosmaiFlutter.instance;
    WidgetsBinding.instance.addObserver(this);

    // Create unique view key for this instance
    _viewKey = 'nosmai_camera_${++_viewCounter}';

    // Attach controller if provided
    widget.controller?._attach(this);

    if (defaultTargetPlatform == TargetPlatform.android) {
      CameraStateNotifier.instance.addReadyCallback(_handleNativeCameraReady);
      CameraStateNotifier.instance.addPreviewStateCallback(
        _handleNativePreviewState,
      );
      _androidPaused =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused;
      _isInitializing = true;
      _initError = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_initializeAndroidTexture());
      });
    } else {
      _isInitializing = true;
      _isInitialized = false;
    }
  }

  Future<void> _handleIOSPlatformViewCreated(int viewId) async {
    if (!mounted || _iosPreviewStartRequested) return;
    _iosPreviewStartRequested = true;

    try {
      // The native preview must exist before attaching the SDK render surface.
      await _nosmaiFlutter.reinitializePreview();
      if (!_nosmaiFlutter.isProcessing) {
        await _nosmaiFlutter.startProcessing();
      }

      if (!mounted) return;
      setState(() {
        _isInitialized = true;
        _isInitializing = false;
        _initError = null;
      });
      widget.onInitialized?.call();
    } catch (error) {
      _iosPreviewStartRequested = false;
      if (!mounted) return;

      final message = 'Failed to start camera preview: $error';
      setState(() {
        _isInitialized = false;
        _isInitializing = false;
        _initError = message;
      });
      widget.onError?.call(message);
    }
  }

  @override
  void dispose() {
    _iosPreviewStartRequested = false;
    _androidCreationGeneration++;
    _androidReadyTimer?.cancel();
    final textureId = _androidTextureId;
    _androidTextureId = null;
    if (textureId != null) unawaited(_releaseAndroidTexture(textureId));
    final readyCompleter = _readyCompleter;
    _readyCompleter = null;
    if (readyCompleter != null && !readyCompleter.isCompleted) {
      readyCompleter.completeError(
        StateError('Camera preview was disposed before becoming ready.'),
      );
    }
    widget.controller?._detach();
    if (defaultTargetPlatform == TargetPlatform.android) {
      CameraStateNotifier.instance.removeReadyCallback(
        _handleNativeCameraReady,
      );
      CameraStateNotifier.instance.removePreviewStateCallback(
        _handleNativePreviewState,
      );
    }

    WidgetsBinding.instance.removeObserver(this);

    super.dispose();
  }

  @override
  void didUpdateWidget(covariant NosmaiCameraPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach();
      widget.controller?._attach(this);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (state == AppLifecycleState.paused) {
        _androidPaused = true;
        _androidReadyTimer?.cancel();
        if (mounted) {
          setState(() {
            _androidPreviewVisible = false;
          });
        }
        if (_androidTextureId != null) unawaited(_pauseCamera());
      } else if (state == AppLifecycleState.resumed) {
        _androidPaused = false;
        if (_androidTextureId != null) unawaited(_resumeCamera());
      }
      return;
    }
    if (!_isInitialized) return;

    switch (state) {
      case AppLifecycleState.paused:
        // App is going to background - stop processing but keep SDK initialized
        _pauseCamera();
        break;
      case AppLifecycleState.resumed:
        // App is back to foreground - resume processing
        _resumeCamera();
        break;
      case AppLifecycleState.detached:
        // Native output ownership/widget disposal owns final camera cleanup.
        break;
      default:
        break;
    }
  }

  Future<void> _pauseCamera() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Retain the graph and Flutter texture; native pauses camera/GL lifecycle.
        await _nosmaiFlutter.pauseCamera();
      } else if (_isInitialized && _nosmaiFlutter.isProcessing) {
        await _nosmaiFlutter.stopProcessing();
      }
    } catch (e) {
      // Ignore camera pause errors
    }
  }

  Future<void> _resumeCamera() async {
    try {
      if (!mounted) return;

      if (kDebugMode) {
        debugPrint('App Resumed: Resuming camera preview...');
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        final resumed = await _nosmaiFlutter.resumeCamera();
        if (!resumed && !_nosmaiFlutter.isProcessing) {
          await _nosmaiFlutter.startProcessing();
        }
        // The output counter/visibility event reveals the resumed frame.
        return;
      } else {
        await _nosmaiFlutter.reinitializePreview();

        if (!_nosmaiFlutter.isProcessing) {
          await _nosmaiFlutter.startProcessing();
        }
      }

      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isInitializing = false;
          _initError = null;
        });
      }
      if (kDebugMode) {
        debugPrint('App Resumed: Camera is ready again.');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error on resuming camera: $e');
      }
      if (mounted) {
        setState(() {
          _initError = "Failed to resume camera. Please try again.";
        });
        widget.onError?.call(_initError!);
      }
    }
  }

  Future<void> _cleanupCamera() async {
    try {
      // Stop processing if active
      if (_nosmaiFlutter.isProcessing) {
        await _nosmaiFlutter.stopProcessing();
      }

      // Detach camera view
      await _nosmaiFlutter.detachCameraView();

      // Brief delay for cleanup
      await Future.delayed(const Duration(milliseconds: 200));

      // Reset state if mounted
      if (mounted) {
        setState(() {
          _isInitialized = false;
          _isInitializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitialized = false;
          _isInitializing = false;
        });
      }
    }
  }

  /// Manually reinitialize the camera (useful for error recovery)
  Future<void> reinitialize() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (_isInitializing) return;

      _notifiedInitialized = false;
      _androidReadyTimer?.cancel();
      final ready = Completer<void>();
      // Disposal can complete this before native reinitialization returns.
      ready.future.ignore();
      _readyCompleter = ready;
      setState(() {
        _isInitialized = false;
        _isInitializing = true;
        _androidPreviewVisible = false;
        _initError = null;
      });

      try {
        if (_androidTextureId == null) {
          await _initializeAndroidTexture();
        } else {
          await _nosmaiFlutter.reinitializePreview();
        }
        await ready.future.timeout(const Duration(seconds: 12));
      } catch (error) {
        if (identical(_readyCompleter, ready)) {
          _readyCompleter = null;
        }
        if (!mounted) return;
        final message = 'Failed to reinitialize camera preview: $error';
        setState(() {
          _isInitialized = false;
          _isInitializing = false;
          _initError = message;
        });
        widget.onError?.call(message);
      }
    } else {
      await _cleanupCamera();
      await Future.delayed(const Duration(milliseconds: 250));
      // Force reset to initialized state (camera is pre-warmed) on iOS
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isInitializing = false;
          _initError = null;
        });
      }
      widget.onInitialized?.call();
    }
  }

  Future<void> _handleGameTap(TapUpDetails details, Size previewSize) async {
    if (!widget.enableGameTapHandling ||
        previewSize.width <= 0 ||
        previewSize.height <= 0) {
      return;
    }

    final tap = NosmaiGameTapDetails(
      normalizedX: (details.localPosition.dx / previewSize.width)
          .clamp(0.0, 1.0)
          .toDouble(),
      normalizedY: (details.localPosition.dy / previewSize.height)
          .clamp(0.0, 1.0)
          .toDouble(),
      localPosition: details.localPosition,
      previewSize: previewSize,
    );

    try {
      final callback = widget.onGameTap;
      if (callback != null) {
        await callback(tap);
        return;
      }

      if (await _nosmaiFlutter.isGameReady()) {
        await _nosmaiFlutter.sendGameTap(tap.normalizedX, tap.normalizedY);
      }
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'nosmai_effects_sdk',
          context: ErrorDescription('while handling a camera game tap'),
        ),
      );
    }
  }

  Widget _buildPreviewWithGameTapHandling({
    required Widget preview,
    required Size previewSize,
  }) {
    if (!widget.enableGameTapHandling) {
      return preview;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        preview,
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTapUp: (details) => unawaited(_handleGameTap(details, previewSize)),
          child: const SizedBox.expand(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show error state
    if (_initError != null) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: const Color(0xFF000000),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                'Camera Error',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _initError!,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: reinitialize,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      const aspectRatio = 9.0 / 16.0;
      return LayoutBuilder(
        builder: (context, constraints) {
          final resolvedSize = _resolveAndroidPreviewSize(
            context,
            constraints,
            aspectRatio,
          );

          return Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: resolvedSize.width,
              height: resolvedSize.height,
              child: ClipRect(
                child: _buildPreviewWithGameTapHandling(
                  previewSize: resolvedSize,
                  preview: RepaintBoundary(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_androidTextureId != null)
                          // Match the Y transform formerly applied by the native
                          // view's display quad. This affects presentation only;
                          // camera facing, recording and game coordinates retain
                          // their SDK contracts.
                          Transform.flip(
                            flipY: true,
                            child: Texture(textureId: _androidTextureId!),
                          ),
                        if (!_androidPreviewVisible)
                          const ColoredBox(
                            key: ValueKey('nosmai-preview-cover'),
                            color: Colors.black,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    final mediaQuery = MediaQuery.of(context);
    final padding = mediaQuery.padding;

    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaSize = mediaQuery.size;
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : mediaSize.width;
        final maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : mediaSize.height;
        final previewWidth =
            (widget.width ?? maxWidth).clamp(0.0, maxWidth).toDouble();
        final previewHeight =
            (widget.height ?? maxHeight).clamp(0.0, maxHeight).toDouble();

        return SizedBox(
          width: previewWidth,
          height: previewHeight,
          child: ClipRect(
            child: _buildPreviewWithGameTapHandling(
              previewSize: Size(previewWidth, previewHeight),
              preview: UiKitView(
                key: ValueKey(_viewKey),
                viewType: 'nosmai_camera_preview',
                layoutDirection: TextDirection.ltr,
                onPlatformViewCreated: _handleIOSPlatformViewCreated,
                creationParams: <String, dynamic>{
                  'width': previewWidth,
                  'height': previewHeight,
                  'deviceType': _getDeviceType(),
                  'safeAreaTop': padding.top,
                  'safeAreaBottom': padding.bottom,
                },
                creationParamsCodec: const StandardMessageCodec(),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Get device type information for native side
  String _getDeviceType() {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final screenWidth = screenSize.width;
    final screenHeight = screenSize.height;
    final padding = mediaQuery.padding;

    // Include safe area information
    final hasNotch =
        padding.top > 24; // Devices with notch typically have padding > 24
    final hasBottomSafeArea = padding.bottom > 0;

    // Determine device type based on screen dimensions
    String deviceType;
    if (screenWidth >= 1024 || screenHeight >= 1024) {
      deviceType = 'tablet';
    } else if (screenWidth >= 768 || screenHeight >= 768) {
      deviceType = 'large_phone';
    } else {
      deviceType = 'phone';
    }

    // Add safe area info for iOS layout
    if (hasNotch) {
      deviceType += '_notch';
    }
    if (hasBottomSafeArea) {
      deviceType += '_bottom';
    }

    return deviceType;
  }

  Size _resolveAndroidPreviewSize(
    BuildContext context,
    BoxConstraints constraints,
    double aspectRatio,
  ) {
    final mediaSize = MediaQuery.of(context).size;

    double maxWidth = constraints.maxWidth;
    if (!maxWidth.isFinite || maxWidth <= 0) {
      maxWidth = mediaSize.width;
    }

    double maxHeight = constraints.maxHeight;
    if (!maxHeight.isFinite || maxHeight <= 0) {
      maxHeight = mediaSize.height;
    }

    if (widget.width != null && widget.height != null) {
      final width = widget.width!.clamp(0.0, maxWidth);
      final height = widget.height!.clamp(0.0, maxHeight);
      return Size(width.toDouble(), height.toDouble());
    }

    double width;
    double height;

    if (widget.width != null) {
      width = widget.width!.clamp(0.0, maxWidth).toDouble();
      height = width / aspectRatio;
      if (height > maxHeight) {
        height = maxHeight;
        width = height * aspectRatio;
      }
      return Size(width, height);
    }

    if (widget.height != null) {
      height = widget.height!.clamp(0.0, maxHeight).toDouble();
      width = height * aspectRatio;
      if (width > maxWidth) {
        width = maxWidth;
        height = width / aspectRatio;
      }
      return Size(width, height);
    }

    width = maxWidth;
    height = width / aspectRatio;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * aspectRatio;
    }

    return Size(width, height);
  }
}
