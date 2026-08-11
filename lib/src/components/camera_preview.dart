import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../nosmai_effects_sdk.dart';
import '../platform/method_channel.dart';

class NosmaiCameraPreview extends StatefulWidget {
  const NosmaiCameraPreview({
    super.key,
    this.width,
    this.height,
    this.onInitialized,
    this.onError,
    this.controller,
  });

  final double? width;
  final double? height;
  final VoidCallback? onInitialized;
  final Function(String error)? onError;
  final NosmaiCameraPreviewController? controller;

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

  void _handleNativeCameraReady() {
    if (!mounted || _notifiedInitialized) return;
    _notifiedInitialized = true;
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
      setState(() {
        _isInitializing = true;
        _initError = null;
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
    widget.controller?._detach();
    if (defaultTargetPlatform == TargetPlatform.android) {
      CameraStateNotifier.instance
          .removeReadyCallback(_handleNativeCameraReady);
    }

    WidgetsBinding.instance.removeObserver(this);

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
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
        // Native PlatformView disposal owns final camera cleanup.
        break;
      default:
        break;
    }
  }

  Future<void> _pauseCamera() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Keep the GL pipeline/view alive and only release camera hardware.
        // The native PlatformView owns full cleanup when the widget is disposed.
        if (_isInitialized) {
          await _nosmaiFlutter.pauseCamera();
        }
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
      widget.onInitialized?.call();
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
    // Force cleanup
    await _cleanupCamera();

    // Longer delay to ensure everything is cleaned up
    await Future.delayed(const Duration(milliseconds: 1000));

    if (defaultTargetPlatform == TargetPlatform.android) {
      // AndroidView path: minimal delay and mark initialized
      await Future.delayed(const Duration(milliseconds: 50));
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isInitializing = false;
          _initError = null;
        });
      }
      widget.onInitialized?.call();
    } else {
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

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      const aspectRatio = 9.0 / 16.0;
      return LayoutBuilder(
        builder: (context, constraints) {
          final resolvedSize =
              _resolveAndroidPreviewSize(context, constraints, aspectRatio);

          return Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: resolvedSize.width,
              height: resolvedSize.height,
              child: ClipRect(
                child: const RepaintBoundary(
                  child: AndroidView(
                    viewType: 'nosmai_camera_preview',
                    layoutDirection: TextDirection.ltr,
                    creationParamsCodec: StandardMessageCodec(),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

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
              const Icon(
                Icons.error_outline,
                color: Colors.red,
                size: 48,
              ),
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
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
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
            child: UiKitView(
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
