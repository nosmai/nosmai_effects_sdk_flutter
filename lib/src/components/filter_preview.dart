import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../preview/filter_preview_loader.dart';
import '../types/models.dart';

/// Managed thumbnail for a local or cloud Nosmai filter.
///
/// ```dart
/// NosmaiFilterPreview(filter: filter, width: 80, height: 80)
/// ```
///
/// Reuses a bounded disk cache, loads the URL when needed, then tries a preview
/// from an already-downloaded package. It never downloads/applies a filter.
/// Existing `previewUrl` consumers remain supported; adoption is optional.
/// Requires the updated native plugin for disk cache and package fallback.
class NosmaiFilterPreview extends StatefulWidget {
  const NosmaiFilterPreview({
    super.key,
    required this.filter,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.decodeSize = 256,
    this.placeholder,
    this.errorBuilder,
  });

  final NosmaiFilter filter;
  final double? width;
  final double? height;
  final BoxFit fit;
  final AlignmentGeometry alignment;

  /// Maximum decoded dimension, clamped to 64–512 pixels.
  final int decodeSize;
  final WidgetBuilder? placeholder;
  final WidgetBuilder? errorBuilder;

  @override
  State<NosmaiFilterPreview> createState() => _NosmaiFilterPreviewState();
}

class _NosmaiFilterPreviewState extends State<NosmaiFilterPreview> {
  static const _channel = MethodChannel('nosmai_camera_sdk');
  static final _loader = FilterPreviewLoader(validate: (bytes) async {
    final image = await _decode(bytes, 64);
    image.dispose();
    return true;
  });
  ui.Image? _image;
  bool _loading = true;
  int _generation = 0;

  static Future<ui.Image> _decode(Uint8List bytes, int size) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final longest = descriptor.width > descriptor.height
            ? descriptor.width
            : descriptor.height;
        final scale = longest > size ? size / longest : 1.0;
        final codec = await descriptor.instantiateCodec(
          targetWidth: (descriptor.width * scale).round().clamp(1, size),
          targetHeight: (descriptor.height * scale).round().clamp(1, size),
        );
        try {
          return (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  String _identity(NosmaiFilter filter) => jsonEncode([
        filter.type,
        filter.cloudIdentifier,
        filter.version,
        filter.isCloudFilter ? null : filter.path,
        filter.toMap()['previewUrl'],
      ]);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant NosmaiFilterPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_identity(oldWidget.filter) != _identity(widget.filter) ||
        oldWidget.filter.isDownloaded != widget.filter.isDownloaded ||
        oldWidget.filter.path != widget.filter.path ||
        oldWidget.decodeSize != widget.decodeSize) {
      _image?.dispose();
      _image = null;
      _loading = true;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final filter = widget.filter;
    final size = widget.decodeSize.clamp(64, 512);
    final arguments = <String, dynamic>{
      'filterId': filter.cloudIdentifier,
      'path': filter.path,
      'cloud': filter.isCloudFilter,
    };
    ui.Image? image;
    try {
      Map<dynamic, dynamic>? context;
      try {
        context = await _channel
            .invokeMethod<Map<dynamic, dynamic>>(
                'getFilterPreviewContext', arguments)
            .timeout(const Duration(seconds: 3));
      } on MissingPluginException {
        // Older plugins still support URL/embedded previews without persistence.
      }
      if (!mounted || generation != _generation) return;
      final bytes = await _loader.load(
        identity: _identity(filter),
        preview: filter.toMap()['previewUrl'] as String?,
        directory: context?['directory'] as String?,
        packageStamp: context?['packageStamp'] as String?,
        packagePreview: () => _channel.invokeMethod<Uint8List>(
            'loadFilterPackagePreview',
            {...arguments, 'packageStamp': context?['packageStamp']}),
      );
      if (bytes != null) image = await _decode(bytes, size);
    } catch (_) {
      // The host application controls the final placeholder, not error plumbing.
    }
    if (!mounted || generation != _generation) {
      image?.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fallback = _loading ? widget.placeholder : widget.errorBuilder;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: _image != null
          ? RawImage(
              image: _image, fit: widget.fit, alignment: widget.alignment)
          : fallback?.call(context) ??
              const ColoredBox(
                color: Color(0xFF252525),
                child: Center(
                    child: Icon(Icons.image_outlined, color: Colors.white54)),
              ),
    );
  }
}
