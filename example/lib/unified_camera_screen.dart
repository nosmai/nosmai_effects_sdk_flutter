import 'package:flutter/material.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';
import 'package:permission_handler/permission_handler.dart';

/// Unified camera screen that demonstrates comprehensive Nosmai SDK functionality
///
/// This screen showcases:
/// - Live camera preview with filters
/// - Photo capture and video recording
/// - Filter categories (Effects, Beauty, Color, HSB, Cloud)
/// - Real-time filter application
/// - Cloud filter downloading
/// - Camera switching
/// - Responsive UI design
///
/// The implementation follows Flutter best practices with proper error handling,
/// performance optimizations, and a clean, maintainable code structure.
class UnifiedCameraScreen extends StatefulWidget {
  const UnifiedCameraScreen({super.key});

  @override
  State<UnifiedCameraScreen> createState() => _UnifiedCameraScreenState();
}

class _UnifiedCameraScreenState extends State<UnifiedCameraScreen>
    with TickerProviderStateMixin {
  // SDK instance
  final NosmaiFlutter _nosmai = NosmaiFlutter.instance;

  // Camera state
  bool _isRecording = false;
  bool _isFrontCamera = true;

  // UI Controllers
  late AnimationController _recordButtonController;

  // ── Beauty sheet state — mirrors the Android MakeupBottomSheet. State lives on
  //    the parent State (survives sheet close/reopen); the applied effects live in
  //    the native engine. Slider values are stored in their final API ranges.
  int _beautyCategory = 0;
  // Active variant per makeup category (-1 = none):
  // 0=lipstick 1=eyeshadow 2=blusher 3=eyelash 4=eyebrow
  final List<int> _makeupVariant = [-1, -1, -1, -1, -1];
  // Skin
  double _bSmoothing = 0.0; // 0..1
  double _bKeepTexture = 0.0; // 0..1 (sharpen = pore/texture preservation)
  double _bWhitening = 0.0; // 0..1
  // Adjust
  double _bBrightness = 0.0; // -1..1, 0 neutral
  double _bContrast = 1.0; // 0..2, 1 neutral
  // Color
  double _bHue = 0.0; // 0..360 degrees
  double _bWbTemp = 5000.0; // 2000..8000 K
  double _bWbTint = 0.0; // -100..100
  double _bRed = 1.0; // 0..2, 1 neutral
  double _bGreen = 1.0; // 0..2, 1 neutral
  double _bBlue = 1.0; // 0..2, 1 neutral
  // Teeth
  double _bTeeth = 0.0; // 0..1

  // Beauty category labels + icons (first 5 are makeup with variant chips).
  static const List<String> _beautyCats = [
    'Lipstick',
    'Eyeshadow',
    'Blusher',
    'Eyelash',
    'Eyebrow',
    'Skin',
    'Adjust',
    'Color',
    'Teeth',
  ];
  static const List<String> _beautyCatIcons = [
    '💋',
    '🎨',
    '🌸',
    '👁️',
    '✏️',
    '✨',
    '🎛️',
    '🌈',
    '🦷',
  ];
  // Variant labels — order matches the style enum ordinals (0,1,2).
  static const List<List<String>> _makeupVariants = [
    ['Classic', 'Matte', 'Natural'], // Lipstick
    ['Smokey', 'Shimmer', 'Natural'], // Eyeshadow
    ['Round', 'Contour', 'Natural'], // Blusher
    ['Natural', 'Dramatic', 'Wispy'], // Eyelash
    ['Natural', 'Bold', 'Arched'], // Eyebrow
  ];
  // Per-category default makeup intensity.
  static const List<double> _makeupIntensity = [0.5, 0.7, 0.6, 1.0, 0.8];

  @override
  void initState() {
    super.initState();
    _setupAnimationControllers();
  }

  /// Setup animation controllers
  void _setupAnimationControllers() {
    _recordButtonController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
  }

  Future<void> _resetAllFilters() async {
    try {
      await _nosmai.removeAllMakeup();
      await _nosmai.removeBuiltInFilters();
      await _nosmai.removeAllFilters();
      _resetBeautyState();
    } catch (e) {
      debugPrint('Error resetting filters: $e');
    }
  }

  /// Reset all beauty-sheet slider/variant state back to neutral. Does NOT touch
  /// the engine (the caller already tore the native filters down).
  void _resetBeautyState() {
    setState(() {
      for (int i = 0; i < _makeupVariant.length; i++) {
        _makeupVariant[i] = -1;
      }
      _bSmoothing = 0.0;
      _bKeepTexture = 0.0;
      _bWhitening = 0.0;
      _bBrightness = 0.0;
      _bContrast = 1.0;
      _bHue = 0.0;
      _bWbTemp = 5000.0;
      _bWbTint = 0.0;
      _bRed = 1.0;
      _bGreen = 1.0;
      _bBlue = 1.0;
      _bTeeth = 0.0;
    });
  }

  Future<void> _toggleRecording() async {
    try {
      if (_isRecording) {
        _recordButtonController.reverse();
        final result = await _nosmai.stopRecording();

        if (!mounted) return;

        setState(() => _isRecording = false);

        if (result.success && result.videoPath != null) {
          _showVideoSuccessDialog(result.videoPath!);
        }
      } else {
        final success = await _nosmai.startRecording();

        if (!mounted) return;

        if (success) {
          setState(() => _isRecording = true);
          _recordButtonController.forward();
        }
      }
    } catch (e) {
      debugPrint('Recording error: $e');
    }
  }

  Future<void> _capturePhoto() async {
    try {
      final result = await _nosmai.capturePhoto();

      if (result.success) {
        _showPhotoSuccessDialog(result);
      }
    } catch (e) {
      debugPrint('Photo capture error: $e');
    }
  }

  Future<void> _switchCamera() async {
    try {
      // Check if SDK is still initialized
      if (!_nosmai.isInitialized) {
        debugPrint('❌ SDK not initialized, cannot switch camera');
        return;
      }

      final switched = await _nosmai.switchCamera();

      if (switched) {
        setState(() {
          _isFrontCamera = !_isFrontCamera;
        });
        debugPrint(
          '✅ Camera switched successfully to ${_isFrontCamera ? 'front' : 'back'}',
        );
      } else {
        debugPrint('🔄 Camera switch throttled - ignored rapid tap');
      }
    } catch (e) {
      debugPrint('❌ Camera switch failed: $e');

      // Handle specific error types
      if (e is NosmaiError) {
        _handleCameraError(e);
      } else {
        _showErrorMessage('Camera switch failed: ${e.toString()}');
      }
    }
  }

  /// Handle camera-specific errors with user-friendly messages
  void _handleCameraError(NosmaiError error) {
    switch (error.type) {
      case NosmaiErrorType.cameraPermissionDenied:
        _showErrorDialog(
          'Camera Permission Required',
          error.userMessage,
          actions: error.recoveryActions,
        );
        break;
      case NosmaiErrorType.cameraUnavailable:
        _showErrorMessage('Camera is not available on this device');
        break;
      case NosmaiErrorType.cameraSwitchFailed:
        _showErrorMessage('Failed to switch camera. Please try again.');
        break;
      default:
        _showErrorMessage(error.userMessage);
    }
  }

  /// Show error dialog with recovery actions
  void _showErrorDialog(String title, String message, {List<String>? actions}) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            if (actions != null && actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Suggested actions:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ...actions.map((action) => Text('• $action')),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Show simple error message
  void _showErrorMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showPhotoSuccessDialog(NosmaiPhotoResult result) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: false,
      isDismissible: true,
      enableDrag: false,
      builder: (context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(77),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Icon(
              Icons.check_circle,
              color: Color(0xFF4ECDC4),
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              'Photo Captured!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withAlpha(77),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Done'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      if (result.imageData != null) {
                        await _savePhotoToGallery(result);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6C5CE7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Save to Gallery'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _savePhotoToGallery(NosmaiPhotoResult result) async {
    try {
      final permission = await Permission.photos.request();
      if (permission != PermissionStatus.granted) return;

      final imageResult = await _nosmai.saveImageToGallery(
        result.imageData!,
        name: "nosmai_photo_${DateTime.now().millisecondsSinceEpoch}",
      );

      if (imageResult['isSuccess'] == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Photo saved to gallery'),
            backgroundColor: const Color(0xFF4ECDC4),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Failed to save photo: $e');
    }
  }

  void _showVideoSuccessDialog(String videoPath) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: false,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(77),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Icon(Icons.videocam, color: Color(0xFF4ECDC4), size: 48),
            const SizedBox(height: 16),
            const Text(
              'Video Recorded!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                await _saveVideoToGallery(videoPath);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C5CE7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Save to Gallery'),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _saveVideoToGallery(String videoPath) async {
    try {
      final permission = await Permission.photos.request();
      if (permission != PermissionStatus.granted) return;

      final result = await _nosmai.saveVideoToGallery(
        videoPath,
        name: "nosmai_video_${DateTime.now().millisecondsSinceEpoch}",
      );

      if (result['isSuccess'] == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Video saved to gallery'),
            backgroundColor: const Color(0xFF4ECDC4),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Failed to save video: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Positioned.fill(
            child: RepaintBoundary(child: NosmaiCameraPreview()),
          ),

          // Top Controls
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withAlpha(179),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Back button
                      _buildIconButton(
                        icon: Icons.arrow_back_ios_rounded,
                        onTap: () async {
                          if (mounted) {
                            Navigator.pop(context);
                          }
                        },
                      ),

                      const SizedBox.shrink(),

                      // Right controls
                      Row(
                        children: [
                          _buildIconButton(
                            icon: NosmaiFlutter.isCameraSwitching
                                ? Icons.hourglass_empty_rounded
                                : Icons.flip_camera_ios_rounded,
                            onTap: NosmaiFlutter.isCameraSwitching
                                ? null
                                : _switchCamera,
                          ),
                          const SizedBox(width: 12),
                          _buildIconButton(
                            icon: Icons.refresh_rounded,
                            onTap: _resetAllFilters,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Bottom Controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Main Controls
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withAlpha(230),
                        Colors.black.withAlpha(153),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: SafeArea(
                    child: Column(
                      children: [
                        // Action Buttons
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              // Capture Photo
                              _buildActionButton(
                                icon: Icons.camera_alt_rounded,
                                onTap: _capturePhoto,
                                size: 24,
                              ),

                              // Record Video
                              GestureDetector(
                                onTap: _toggleRecording,
                                child: AnimatedBuilder(
                                  animation: _recordButtonController,
                                  builder: (context, child) {
                                    return Container(
                                      width: 60,
                                      height: 60,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: _isRecording
                                              ? Colors.red
                                              : Colors.white,
                                          width: 3,
                                        ),
                                      ),
                                      child: Center(
                                        child: Container(
                                          width: 46,
                                          height: 46,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: _isRecording
                                                ? Colors.red
                                                : Colors.white.withAlpha(77),
                                          ),
                                          child: Icon(
                                            _isRecording
                                                ? Icons.stop
                                                : Icons.videocam,
                                            color: Colors.white,
                                            size: 24,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),

                              // Beauty (opens the Android-style beauty sheet)
                              _buildActionButton(
                                icon: Icons.face_retouching_natural,
                                onTap: _openBeautySheet,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Recording Indicator
          if (_isRecording)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.only(top: 16),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Recording',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback? onTap,
    double size = 24,
  }) {
    final isDisabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(isDisabled ? 26 : 51),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: isDisabled ? Colors.white.withAlpha(128) : Colors.white,
          size: size,
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 24,
    bool isActive = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color:
              isActive ? const Color(0xFF6C5CE7) : Colors.white.withAlpha(51),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: size),
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Beauty sheet — Flutter port of the Android MakeupBottomSheet. ONE category
  // row (5 makeup + Skin / Adjust / Color / Teeth). Tapping a category fills the
  // panel below: makeup → variant chips, adjustments → sliders. Multiple layers
  // stay active at once; selecting a category only changes what is SHOWN. State
  // lives on the parent State so it survives sheet close/reopen.
  // ───────────────────────────────────────────────────────────────────────────
  void _openBeautySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF151515),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (_, setSheet) => _buildBeautySheet(setSheet),
      ),
    );
  }

  Widget _buildBeautySheet(StateSetter setSheet) {
    final media = MediaQuery.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 10,
          bottom: 16 + media.viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 5,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(85),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '💄  Beauty',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () async {
                    await _clearAllBeauty();
                    setSheet(() {});
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text(
                      'Clear All',
                      style: TextStyle(
                        color: Color(0xFFFF6B6B),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Tap a category — makeup shows styles, the rest show sliders.',
              style:
                  TextStyle(color: Colors.white.withAlpha(140), fontSize: 12),
            ),
            const SizedBox(height: 14),
            _sectionLabel('CATEGORY'),
            const SizedBox(height: 8),
            SizedBox(
              height: 92,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _beautyCats.length,
                itemBuilder: (_, i) => _beautyCatChip(i, setSheet),
              ),
            ),
            const SizedBox(height: 14),
            _sectionLabel('OPTIONS'),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: media.size.height * 0.38),
              child: SingleChildScrollView(child: _beautyPanel(setSheet)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: TextStyle(
          color: Colors.white.withAlpha(140),
          fontSize: 11,
          letterSpacing: 1.2,
        ),
      );

  Widget _beautyCatChip(int i, StateSetter setSheet) {
    final selected = _beautyCategory == i;
    final active = _categoryHasActive(i);
    return GestureDetector(
      onTap: () => setSheet(() => _beautyCategory = i),
      child: Container(
        width: 74,
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color:
              selected ? const Color(0xFF6C5CE7) : Colors.white.withAlpha(20),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color:
                selected ? const Color(0xFF6C5CE7) : Colors.white.withAlpha(30),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_beautyCatIcons[i], style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 6),
            Text(
              _beautyCats[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? const Color(0xFF74B9FF) : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _beautyPanel(StateSetter setSheet) {
    final cat = _beautyCategory;

    // Makeup categories → variant chips.
    if (cat < 5) {
      final variants = _makeupVariants[cat];
      final active = _makeupVariant[cat];
      return Row(
        children: List.generate(variants.length, (vi) {
          final isSel = vi == active;
          return Expanded(
            child: GestureDetector(
              onTap: () => _onVariantTap(cat, vi, setSheet),
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: isSel
                      ? const Color(0xFF6C5CE7)
                      : Colors.white.withAlpha(20),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSel
                        ? const Color(0xFF6C5CE7)
                        : Colors.white.withAlpha(30),
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      '${vi + 1}',
                      style: TextStyle(
                        color: Colors.white.withAlpha(150),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      variants[vi],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      );
    }

    // Adjustment groups → sliders. Values are stored/passed in final API ranges.
    switch (cat) {
      case 5: // Skin
        return Column(
          children: [
            _beautySlider('✨  Smoothing', _bSmoothing, 0, 1, (v) {
              _bSmoothing = v;
              _nosmai.applySkinSmoothing(v);
            }, setSheet),
            _beautySlider('🫧  Keep texture', _bKeepTexture, 0, 1, (v) {
              _bKeepTexture = v;
              _nosmai.applySharpening(v);
            }, setSheet),
            _beautySlider('🤍  Whitening', _bWhitening, 0, 1, (v) {
              _bWhitening = v;
              _nosmai.applySkinWhitening(v);
            }, setSheet),
          ],
        );
      case 6: // Adjust
        return Column(
          children: [
            _beautySlider('☀️  Brightness', _bBrightness, -1, 1, (v) {
              _bBrightness = v;
              _nosmai.applyBrightnessFilter(v);
            }, setSheet),
            _beautySlider('🎛️  Contrast', _bContrast, 0, 2, (v) {
              _bContrast = v;
              _nosmai.applyContrastFilter(v);
            }, setSheet),
            // NOTE: Saturation intentionally omitted — the Flutter plugin's
            // adjustHSB is an Android stub that drops saturation and only
            // re-applies hue (which would reset the Hue slider). Needs a real
            // applySaturation channel (like teeth) before it can go here.
          ],
        );
      case 7: // Color
        return Column(
          children: [
            _beautySlider('🎨  Hue', _bHue, 0, 360, (v) {
              _bHue = v;
              _nosmai.applyHue(v);
            }, setSheet),
            _beautySlider('🌡️  WB Temp', _bWbTemp, 2000, 8000, (v) {
              _bWbTemp = v;
              _nosmai.applyWhiteBalance(temperature: v, tint: _bWbTint);
            }, setSheet),
            _beautySlider('🎚️  WB Tint', _bWbTint, -100, 100, (v) {
              _bWbTint = v;
              _nosmai.applyWhiteBalance(temperature: _bWbTemp, tint: v);
            }, setSheet),
            _beautySlider('🔴  Red', _bRed, 0, 2, (v) {
              _bRed = v;
              _nosmai.applyRGBFilter(red: _bRed, green: _bGreen, blue: _bBlue);
            }, setSheet),
            _beautySlider('🟢  Green', _bGreen, 0, 2, (v) {
              _bGreen = v;
              _nosmai.applyRGBFilter(red: _bRed, green: _bGreen, blue: _bBlue);
            }, setSheet),
            _beautySlider('🔵  Blue', _bBlue, 0, 2, (v) {
              _bBlue = v;
              _nosmai.applyRGBFilter(red: _bRed, green: _bGreen, blue: _bBlue);
            }, setSheet),
          ],
        );
      case 8: // Teeth
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _beautySlider('🦷  Whitening', _bTeeth, 0, 1, (v) {
              _bTeeth = v;
              _nosmai.applyTeethWhitening(v);
            }, setSheet),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Smile to see it — teeth whitening only shows when your '
                'mouth is open.',
                style:
                    TextStyle(color: Colors.white.withAlpha(140), fontSize: 11),
              ),
            ),
          ],
        );
    }
    return const SizedBox.shrink();
  }

  Widget _beautySlider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) onChange,
    StateSetter setSheet,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label    ${max > 10 ? value.toStringAsFixed(0) : value.toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF6C5CE7),
              inactiveTrackColor: Colors.white.withAlpha(51),
              thumbColor: const Color(0xFF6C5CE7),
              overlayColor: const Color(0xFF6C5CE7).withAlpha(77),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              trackHeight: 3,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: (v) => setSheet(() => onChange(v)),
            ),
          ),
        ],
      ),
    );
  }

  /// Tap a variant: tap the active one again → remove that category; else apply.
  /// Layers stack — applying one makeup category never clears the others.
  Future<void> _onVariantTap(int cat, int vi, StateSetter setSheet) async {
    try {
      if (_makeupVariant[cat] == vi) {
        await _removeMakeup(cat);
        _makeupVariant[cat] = -1;
      } else {
        await _applyMakeup(cat, vi);
        _makeupVariant[cat] = vi;
      }
    } catch (e) {
      debugPrint('Beauty variant tap error: $e');
    }
    setSheet(() {});
  }

  Future<void> _applyMakeup(int cat, int vi) async {
    final intensity = _makeupIntensity[cat];
    switch (cat) {
      case 0:
        await _nosmai.applyLipstick(
            style: NosmaiLipstickStyle.values[vi], intensity: intensity);
        break;
      case 1:
        await _nosmai.applyEyeshadow(
            style: NosmaiEyeshadowStyle.values[vi], intensity: intensity);
        break;
      case 2:
        await _nosmai.applyBlusher(
            style: NosmaiBlusherStyle.values[vi], intensity: intensity);
        break;
      case 3:
        await _nosmai.applyEyelash(
            style: NosmaiEyelashStyle.values[vi], intensity: intensity);
        break;
      case 4:
        await _nosmai.applyEyebrow(
            style: NosmaiEyebrowStyle.values[vi], intensity: intensity);
        break;
    }
  }

  Future<void> _removeMakeup(int cat) async {
    switch (cat) {
      case 0:
        await _nosmai.removeLipstick();
        break;
      case 1:
        await _nosmai.removeEyeshadow();
        break;
      case 2:
        await _nosmai.removeBlusher();
        break;
      case 3:
        await _nosmai.removeEyelash();
        break;
      case 4:
        await _nosmai.removeEyebrow();
        break;
    }
  }

  /// Whether a category currently has an active effect (drives the blue dot).
  bool _categoryHasActive(int i) {
    switch (i) {
      case 5:
        return _bSmoothing > 0 || _bKeepTexture > 0 || _bWhitening > 0;
      case 6:
        return _bBrightness != 0 || _bContrast != 1;
      case 7:
        return _bHue != 0 ||
            _bWbTemp != 5000 ||
            _bWbTint != 0 ||
            _bRed != 1 ||
            _bGreen != 1 ||
            _bBlue != 1;
      case 8:
        return _bTeeth > 0;
      default:
        return i < 5 && _makeupVariant[i] != -1;
    }
  }

  /// Clear EVERY built-in beauty effect (makeup layers + adjustments).
  Future<void> _clearAllBeauty() async {
    try {
      await _nosmai.removeAllMakeup();
      await _nosmai.removeAllBeautyEffects();
      await _nosmai.removeBuiltInFilters();
    } catch (e) {
      debugPrint('Clear beauty error: $e');
    }
    _resetBeautyState();
  }

  @override
  void dispose() {
    _recordButtonController.dispose();
    super.dispose();
  }
}
