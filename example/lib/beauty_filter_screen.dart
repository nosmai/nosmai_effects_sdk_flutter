import 'package:flutter/material.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

/// Dedicated screen for beauty filters and color adjustments
///
/// This screen demonstrates advanced filter capabilities including:
/// - Real-time beauty filters (skin smoothing, whitening, face slimming)
/// - Color adjustments (brightness, contrast, RGB)
/// - Effect filters (sharpening, hue, white balance)
/// - HSB (Hue, Saturation, Brightness) controls
/// - Organized category-based interface
///
/// The screen uses a tabbed interface to organize different filter types
/// and provides real-time preview of all adjustments.
class BeautyFilterScreen extends StatefulWidget {
  const BeautyFilterScreen({super.key});

  @override
  State<BeautyFilterScreen> createState() => _BeautyFilterScreenState();
}

class _BeautyFilterScreenState extends State<BeautyFilterScreen> {
  final NosmaiFlutter _nosmai = NosmaiFlutter.instance;

  // Initialization state
  bool _isInitialized = false;
  String _selectedCategory = 'beauty';

  // Beauty filter values
  double _skinSmoothing = 0.0;
  double _skinWhitening = 0.0;

  // Color adjustment values
  double _brightness = 0.0;
  double _contrast = 1.0;
  double _sharpening = 0.0;

  // RGB color values
  double _redValue = 1.0;
  double _greenValue = 1.0;
  double _blueValue = 1.0;

  // Effect filter values
  double _hueAngle = 0.0;
  double _temperature = 5000.0; // Normal color temperature
  double _tint = 0.0;

  // HSB values
  double _hsbHue = 0.0;
  double _hsbSaturation = 1.0;
  double _hsbBrightness = 1.0; // 1.0 is normal, not 0.0!

  // Filter category configuration
  static const List<FilterCategory> _filterCategories = [
    FilterCategory(
      id: 'beauty',
      label: 'Beauty',
      icon: Icons.face,
    ),
    FilterCategory(
      id: 'color',
      label: 'Color',
      icon: Icons.palette,
    ),
    FilterCategory(
      id: 'effect',
      label: 'Effects',
      icon: Icons.auto_awesome,
    ),
    FilterCategory(
      id: 'hsb',
      label: 'HSB',
      icon: Icons.tune,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  /// Initialize camera for beauty filter screen
  ///
  /// Configures the camera with front-facing position (typical for beauty filters)
  /// and starts processing. Face detection is automatically enabled when beauty
  /// filters are used.
  Future<void> _initializeCamera() async {
    try {
      // Configure camera if not already done
      await _nosmai.configureCamera(
        position: NosmaiCameraPosition.front,
      );

      // Face detection is automatically enabled when beauty filters are used

      // Start processing
      await _nosmai.startProcessing();

      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

  /// Apply all beauty filters with current values
  ///
  /// This method applies beauty enhancement filters including skin smoothing
  /// and whitening.
  Future<void> _applyBeautyFilters() async {
    try {
      await _nosmai.applySkinSmoothing(_skinSmoothing);
      await _nosmai.applySkinWhitening(_skinWhitening);
    } catch (e) {
      debugPrint('Error applying beauty filters: $e');
    }
  }

  /// Apply color adjustment filters
  ///
  /// This method applies brightness, contrast, and RGB color adjustments
  /// to enhance the overall color appearance of the video feed.
  Future<void> _applyColorFilters() async {
    try {
      await _nosmai.applyBrightnessFilter(_brightness);
      await _nosmai.applyContrastFilter(_contrast);
      await _nosmai.applyRGBFilter(
        red: _redValue,
        green: _greenValue,
        blue: _blueValue,
      );
    } catch (e) {
      debugPrint('Error applying color filters: $e');
    }
  }

  /// Apply effect filters
  ///
  /// This method applies various effect filters including sharpening,
  /// hue adjustment, and white balance correction.
  Future<void> _applyEffectFilters() async {
    try {
      await _nosmai.applySharpening(_sharpening);
      await _nosmai.applyHue(_hueAngle);
      await _nosmai.applyWhiteBalance(
        temperature: _temperature,
        tint: _tint,
      );
    } catch (e) {
      debugPrint('Error applying effect filters: $e');
    }
  }

  /// Apply HSB (Hue, Saturation, Brightness) filters
  ///
  /// This method applies HSB adjustments. Note that hue adjustment is handled
  /// separately since it's not implemented in the HSB filter directly.
  Future<void> _applyHSBFilters() async {
    try {
      // Apply HSB values (Note: Hue in HSB is not implemented in SDK)
      // So we use the standalone applyHue filter for hue adjustment
      if (_hsbHue != 0.0) {
        // Convert from -360 to 360 range to 0 to 360 range for applyHue
        double hueValue = _hsbHue < 0 ? _hsbHue + 360 : _hsbHue;
        await _nosmai.applyHue(hueValue);
      }

      // Apply saturation and brightness through HSB
      await _nosmai.adjustHSB(
        hue: 0.0, // Always 0 since hue is not implemented in HSB
        saturation: _hsbSaturation,
        brightness: _hsbBrightness,
      );
    } catch (e) {
      debugPrint('Error applying HSB filters: $e');
    }
  }

  /// Reset all filters to their default values
  ///
  /// This method resets all filter values to their defaults and removes
  /// any applied filters from the SDK.
  Future<void> _resetAllFilters() async {
    setState(() {
      _resetFilterValues();
    });

    try {
      await _nosmai.removeBuiltInFilters();
    } catch (e) {
      debugPrint('Error resetting filters: $e');
    }
  }

  /// Reset all filter values to defaults
  void _resetFilterValues() {
    // Beauty filters
    _skinSmoothing = 0.0;
    _skinWhitening = 0.0;

    // Color filters
    _brightness = 0.0;
    _contrast = 1.0;
    _redValue = 1.0;
    _greenValue = 1.0;
    _blueValue = 1.0;

    // Effect filters
    _sharpening = 0.0;
    _hueAngle = 0.0;
    _temperature = 5000.0;
    _tint = 0.0;

    // HSB filters
    _hsbHue = 0.0;
    _hsbSaturation = 1.0;
    _hsbBrightness = 1.0;
  }

  Widget _buildCategoryChip(String category, String label, IconData icon) {
    final isSelected = _selectedCategory == category;
    return GestureDetector(
      onTap: () => setState(() => _selectedCategory = category),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color:
              isSelected ? const Color(0xFF6C5CE7) : Colors.white.withAlpha(26),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF6C5CE7)
                : Colors.white.withAlpha(77),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    required VoidCallback onChangeEnd,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                value.toStringAsFixed(max > 2 ? 0 : 2),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF6C5CE7),
              inactiveTrackColor: Colors.white30,
              thumbColor: const Color(0xFF6C5CE7),
              overlayColor: const Color(0xFF6C5CE7).withAlpha(77),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              trackHeight: 3,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
              onChangeEnd: (_) => onChangeEnd(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBeautyControls() {
    return Column(
      children: [
        _buildSlider(
          label: 'Skin Smoothing',
          value: _skinSmoothing,
          min: 0.0,
          max: 10.0,
          onChanged: (value) => setState(() => _skinSmoothing = value),
          onChangeEnd: _applyBeautyFilters,
        ),
        _buildSlider(
          label: 'Skin Whitening',
          value: _skinWhitening,
          min: 0.0,
          max: 10.0,
          onChanged: (value) => setState(() => _skinWhitening = value),
          onChangeEnd: _applyBeautyFilters,
        ),
      ],
    );
  }

  Widget _buildColorControls() {
    return Column(
      children: [
        _buildSlider(
          label: 'Brightness',
          value: _brightness,
          min: -1.0,
          max: 1.0,
          onChanged: (value) => setState(() => _brightness = value),
          onChangeEnd: _applyColorFilters,
        ),
        _buildSlider(
          label: 'Contrast',
          value: _contrast,
          min: 0.0,
          max: 2.0,
          onChanged: (value) => setState(() => _contrast = value),
          onChangeEnd: _applyColorFilters,
        ),
        _buildSlider(
          label: 'Red',
          value: _redValue,
          min: 0.0,
          max: 2.0,
          onChanged: (value) => setState(() => _redValue = value),
          onChangeEnd: _applyColorFilters,
        ),
        _buildSlider(
          label: 'Green',
          value: _greenValue,
          min: 0.0,
          max: 2.0,
          onChanged: (value) => setState(() => _greenValue = value),
          onChangeEnd: _applyColorFilters,
        ),
        _buildSlider(
          label: 'Blue',
          value: _blueValue,
          min: 0.0,
          max: 2.0,
          onChanged: (value) => setState(() => _blueValue = value),
          onChangeEnd: _applyColorFilters,
        ),
      ],
    );
  }

  Widget _buildEffectControls() {
    return Column(
      children: [
        _buildSlider(
          label: 'Sharpening',
          value: _sharpening,
          min: 0.0,
          max: 10.0,
          onChanged: (value) => setState(() => _sharpening = value),
          onChangeEnd: _applyEffectFilters,
        ),
        _buildSlider(
          label: 'Hue',
          value: _hueAngle,
          min: 0.0,
          max: 360.0,
          onChanged: (value) => setState(() => _hueAngle = value),
          onChangeEnd: _applyEffectFilters,
        ),
        _buildSlider(
          label: 'Temperature',
          value: _temperature,
          min: 2000.0,
          max: 8000.0,
          onChanged: (value) => setState(() => _temperature = value),
          onChangeEnd: _applyEffectFilters,
        ),
        _buildSlider(
          label: 'Tint',
          value: _tint,
          min: -1.0,
          max: 1.0,
          onChanged: (value) => setState(() => _tint = value),
          onChangeEnd: _applyEffectFilters,
        ),
      ],
    );
  }

  Widget _buildHSBControls() {
    return Column(
      children: [
        _buildSlider(
          label: 'Hue',
          value: _hsbHue,
          min: -360.0,
          max: 360.0,
          onChanged: (value) => setState(() => _hsbHue = value),
          onChangeEnd: _applyHSBFilters,
        ),
        _buildSlider(
          label: 'Saturation',
          value: _hsbSaturation,
          min: 0.0,
          max: 2.0,
          onChanged: (value) => setState(() => _hsbSaturation = value),
          onChangeEnd: _applyHSBFilters,
        ),
        _buildSlider(
          label: 'Brightness',
          value: _hsbBrightness,
          min: 0.0,
          max: 2.0,
          onChanged: (value) => setState(() => _hsbBrightness = value),
          onChangeEnd: _applyHSBFilters,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Beauty & Filters',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _resetAllFilters,
            tooltip: 'Reset All',
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
            onPressed: () async {
              await _nosmai.switchCamera();
            },
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // Camera preview
          if (_isInitialized)
            const Positioned.fill(
              child: RepaintBoundary(
                child: NosmaiCameraPreview(
                  key: ValueKey('beauty_camera_preview'),
                ),
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
            ),

          // Controls overlay
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withAlpha(204),
                  ],
                ),
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Category selector
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Row(
                        children: _filterCategories
                            .map((category) {
                              return [
                                _buildCategoryChip(
                                    category.id, category.label, category.icon),
                                if (category != _filterCategories.last)
                                  const SizedBox(width: 8),
                              ];
                            })
                            .expand((widgets) => widgets)
                            .toList(),
                      ),
                    ),

                    // Controls based on selected category
                    Container(
                      height: 250,
                      padding: const EdgeInsets.all(16),
                      child: SingleChildScrollView(
                        child: Builder(
                          builder: (context) {
                            switch (_selectedCategory) {
                              case 'beauty':
                                return _buildBeautyControls();
                              case 'color':
                                return _buildColorControls();
                              case 'effect':
                                return _buildEffectControls();
                              case 'hsb':
                                return _buildHSBControls();
                              default:
                                return const SizedBox.shrink();
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    // Don't cleanup SDK - let app manager handle it
    super.dispose();
  }
}

/// Filter category configuration class
class FilterCategory {
  final String id;
  final String label;
  final IconData icon;

  const FilterCategory({
    required this.id,
    required this.label,
    required this.icon,
  });
}
