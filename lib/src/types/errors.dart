/// Nosmai Flutter Plugin Error Types
///
/// This file contains all the error types and error handling utilities.
library;

import 'enums.dart';

/// Base error class for Nosmai SDK
class NosmaiError implements Exception {
  final NosmaiErrorType type;
  final String code;
  final String message;
  final String? details;
  final dynamic originalError;
  final StackTrace? stackTrace;

  const NosmaiError({
    required this.type,
    required this.code,
    required this.message,
    this.details,
    this.originalError,
    this.stackTrace,
  });

  factory NosmaiError.fromMap(Map<String, dynamic> map) {
    final codeString = map['code']?.toString() ?? 'UNKNOWN_ERROR';
    final type = _parseErrorType(codeString);

    return NosmaiError(
      type: type,
      code: codeString,
      message: map['message']?.toString() ?? 'Unknown error occurred',
      details: map['details']?.toString(),
    );
  }

  /// Create a license-related error
  factory NosmaiError.license({
    required NosmaiErrorType type,
    required String message,
    String? details,
  }) {
    return NosmaiError(
      type: type,
      code: type.name.toUpperCase(),
      message: message,
      details: details,
    );
  }

  /// Create a camera-related error
  factory NosmaiError.camera({
    required NosmaiErrorType type,
    required String message,
    String? details,
  }) {
    return NosmaiError(
      type: type,
      code: type.name.toUpperCase(),
      message: message,
      details: details,
    );
  }

  /// Create a filter-related error
  factory NosmaiError.filter({
    required NosmaiErrorType type,
    required String message,
    String? details,
  }) {
    return NosmaiError(
      type: type,
      code: type.name.toUpperCase(),
      message: message,
      details: details,
    );
  }

  /// Create a recording-related error
  factory NosmaiError.recording({
    required NosmaiErrorType type,
    required String message,
    String? details,
  }) {
    return NosmaiError(
      type: type,
      code: type.name.toUpperCase(),
      message: message,
      details: details,
    );
  }

  /// Create a general error
  factory NosmaiError.general({
    required NosmaiErrorType type,
    required String message,
    String? details,
    dynamic originalError,
    StackTrace? stackTrace,
  }) {
    return NosmaiError(
      type: type,
      code: type.name.toUpperCase(),
      message: message,
      details: details,
      originalError: originalError,
      stackTrace: stackTrace,
    );
  }

  /// Check if this error is recoverable
  bool get isRecoverable {
    switch (type) {
      case NosmaiErrorType.networkError:
      case NosmaiErrorType.operationTimeout:
        return true;
      case NosmaiErrorType.invalidLicense:
      case NosmaiErrorType.licenseExpired:
      case NosmaiErrorType.sdkNotInitialized:
        return false;
      default:
        return true;
    }
  }

  /// User-friendly message for display
  String get userMessage {
    switch (type) {
      case NosmaiErrorType.cameraPermissionDenied:
        return 'Camera permission is required to use this feature. Please grant permission in your device settings.';
      case NosmaiErrorType.cameraUnavailable:
        return 'Camera is not available on this device.';
      case NosmaiErrorType.cameraSwitchFailed:
        return 'Failed to switch camera. Please try again.';
      case NosmaiErrorType.invalidLicense:
        return 'Invalid license key. Please check your license.';
      case NosmaiErrorType.licenseExpired:
        return 'License has expired. Please renew your license.';
      case NosmaiErrorType.networkError:
        return 'Network error. Please check your connection and try again.';
      case NosmaiErrorType.operationTimeout:
        return 'Operation timed out. Please try again.';
      case NosmaiErrorType.sdkNotInitialized:
        return 'SDK not initialized. Please initialize the SDK first.';
      default:
        return message;
    }
  }

  /// Recovery actions that can be taken
  List<String> get recoveryActions {
    switch (type) {
      case NosmaiErrorType.cameraPermissionDenied:
        return [
          'Go to Settings > Privacy > Camera',
          'Enable camera access for this app',
          'Return to the app and try again'
        ];
      case NosmaiErrorType.networkError:
        return [
          'Check your internet connection',
          'Try again in a few moments',
          'Restart the app if the problem persists'
        ];
      case NosmaiErrorType.operationTimeout:
        return [
          'Try the operation again',
          'Check your network connection',
          'Restart the app if the problem persists'
        ];
      case NosmaiErrorType.invalidLicense:
      case NosmaiErrorType.licenseExpired:
        return [
          'Contact support for license assistance',
          'Check your license key',
          'Renew your license if expired'
        ];
      default:
        return ['Try again', 'Restart the app if the problem persists'];
    }
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('NosmaiError(');
    buffer.write('type: $type, ');
    buffer.write('code: $code, ');
    buffer.write('message: $message');
    if (details != null) {
      buffer.write(', details: $details');
    }
    buffer.write(')');
    return buffer.toString();
  }
}

/// Helper function to parse error type from string
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
      return NosmaiErrorType.networkError;
    case 'INVALID_PARAMETER':
      return NosmaiErrorType.invalidParameter;
    default:
      return NosmaiErrorType.unknown;
  }
}

/// Retry manager for handling failed operations
class NosmaiRetryManager {
  /// Execute an operation with retry logic
  static Future<T> executeWithRetry<T>(
    Future<T> Function() operation, {
    int maxRetries = 3,
    Duration delay = const Duration(seconds: 1),
    bool Function(dynamic error)? shouldRetry,
  }) async {
    int attempts = 0;

    while (attempts < maxRetries) {
      try {
        return await operation();
      } catch (error) {
        attempts++;

        if (attempts >= maxRetries) {
          rethrow;
        }

        if (shouldRetry != null && !shouldRetry(error)) {
          rethrow;
        }

        await Future.delayed(delay);
      }
    }

    throw StateError('Max retry attempts exceeded');
  }
}
