/// Nosmai Flutter Plugin Enums
///
/// This file contains all the enumeration types used by the Nosmai Flutter plugin.
library;

/// Camera position enumeration
enum NosmaiCameraPosition { front, back }

/// Filter types supported by Nosmai SDK
enum NosmaiFilterType {
  local, // Custom .nosmai effect packages
  cloud, // Cloud-based filters
}

/// Filter category types for metadata-based categorization
///
/// These correspond to the `filterType` field in the manifest.json file.
enum NosmaiFilterCategory {
  /// Standard color grading/LUT filters
  filter,

  /// AR effects (masks, 3D overlays, face tracking effects)
  effect,

  /// Background replacement/blur effects
  background,

  /// Preset beauty filter combinations
  beautyEffect,

  /// Legacy beauty filters (deprecated, use beautyEffect instead)
  @Deprecated('Use beautyEffect instead')
  beauty,

  /// Unknown or uncategorized filters
  unknown,
}

/// Filter source type enumeration
enum NosmaiFilterSourceType { filter, effect, background, beautyEffect }

/// Local filter type enumeration
///
/// Used to identify the type of local filter based on the `filterType` field
/// in the manifest.json file.
enum NosmaiLocalFilterType {
  /// Standard color grading/LUT filters
  filter('filter'),

  /// AR effects (masks, 3D overlays, face tracking effects)
  effect('effect'),

  /// Background replacement/blur effects
  background('background'),

  /// Preset beauty filter combinations
  beautyEffect('beauty_effect');

  final String value;
  const NosmaiLocalFilterType(this.value);

  /// Create from string value
  static NosmaiLocalFilterType fromString(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'filter':
        return NosmaiLocalFilterType.filter;
      case 'effect':
        return NosmaiLocalFilterType.effect;
      case 'background':
        return NosmaiLocalFilterType.background;
      case 'beauty_effect':
      case 'beautyeffect':
      case 'beauty-effect':
        return NosmaiLocalFilterType.beautyEffect;
      default:
        return NosmaiLocalFilterType.effect; // Default to effect
    }
  }
}

/// Cloud filter catalog compatibility version.
///
/// Used with [getCloudFilters]. Version 2 is selected by default.
enum NosmaiCloudFilterVersion {
  /// Cloud filter catalog version 2.
  v2('2.0.0');

  final String apiValue;
  const NosmaiCloudFilterVersion(this.apiValue);
}

/// Cloud filter type for API requests
///
/// Used with [getCloudFilters] to fetch specific types of cloud filters.
enum NosmaiCloudFilterType {
  /// Special effects (glitch, distortion, AR effects, etc.)
  effects('effects'),

  /// Color grading and LUT filters
  filter('filter'),

  /// Interactive background filters
  background('bg'),

  /// Beauty packages such as makeup and face beauty effects
  beautyEffect('beauty_effect');

  final String apiValue;
  const NosmaiCloudFilterType(this.apiValue);
}

/// Error types that can occur in the Nosmai SDK
enum NosmaiErrorType {
  // General errors
  unknown,
  stateError,
  operationTimeout,
  platformError,
  networkError,
  invalidParameter,

  // SDK initialization errors
  sdkNotInitialized,
  invalidLicense,
  licenseExpired,

  // Camera errors
  cameraPermissionDenied,
  cameraUnavailable,
  cameraConfigurationFailed,
  cameraSwitchFailed,

  // Filter errors
  filterNotFound,
  filterInvalidFormat,
  filterLoadFailed,
  filterDownloadFailed,

  // Recording errors
  recordingPermissionDenied,
  recordingStorageFull,
  recordingWriteFailed,
  recordingInProgress,
}

/// SDK state enumeration
enum NosmaiSdkState { uninitialized, initializing, ready, error }

/// High-level state of active `.nosmai` packages.
enum NosmaiActiveEffectsMode {
  idle,
  effectsFilters,
  filtersBackground,
  beautyFilters,
  beautyBackground,
  unknown;

  static NosmaiActiveEffectsMode fromString(String? value) {
    switch (value?.trim()) {
      case 'idle':
        return NosmaiActiveEffectsMode.idle;
      case 'effectsFilters':
        return NosmaiActiveEffectsMode.effectsFilters;
      case 'filtersBackground':
        return NosmaiActiveEffectsMode.filtersBackground;
      case 'beautyFilters':
        return NosmaiActiveEffectsMode.beautyFilters;
      case 'beautyBackground':
        return NosmaiActiveEffectsMode.beautyBackground;
      default:
        return NosmaiActiveEffectsMode.unknown;
    }
  }
}

/// Owner of the currently active background, if any.
enum NosmaiActiveBackgroundSource {
  none,
  manual,
  filter,
  package,
  effect,
  unknown;

  static NosmaiActiveBackgroundSource fromString(String? value) {
    switch (value?.trim()) {
      case 'none':
        return NosmaiActiveBackgroundSource.none;
      case 'manual':
        return NosmaiActiveBackgroundSource.manual;
      case 'filter':
        return NosmaiActiveBackgroundSource.filter;
      case 'package':
        return NosmaiActiveBackgroundSource.package;
      case 'effect':
        return NosmaiActiveBackgroundSource.effect;
      default:
        return NosmaiActiveBackgroundSource.unknown;
    }
  }
}

/// Flash mode enumeration
enum NosmaiFlashMode { off, on, auto }

/// Torch mode enumeration
enum NosmaiTorchMode { off, on, auto }

/// License status enumeration
enum NosmaiLicenseStatus { valid, expired, invalid }

/// Background segmentation mode enumeration
enum NosmaiBackgroundSegmentationMode { color, image, video }

/// Lipstick style enumeration
///
/// Different lipstick texture/finish styles available in the SDK.
enum NosmaiLipstickStyle {
  /// Classic finish lipstick
  classic(0),

  /// Matte finish lipstick
  matte(1),

  /// Natural/subtle lipstick
  natural(2);

  final int value;
  const NosmaiLipstickStyle(this.value);

  /// Create from integer value
  static NosmaiLipstickStyle fromValue(int value) {
    switch (value) {
      case 0:
        return NosmaiLipstickStyle.classic;
      case 1:
        return NosmaiLipstickStyle.matte;
      case 2:
        return NosmaiLipstickStyle.natural;
      default:
        return NosmaiLipstickStyle.classic;
    }
  }
}

/// Eyeshadow style enumeration
///
/// Different eyeshadow texture/finish styles available in the SDK.
enum NosmaiEyeshadowStyle {
  /// Smokey eye effect
  smokey(0),

  /// Shimmery/sparkly finish
  shimmer(1),

  /// Natural/subtle eyeshadow
  natural(2);

  final int value;
  const NosmaiEyeshadowStyle(this.value);

  /// Create from integer value
  static NosmaiEyeshadowStyle fromValue(int value) {
    switch (value) {
      case 0:
        return NosmaiEyeshadowStyle.smokey;
      case 1:
        return NosmaiEyeshadowStyle.shimmer;
      case 2:
        return NosmaiEyeshadowStyle.natural;
      default:
        return NosmaiEyeshadowStyle.smokey;
    }
  }
}

/// Blusher style enumeration
///
/// Different blusher application styles available in the SDK.
enum NosmaiBlusherStyle {
  /// Round cheek blush
  round(0),

  /// Contoured cheek blush
  contour(1),

  /// Natural soft blush
  natural(2);

  final int value;
  const NosmaiBlusherStyle(this.value);

  /// Create from integer value
  static NosmaiBlusherStyle fromValue(int value) {
    switch (value) {
      case 0:
        return NosmaiBlusherStyle.round;
      case 1:
        return NosmaiBlusherStyle.contour;
      case 2:
        return NosmaiBlusherStyle.natural;
      default:
        return NosmaiBlusherStyle.round;
    }
  }
}

/// Eyelash style enumeration
///
/// Different eyelash styles available in the SDK.
enum NosmaiEyelashStyle {
  /// Natural looking eyelashes
  natural(0),

  /// Bold/dramatic eyelashes
  dramatic(1),

  /// Wispy/feathery eyelashes
  wispy(2);

  final int value;
  const NosmaiEyelashStyle(this.value);

  /// Create from integer value
  static NosmaiEyelashStyle fromValue(int value) {
    switch (value) {
      case 0:
        return NosmaiEyelashStyle.natural;
      case 1:
        return NosmaiEyelashStyle.dramatic;
      case 2:
        return NosmaiEyelashStyle.wispy;
      default:
        return NosmaiEyelashStyle.natural;
    }
  }
}

/// Eyebrow style enumeration
///
/// Different eyebrow styles available in the SDK.
enum NosmaiEyebrowStyle {
  /// Natural brow
  natural(0),

  /// Bold/thick brow
  bold(1),

  /// Arched shape brow
  arched(2);

  final int value;
  const NosmaiEyebrowStyle(this.value);

  /// Create from integer value
  static NosmaiEyebrowStyle fromValue(int value) {
    switch (value) {
      case 0:
        return NosmaiEyebrowStyle.natural;
      case 1:
        return NosmaiEyebrowStyle.bold;
      case 2:
        return NosmaiEyebrowStyle.arched;
      default:
        return NosmaiEyebrowStyle.natural;
    }
  }
}
