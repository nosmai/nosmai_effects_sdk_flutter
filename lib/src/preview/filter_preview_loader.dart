import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

typedef PreviewDownload = Future<Uint8List?> Function(Uri uri);
typedef PreviewValidate = Future<bool> Function(Uint8List bytes);

/// Internal, bounded thumbnail cache. It never downloads or applies a package.
class FilterPreviewLoader {
  FilterPreviewLoader({PreviewDownload? download, required this.validate})
      : download = download ?? downloadImage;

  static const maxImageBytes = 2 * 1024 * 1024;
  static const maxDiskBytes = 32 * 1024 * 1024;
  static const maxMemoryBytes = 4 * 1024 * 1024;
  static const maxEntries = 128;
  static const maxAge = Duration(days: 7);
  final PreviewDownload download;
  final PreviewValidate validate;
  final _memory = <String, (DateTime, Uint8List)>{};
  final _pending = <String, Future<Uint8List?>>{};
  final _failures = <String, DateTime>{};
  final _waiters = Queue<Completer<void>>();
  int _active = 0;
  int _memoryBytes = 0;

  Future<Uint8List?> load({
    required String identity,
    required String? preview,
    required String? directory,
    required String? packageStamp,
    required Future<Uint8List?> Function() packagePreview,
  }) async {
    final source = preview?.trim() ?? '';
    final uri = Uri.tryParse(source);
    final remote =
        uri != null && (uri.scheme == 'https' || uri.scheme == 'http');
    final primary = sha256
        .convert(utf8.encode(jsonEncode([
          'thumbnail-v1',
          identity,
          source,
        ])))
        .toString();
    final package = sha256
        .convert(utf8.encode(jsonEncode([
          'package-v1',
          identity,
          packageStamp,
        ])))
        .toString();
    final request = '${directory ?? ''}/$primary/$package';
    final running = _pending[request];
    if (running != null) return running;
    if (_pending.length >= maxEntries) return null;
    final task = _limited(() async {
      if (remote) {
        final cached = await _read(directory, primary);
        if (cached != null) return cached;
        if (packageStamp != null) {
          final fallback = await _read(directory, package);
          if (fallback != null) return fallback;
        }
        final bytes =
            await _attempt('${directory ?? ''}/$primary', () => download(uri));
        if (bytes != null) {
          await _write(directory, primary, bytes);
          return bytes;
        }
      } else if (source.isNotEmpty && source.length <= maxImageBytes * 2) {
        try {
          final bytes = base64Decode(source.startsWith('data:')
              ? source.substring(source.indexOf(',') + 1)
              : source);
          if (await _valid(bytes)) return bytes;
        } catch (_) {
          // Invalid legacy data must not prevent package fallback.
        }
      }
      if (packageStamp == null) return null;
      final cached = await _read(directory, package);
      if (cached != null) return cached;
      final bytes =
          await _attempt('${directory ?? ''}/$package', packagePreview);
      if (bytes != null) await _write(directory, package, bytes);
      return bytes;
    });
    _pending[request] = task;
    try {
      return await task;
    } finally {
      _pending.remove(request);
    }
  }

  Future<T> _limited<T>(Future<T> Function() work) async {
    if (_active >= 3) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      return await work();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }

  Future<bool> _valid(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxImageBytes) return false;
    try {
      return await validate(bytes);
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> _attempt(
      String key, Future<Uint8List?> Function() read) async {
    final failed = _failures[key];
    if (failed != null &&
        DateTime.now().difference(failed) < const Duration(seconds: 30)) {
      return null;
    }
    try {
      final bytes = await read().timeout(const Duration(seconds: 10));
      if (bytes != null && await _valid(bytes)) {
        _failures.remove(key);
        return bytes;
      }
    } catch (_) {
      // Unavailable sources fall through to the next preview source.
    }
    if (_failures.length >= maxEntries) _failures.remove(_failures.keys.first);
    _failures[key] = DateTime.now();
    return null;
  }

  Future<Uint8List?> _read(String? directory, String key) async {
    if (directory == null) return null;
    final scoped = '$directory/$key';
    final hit = _memory.remove(scoped);
    if (hit != null) {
      _memoryBytes -= hit.$2.length;
      if (DateTime.now().difference(hit.$1) < maxAge) {
        _remember(scoped, hit.$2, hit.$1);
        return hit.$2;
      }
    }
    try {
      final file = File(scoped);
      final stat = await file.stat();
      final age = DateTime.now().difference(stat.modified);
      if (stat.type != FileSystemEntityType.file ||
          stat.size > maxImageBytes ||
          stat.size <= 0 ||
          age > maxAge ||
          age.isNegative) {
        return null;
      }
      final bytes = await file.readAsBytes();
      if (await _valid(bytes)) {
        _remember(scoped, bytes, stat.modified);
        return bytes;
      }
      await file.delete();
    } catch (_) {
      // Cache eviction or storage failure must not prevent network loading.
    }
    return null;
  }

  void _remember(String key, Uint8List bytes, DateTime time) {
    final previous = _memory.remove(key);
    if (previous != null) _memoryBytes -= previous.$2.length;
    _memory[key] = (time, bytes);
    _memoryBytes += bytes.length;
    while (_memoryBytes > maxMemoryBytes || _memory.length > maxEntries) {
      _memoryBytes -= _memory.remove(_memory.keys.first)!.$2.length;
    }
  }

  Future<void> _write(String? directory, String key, Uint8List bytes) async {
    if (directory == null) return;
    final path = '$directory/$key';
    _remember(path, bytes, DateTime.now());
    try {
      final root = await Directory(directory).create(recursive: true);
      final temporary = File('$path.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(path);
      final entries = <(File, FileStat)>[];
      await for (final entry in root.list(followLinks: false)) {
        final name = entry.uri.pathSegments.last;
        if (entry is! File || !RegExp(r'^[a-f0-9]{64}$').hasMatch(name)) {
          continue;
        }
        try {
          entries.add((entry, await entry.stat()));
        } catch (_) {}
      }
      entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      int total = entries.fold(0, (sum, item) => sum + item.$2.size);
      int count = entries.length;
      for (final item in entries) {
        final expired = DateTime.now().difference(item.$2.modified) > maxAge;
        if (item.$1.path == path ||
            (!expired && count <= maxEntries && total <= maxDiskBytes)) {
          continue;
        }
        try {
          await item.$1.delete();
          count--;
          total -= item.$2.size;
        } catch (_) {}
      }
    } catch (_) {
      // Persistence is optional when the OS denies or clears cache storage.
    }
  }

  static Future<Uint8List?> downloadImage(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    Future<Uint8List?> read() async {
      var target = uri;
      for (var redirects = 0; redirects <= 3; redirects++) {
        if (target.scheme != 'https' && target.scheme != 'http') return null;
        if (uri.scheme == 'https' && target.scheme != 'https') return null;
        final request = await client.getUrl(target);
        request.followRedirects = false;
        final response = await request.close();
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) return null;
          target = target.resolve(location);
          continue;
        }
        if (response.statusCode != 200 ||
            response.contentLength > maxImageBytes) {
          return null;
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (builder.length + chunk.length > maxImageBytes) return null;
          builder.add(chunk);
        }
        return builder.takeBytes();
      }
      return null;
    }

    try {
      return await read().timeout(const Duration(seconds: 8));
    } finally {
      client.close(force: true);
    }
  }
}
