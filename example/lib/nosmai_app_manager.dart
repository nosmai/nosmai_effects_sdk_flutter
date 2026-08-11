import 'package:flutter/material.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

/// Singleton manager for Nosmai SDK lifecycle management
///
/// This class ensures the Nosmai SDK is properly initialized once for the entire
/// application and provides centralized access to the SDK instance. It handles
/// initialization, error states, and performance optimizations like camera pre-warming.
///
/// Example usage:
/// ```dart
/// // Initialize the SDK
/// final success = await NosmaiAppManager.instance.initialize('your_api_key');
/// if (success) {
///   // Use the SDK
///   final nosmai = NosmaiAppManager.instance.nosmai;
/// }
/// ```
class NosmaiAppManager {
  /// Private constructor for singleton pattern
  NosmaiAppManager._internal();

  /// Singleton instance
  static final NosmaiAppManager _instance = NosmaiAppManager._internal();

  /// Get the singleton instance
  static NosmaiAppManager get instance => _instance;

  /// Internal SDK instance
  final NosmaiFlutter _nosmai = NosmaiFlutter.instance;

  /// Initialization state
  bool _isInitialized = false;

  /// Error message if initialization failed
  String? _initError;

  /// Get the Nosmai SDK instance
  ///
  /// Only use this after successful initialization
  NosmaiFlutter get nosmai => _nosmai;

  /// Check if SDK is initialized
  bool get isInitialized => _isInitialized;

  /// Get initialization error if any
  String? get initError => _initError;

  /// Initialize the Nosmai SDK with the provided license key
  ///
  /// This method ensures the SDK is initialized only once. If already initialized,
  /// it returns true immediately. After successful initialization, it automatically
  /// pre-warms the camera for better performance.
  ///
  /// [licenseKey] - Your Nosmai API license key
  ///
  /// Returns true if initialization was successful, false otherwise.
  /// Check [initError] for error details on failure.
  Future<bool> initialize(String licenseKey) async {
    if (_isInitialized) {
      debugPrint('✅ Nosmai SDK already initialized');
      return true;
    }

    try {
      debugPrint('🚀 Initializing Nosmai SDK...');
      final success = await NosmaiFlutter.initialize(licenseKey);

      if (success) {
        _isInitialized = true;
        _initError = null;
        debugPrint('✅ Nosmai SDK initialized successfully');

        // Pre-warm camera for faster startup
        _prewarmCamera();
      } else {
        _isInitialized = false;
        _initError = 'Failed to initialize SDK with license';
        debugPrint('❌ Nosmai SDK initialization failed');
      }

      return success;
    } catch (e) {
      _isInitialized = false;
      _initError = e.toString();
      debugPrint('❌ Nosmai SDK initialization error: $e');
      return false;
    }
  }

  void _prewarmCamera() {
    Future.microtask(() async {
      try {
        final stopwatch = Stopwatch()..start();
        debugPrint('⏱️ Starting camera pre-warming...');

        // Pre-configure front camera (most commonly used first)
        final configStart = Stopwatch()..start();
        await _nosmai.configureCamera(
          position: NosmaiCameraPosition.front,
        );
        configStart.stop();
        debugPrint(
            '⏱️ Pre-warming: Camera config took ${configStart.elapsedMilliseconds}ms');

        // Pre-start processing for instant camera
        final processingStart = Stopwatch()..start();
        await _nosmai.startProcessing();
        processingStart.stop();
        debugPrint(
            '⏱️ Pre-warming: Processing start took ${processingStart.elapsedMilliseconds}ms');

        // Pre-load essential filters in background
        _preloadEssentialFilters();

        stopwatch.stop();
        debugPrint(
            '📷 Camera pre-warmed and ready in ${stopwatch.elapsedMilliseconds}ms');
      } catch (e) {
        debugPrint('⚠️ Camera pre-warming failed: $e');
      }
    });
  }

  /// Pre-load essential filters for faster access
  ///
  /// This method pre-loads local filters in the background to improve
  /// performance when users first access the filter interface.
  void _preloadEssentialFilters() {
    Future.microtask(() async {
      try {
        // Pre-load only local filters (fast)
        await _nosmai.getLocalFilters();
        debugPrint('🎭 Essential filters pre-loaded');
      } catch (e) {
        debugPrint('⚠️ Filter pre-loading failed: $e');
      }
    });
  }

  /// Clean up the SDK resources
  ///
  /// Call this method only when the app is terminating to properly
  /// dispose of SDK resources and prevent memory leaks.
  Future<void> cleanup() async {
    if (_isInitialized) {
      await _nosmai.cleanup();
      _isInitialized = false;
      debugPrint('🧹 Nosmai SDK cleaned up');
    }
  }
}
