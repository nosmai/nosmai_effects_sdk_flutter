/// Nosmai Flutter Plugin Data Models
///
/// This file contains all the data model classes used by the Nosmai Flutter plugin.
library;

import 'dart:typed_data';
import 'dart:ui';
import 'enums.dart';

/// Helper function to safely parse integers from various types
int? _parseIntSafely(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return parsed;
    final doubleValue = double.tryParse(value);
    return doubleValue?.toInt();
  }
  return null;
}

double? _parseDoubleSafely(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

bool _parseBoolSafely(dynamic value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final normalized = value.toString().trim().toLowerCase();
  return normalized == 'true' || normalized == '1' || normalized == 'yes';
}

String? _stringOrNull(dynamic value) {
  if (value == null) return null;
  final text = value.toString();
  if (text.isEmpty || text == 'null') return null;
  return text;
}

String _normalizeFilterType(dynamic value) {
  final raw = value?.toString().trim().toLowerCase();
  if (raw == null || raw.isEmpty) return '';
  final normalized = raw.replaceAll('-', '_');
  return normalized == 'beautyeffect' ? 'beauty_effect' : normalized;
}

/// Filter information for both local and cloud filters
class NosmaiFilter {
  final String id;

  /// Download/cache identifier used by the cloud-filter APIs.
  ///
  /// Older native bridges returned the catalog record UUID as [id] and the
  /// downloadable package identifier separately as `filterId`. Keep both so
  /// callers can safely use [cloudIdentifier] without losing the record ID.
  final String? filterId;
  final String? backendId;
  final String name;
  final String description;
  final String displayName;
  final String path;
  final int fileSize;
  final String type; // "cloud" or "local" - indicates source location
  final NosmaiFilterCategory filterCategory; // beauty, effect, filter
  final NosmaiFilterSourceType sourceType; // filter, effect

  // Cloud-specific properties (optional for local filters)
  final bool isFree;
  final bool isDownloaded;
  final String? previewUrl;
  final String? category;
  final int downloadCount;
  final int price;

  // New structure properties (optional - only for Nosmai_Filters structure)
  final String? version;
  final String? author;
  final String? minSDKVersion;
  final String? created;
  final List<String>? tags;

  const NosmaiFilter({
    required this.id,
    this.filterId,
    this.backendId,
    required this.name,
    required this.description,
    required this.displayName,
    required this.path,
    required this.fileSize,
    required this.type,
    this.filterCategory = NosmaiFilterCategory.unknown,
    this.sourceType = NosmaiFilterSourceType.effect,
    this.isFree = true,
    this.isDownloaded = true,
    this.previewUrl,
    this.category,
    this.downloadCount = 0,
    this.price = 0,
    this.version,
    this.author,
    this.minSDKVersion,
    this.created,
    this.tags,
  });

  /// Check if this is a cloud filter
  bool get isCloudFilter => type == 'cloud';

  /// Identifier accepted by download/remove cloud-filter APIs.
  String get cloudIdentifier =>
      filterId != null && filterId!.isNotEmpty ? filterId! : id;

  /// Check if this is a local filter
  bool get isLocalFilter => type == 'local';

  /// Check if this is a filter (vs effect)
  bool get isFilter => sourceType == NosmaiFilterSourceType.filter;

  /// Check if this is an effect (vs filter)
  bool get isEffect => sourceType == NosmaiFilterSourceType.effect;

  /// Check if this is a background filter
  bool get isBackground => filterCategory == NosmaiFilterCategory.background;

  /// Check if this is a beauty effect
  bool get isBeautyEffect =>
      filterCategory == NosmaiFilterCategory.beautyEffect;

  /// Get the local filter type based on filterCategory
  NosmaiLocalFilterType get localFilterType {
    switch (filterCategory) {
      case NosmaiFilterCategory.filter:
        return NosmaiLocalFilterType.filter;
      case NosmaiFilterCategory.effect:
        return NosmaiLocalFilterType.effect;
      case NosmaiFilterCategory.background:
        return NosmaiLocalFilterType.background;
      case NosmaiFilterCategory.beautyEffect:
        return NosmaiLocalFilterType.beautyEffect;
      // ignore: deprecated_member_use_from_same_package
      case NosmaiFilterCategory.beauty:
        return NosmaiLocalFilterType.beautyEffect;
      case NosmaiFilterCategory.unknown:
        return NosmaiLocalFilterType.effect;
    }
  }

  factory NosmaiFilter.fromMap(Map<String, dynamic> map) {
    final String typeString = map['type']?.toString() ?? 'local';
    NosmaiFilterSourceType parsedSourceType;
    final filterTypeString = _normalizeFilterType(
      map['filterType'] ?? map['sourceType'] ?? map['category'],
    );
    switch (filterTypeString) {
      case 'filter':
        parsedSourceType = NosmaiFilterSourceType.filter;
        break;
      case 'effect':
        parsedSourceType = NosmaiFilterSourceType.effect;
        break;
      case 'background':
        parsedSourceType = NosmaiFilterSourceType.background;
        break;
      case 'beauty_effect':
        parsedSourceType = NosmaiFilterSourceType.beautyEffect;
        break;
      default:
        // Default to effect for backward compatibility
        parsedSourceType = NosmaiFilterSourceType.effect;
        break;
    }

    // Parse filter category from filterType or category field
    NosmaiFilterCategory parsedFilterCategory = NosmaiFilterCategory.unknown;
    final categoryString = _normalizeFilterType(
      map['filterType'] ?? map['category'] ?? map['filterCategory'],
    );
    if (categoryString.isNotEmpty) {
      switch (categoryString) {
        case 'filter':
          parsedFilterCategory = NosmaiFilterCategory.filter;
          break;
        case 'effect':
          parsedFilterCategory = NosmaiFilterCategory.effect;
          break;
        case 'background':
          parsedFilterCategory = NosmaiFilterCategory.background;
          break;
        case 'beauty_effect':
        case 'beautyeffect':
          parsedFilterCategory = NosmaiFilterCategory.beautyEffect;
          break;
        case 'beauty':
          // ignore: deprecated_member_use_from_same_package
          parsedFilterCategory = NosmaiFilterCategory.beauty;
          break;
        default:
          parsedFilterCategory = NosmaiFilterCategory.unknown;
          break;
      }
    }

    String finalPath;
    final pathValue = map['path'];
    if (pathValue != null && pathValue.toString() != 'null') {
      finalPath = pathValue.toString();
    } else {
      finalPath = '';
    }

    // Parse tags array safely
    List<String>? tags;
    if (map['tags'] != null) {
      try {
        final tagsList = map['tags'];
        if (tagsList is List) {
          tags = tagsList.map((e) => e.toString()).toList();
        }
      } catch (e) {
        tags = null;
      }
    }

    final filterId = _stringOrNull(map['filterId']);
    final backendId = _stringOrNull(map['backendId'] ?? map['id']);

    return NosmaiFilter(
      // Public `id` remains directly usable with downloadCloudFilter, which
      // has always documented this object as its source of identifiers.
      id: filterId ?? backendId ?? map['name']?.toString() ?? '',
      filterId: filterId,
      backendId: backendId,
      name: map['name']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      displayName:
          map['displayName']?.toString() ?? map['name']?.toString() ?? '',
      path: finalPath,
      fileSize: _parseIntSafely(map['fileSize']) ?? 0,
      type: typeString,
      filterCategory: parsedFilterCategory,
      sourceType: parsedSourceType,
      isFree: map['isFree'] as bool? ?? true,
      isDownloaded: map['isDownloaded'] as bool? ?? false,
      previewUrl: map['previewImageBase64']?.toString() ??
          map['previewUrl']?.toString() ??
          map['thumbnailUrl']?.toString(),
      category: map['category']?.toString(),
      downloadCount: _parseIntSafely(map['downloadCount']) ?? 0,
      price: _parseIntSafely(map['price']) ?? 0,
      version: map['version']?.toString(),
      author: map['author']?.toString(),
      minSDKVersion: map['minSDKVersion']?.toString(),
      created: map['created']?.toString(),
      tags: tags,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'filterId': filterId,
      'backendId': backendId,
      'name': name,
      'description': description,
      'displayName': displayName,
      'path': path,
      'fileSize': fileSize,
      'type': type,
      'filterType': localFilterType.value,
      'filterCategory': filterCategory.name,
      'sourceType': sourceType.name,
      'isFree': isFree,
      'isDownloaded': isDownloaded,
      'previewUrl': previewUrl,
      'category': category,
      'downloadCount': downloadCount,
      'price': price,
      'version': version,
      'author': author,
      'minSDKVersion': minSDKVersion,
      'created': created,
      'tags': tags,
    };
  }

  @override
  String toString() {
    return 'NosmaiFilter(id: $id, name: $name, type: $type, filterCategory: $filterCategory, sourceType: $sourceType)';
  }
}

/// Snapshot of active `.nosmai` packages.
///
/// Use [NosmaiFlutter.onActiveEffectsChanged] for live updates and
/// `NosmaiFlutter.instance.getActiveEffects()` when a screen opens.
class NosmaiActiveEffects {
  final int mode;
  final String modeName;
  final NosmaiActiveEffectsMode activeMode;
  final String? activeFilterPath;
  final String? activeEffectPath;
  final String? activeBackgroundPath;
  final bool hasBackground;
  final int backgroundSource;
  final String backgroundSourceName;
  final NosmaiActiveBackgroundSource activeBackgroundSource;
  final bool hasBeautyEffect;
  final bool hasBuiltInBeauty;
  final bool hasManualBackground;
  final NosmaiFilter? activeFilter;
  final NosmaiFilter? activeEffect;

  const NosmaiActiveEffects({
    required this.mode,
    required this.modeName,
    required this.activeMode,
    this.activeFilterPath,
    this.activeEffectPath,
    this.activeBackgroundPath,
    required this.hasBackground,
    required this.backgroundSource,
    required this.backgroundSourceName,
    required this.activeBackgroundSource,
    required this.hasBeautyEffect,
    this.hasBuiltInBeauty = false,
    required this.hasManualBackground,
    this.activeFilter,
    this.activeEffect,
  });

  factory NosmaiActiveEffects.idle() {
    return const NosmaiActiveEffects(
      mode: 0,
      modeName: 'idle',
      activeMode: NosmaiActiveEffectsMode.idle,
      hasBackground: false,
      backgroundSource: 0,
      backgroundSourceName: 'none',
      activeBackgroundSource: NosmaiActiveBackgroundSource.none,
      hasBeautyEffect: false,
      hasBuiltInBeauty: false,
      hasManualBackground: false,
    );
  }

  factory NosmaiActiveEffects.fromMap(Map<String, dynamic> map) {
    final modeName = map['modeName']?.toString() ?? 'idle';
    final backgroundSourceName =
        map['backgroundSourceName']?.toString() ?? 'none';

    NosmaiFilter? parseFilter(dynamic value) {
      if (value is Map) {
        return NosmaiFilter.fromMap(Map<String, dynamic>.from(value));
      }
      return null;
    }

    return NosmaiActiveEffects(
      mode: _parseIntSafely(map['mode']) ?? 0,
      modeName: modeName,
      activeMode: NosmaiActiveEffectsMode.fromString(modeName),
      activeFilterPath: _stringOrNull(map['activeFilterPath']),
      activeEffectPath: _stringOrNull(map['activeEffectPath']),
      activeBackgroundPath: _stringOrNull(
        map['activeBackgroundPath'] ?? map['activeBackgroundPackagePath'],
      ),
      hasBackground: _parseBoolSafely(
        map['hasBackground'] ?? map['backgroundActive'],
      ),
      backgroundSource: _parseIntSafely(map['backgroundSource']) ?? 0,
      backgroundSourceName: backgroundSourceName,
      activeBackgroundSource:
          NosmaiActiveBackgroundSource.fromString(backgroundSourceName),
      hasBeautyEffect: _parseBoolSafely(map['hasBeautyEffect']),
      hasBuiltInBeauty: _parseBoolSafely(map['hasBuiltInBeauty']),
      hasManualBackground: _parseBoolSafely(
        map['hasManualBackground'] ?? map['hasManualBackgroundConfig'],
      ),
      activeFilter: parseFilter(map['activeFilterInfo'] ?? map['activeFilter']),
      activeEffect: parseFilter(map['activeEffectInfo'] ?? map['activeEffect']),
    );
  }

  bool get hasFilter => activeFilterPath != null;
  bool get hasEffect =>
      activeEffectPath != null &&
      activeEffect?.sourceType != NosmaiFilterSourceType.beautyEffect;
  bool get hasBeautyEffectPackage => activeBeautyEffect != null;
  bool get hasAnyBeauty => hasBeautyEffect || hasBuiltInBeauty;
  bool get hasFilterPackage => activeFilterPath != null;
  bool get hasArPackage => activeEffectPath != null;
  bool get hasBackgroundPackage => activeBackgroundPath != null;
  String? get activeBackgroundPackagePath => activeBackgroundPath;
  bool get backgroundActive => hasBackground;
  bool get hasManualBackgroundConfig => hasManualBackground;
  NosmaiActiveBackgroundSource get backgroundSourceType =>
      activeBackgroundSource;
  bool get activeEffectIsBeautyEffect =>
      activeEffect?.sourceType == NosmaiFilterSourceType.beautyEffect ||
      activeEffect?.filterCategory == NosmaiFilterCategory.beautyEffect;
  NosmaiFilter? get activeBeautyEffect =>
      activeEffectIsBeautyEffect ? activeEffect : null;

  Map<String, dynamic> toMap() {
    return {
      'mode': mode,
      'modeName': modeName,
      'activeFilterPath': activeFilterPath,
      'activeEffectPath': activeEffectPath,
      'activeBackgroundPath': activeBackgroundPath,
      'activeBackgroundPackagePath': activeBackgroundPath,
      'hasBackground': hasBackground,
      'backgroundActive': hasBackground,
      'backgroundSource': backgroundSource,
      'backgroundSourceName': backgroundSourceName,
      'hasBeautyEffect': hasBeautyEffect,
      'hasBuiltInBeauty': hasBuiltInBeauty,
      'hasManualBackground': hasManualBackground,
      'hasManualBackgroundConfig': hasManualBackground,
      'activeFilterInfo': activeFilter?.toMap(),
      'activeEffectInfo': activeEffect?.toMap(),
    };
  }
}

/// Download progress information
class NosmaiDownloadProgress {
  final String filterId;
  final double progress; // 0.0 to 1.0
  final int? bytesDownloaded;
  final int? totalBytes;

  const NosmaiDownloadProgress({
    required this.filterId,
    required this.progress,
    this.bytesDownloaded,
    this.totalBytes,
  });

  factory NosmaiDownloadProgress.fromMap(Map<String, dynamic> map) {
    return NosmaiDownloadProgress(
      filterId: map['filterId']?.toString() ?? '',
      progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
      bytesDownloaded: _parseIntSafely(map['bytesDownloaded']),
      totalBytes: _parseIntSafely(map['totalBytes']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'filterId': filterId,
      'progress': progress,
      'bytesDownloaded': bytesDownloaded,
      'totalBytes': totalBytes,
    };
  }
}

/// Recording result information
class NosmaiRecordingResult {
  final bool success;
  final String? videoPath;
  final double duration;
  final int fileSize;
  final String? error;

  const NosmaiRecordingResult({
    required this.success,
    this.videoPath,
    required this.duration,
    required this.fileSize,
    this.error,
  });

  factory NosmaiRecordingResult.fromMap(Map<String, dynamic> map) {
    return NosmaiRecordingResult(
      success: map['success'] as bool? ?? false,
      videoPath: map['videoPath']?.toString(),
      duration: (map['duration'] as num?)?.toDouble() ?? 0.0,
      fileSize: _parseIntSafely(map['fileSize']) ?? 0,
      error: map['error']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'success': success,
      'videoPath': videoPath,
      'duration': duration,
      'fileSize': fileSize,
      'error': error,
    };
  }
}

/// Photo capture result
class NosmaiPhotoResult {
  final bool success;
  final String? imagePath;
  final List<int>? imageData;
  final String? error;
  final int? width;
  final int? height;

  const NosmaiPhotoResult({
    required this.success,
    this.imagePath,
    this.imageData,
    this.error,
    this.width,
    this.height,
  });

  factory NosmaiPhotoResult.fromMap(Map<String, dynamic> map) {
    try {
      final success = map['success'] as bool? ?? false;
      final imagePath = map['imagePath']?.toString();
      final error = map['error']?.toString();

      int? width;
      int? height;

      if (map['width'] != null) {
        if (map['width'] is int) {
          width = map['width'] as int;
        } else if (map['width'] is double) {
          width = (map['width'] as double).round();
        } else {
          width = int.tryParse(map['width'].toString());
        }
      }

      if (map['height'] != null) {
        if (map['height'] is int) {
          height = map['height'] as int;
        } else if (map['height'] is double) {
          height = (map['height'] as double).round();
        } else {
          height = int.tryParse(map['height'].toString());
        }
      }

      List<int>? imageData;
      if (map['imageData'] != null) {
        try {
          // Handle different types of image data from native platforms
          final rawImageData = map['imageData'];

          if (rawImageData is List<int>) {
            imageData = rawImageData;
          } else if (rawImageData is Uint8List) {
            imageData = rawImageData.toList();
          } else if (rawImageData is List) {
            // Try to convert list elements to int
            imageData = rawImageData.map((e) => e as int).toList();
          }
        } catch (e) {
          // If image data conversion fails, continue without it
          imageData = null;
        }
      }

      return NosmaiPhotoResult(
        success: success,
        imagePath: imagePath,
        imageData: imageData,
        error: error,
        width: width,
        height: height,
      );
    } catch (e) {
      return NosmaiPhotoResult(
        success: false,
        error: 'Failed to parse photo result: ${e.toString()}',
      );
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'success': success,
      'imagePath': imagePath,
      'imageData': imageData,
      'error': error,
      'width': width,
      'height': height,
    };
  }
}

/// Pagination information for cloud filters
///
/// Contains metadata about the current page and total available pages
/// when fetching cloud filters with pagination support.
class NosmaiPaginationInfo {
  final int currentPage;
  final int totalPages;
  final int totalItems;
  final int itemsPerPage;
  final bool hasNextPage;
  final bool hasPreviousPage;

  const NosmaiPaginationInfo({
    required this.currentPage,
    required this.totalPages,
    required this.totalItems,
    required this.itemsPerPage,
    required this.hasNextPage,
    required this.hasPreviousPage,
  });

  factory NosmaiPaginationInfo.fromMap(Map<String, dynamic> map) {
    final currentPage = _parseIntSafely(map['currentPage']) ?? 1;
    final totalPages = _parseIntSafely(map['totalPages']) ?? 1;

    return NosmaiPaginationInfo(
      currentPage: currentPage,
      totalPages: totalPages,
      totalItems: _parseIntSafely(map['totalItems']) ?? 0,
      itemsPerPage: _parseIntSafely(map['itemsPerPage']) ??
          _parseIntSafely(map['limit']) ??
          20,
      hasNextPage: map['hasNextPage'] as bool? ?? (currentPage < totalPages),
      hasPreviousPage: map['hasPreviousPage'] as bool? ?? (currentPage > 1),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'currentPage': currentPage,
      'totalPages': totalPages,
      'totalItems': totalItems,
      'itemsPerPage': itemsPerPage,
      'hasNextPage': hasNextPage,
      'hasPreviousPage': hasPreviousPage,
    };
  }

  @override
  String toString() {
    return 'NosmaiPaginationInfo(page: $currentPage/$totalPages, hasNext: $hasNextPage)';
  }
}

/// Effect parameter information from active .nosmai filter
///
/// Represents a single adjustable parameter in the currently loaded effect.
/// Each parameter has metadata including name, type, default value, and pass ID.
class FilterParameter {
  final String name;
  final String type;
  final String displayName;
  final String description;
  final dynamic currentValue;
  final dynamic defaultValue;
  final bool hasRange;
  final double? minValue;
  final double? maxValue;
  final List<String> options;
  final int passId;

  const FilterParameter({
    required this.name,
    required this.type,
    this.displayName = '',
    this.description = '',
    this.currentValue,
    required this.defaultValue,
    this.hasRange = false,
    this.minValue,
    this.maxValue,
    this.options = const [],
    required this.passId,
  });

  factory FilterParameter.fromMap(Map<String, dynamic> map) {
    return FilterParameter(
      name: map['name']?.toString() ?? '',
      type: map['type']?.toString() ?? 'float',
      displayName:
          map['displayName']?.toString() ?? map['name']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      currentValue: map['currentValue'] ?? map['defaultValue'],
      defaultValue: map['defaultValue'],
      hasRange: map['hasRange'] == true,
      minValue: _parseDoubleSafely(map['minValue'] ?? map['min']),
      maxValue: _parseDoubleSafely(map['maxValue'] ?? map['max']),
      options: (map['options'] as List<dynamic>?)
              ?.map((value) => value.toString())
              .toList(growable: false) ??
          const [],
      passId: _parseIntSafely(map['passId']) ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'type': type,
      'displayName': displayName,
      'description': description,
      'currentValue': currentValue,
      'defaultValue': defaultValue,
      'hasRange': hasRange,
      'minValue': minValue,
      'maxValue': maxValue,
      'options': options,
      'passId': passId,
    };
  }

  @override
  String toString() {
    return 'FilterParameter(name: $name, type: $type, currentValue: $currentValue, defaultValue: $defaultValue, passId: $passId)';
  }
}

/// Background segmentation configuration
///
/// Use factory constructors for easy configuration:
/// - `NosmaiBackgroundSegmentationConfig.color(Colors.green)` - Solid color background
/// - `NosmaiBackgroundSegmentationConfig.image(imageBytes)` - Image background
/// - `NosmaiBackgroundSegmentationConfig.video('/path/to/video.mp4')` - Video background
class NosmaiBackgroundSegmentationConfig {
  final NosmaiBackgroundSegmentationMode mode;
  final Color? replacementColor;
  final Uint8List? replacementImage;
  final String? replacementVideoPath;

  const NosmaiBackgroundSegmentationConfig._({
    required this.mode,
    this.replacementColor,
    this.replacementImage,
    this.replacementVideoPath,
  });

  /// Create a color background configuration
  factory NosmaiBackgroundSegmentationConfig.color(Color color) {
    return NosmaiBackgroundSegmentationConfig._(
      mode: NosmaiBackgroundSegmentationMode.color,
      replacementColor: color,
    );
  }

  /// Create an image background configuration
  factory NosmaiBackgroundSegmentationConfig.image(Uint8List imageData) {
    return NosmaiBackgroundSegmentationConfig._(
      mode: NosmaiBackgroundSegmentationMode.image,
      replacementImage: imageData,
    );
  }

  /// Create a video background configuration
  factory NosmaiBackgroundSegmentationConfig.video(String videoPath) {
    return NosmaiBackgroundSegmentationConfig._(
      mode: NosmaiBackgroundSegmentationMode.video,
      replacementVideoPath: videoPath,
    );
  }

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{'mode': mode.name};

    if (replacementColor != null) {
      map['colorRed'] = replacementColor!.r;
      map['colorGreen'] = replacementColor!.g;
      map['colorBlue'] = replacementColor!.b;
      map['colorAlpha'] = replacementColor!.a;
    }

    if (replacementImage != null) {
      map['imageData'] = replacementImage;
    }

    if (replacementVideoPath != null) {
      map['videoPath'] = replacementVideoPath;
    }

    return map;
  }

  @override
  String toString() {
    return 'NosmaiBackgroundSegmentationConfig(mode: $mode)';
  }
}

/// Validation result for a local filter folder
///
/// Used by [validateLocalFilters] to return detailed information
/// about why a filter may not be loading correctly.
class FilterValidationResult {
  /// The folder name being validated
  final String folderName;

  /// Whether the filter is valid and can be loaded
  final bool isValid;

  /// List of errors that prevent the filter from loading
  final List<String> errors;

  /// List of warnings (non-blocking issues)
  final List<String> warnings;

  /// Path to the .nosmai file (if found)
  final String? nosmaiPath;

  /// Path to the manifest file (if found)
  final String? manifestPath;

  /// Path to the preview image (if found)
  final String? previewPath;

  const FilterValidationResult({
    required this.folderName,
    required this.isValid,
    required this.errors,
    required this.warnings,
    this.nosmaiPath,
    this.manifestPath,
    this.previewPath,
  });

  factory FilterValidationResult.fromMap(Map<String, dynamic> map) {
    return FilterValidationResult(
      folderName: map['folderName']?.toString() ?? '',
      isValid: map['isValid'] as bool? ?? false,
      errors: (map['errors'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      warnings: (map['warnings'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      nosmaiPath: map['nosmaiPath']?.toString(),
      manifestPath: map['manifestPath']?.toString(),
      previewPath: map['previewPath']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'folderName': folderName,
      'isValid': isValid,
      'errors': errors,
      'warnings': warnings,
      'nosmaiPath': nosmaiPath,
      'manifestPath': manifestPath,
      'previewPath': previewPath,
    };
  }

  @override
  String toString() {
    final status = isValid ? '✅' : '❌';
    return 'FilterValidationResult($status $folderName, errors: ${errors.length}, warnings: ${warnings.length})';
  }
}
