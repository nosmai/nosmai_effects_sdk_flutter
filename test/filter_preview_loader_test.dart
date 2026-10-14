import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_effects_sdk/src/preview/filter_preview_loader.dart';

void main() {
  late Directory root;
  final good = Uint8List.fromList([7, 1, 2]);
  Future<bool> validate(Uint8List bytes) async =>
      bytes.isNotEmpty && bytes.first == 7;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nosmai-preview-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<Uint8List?> load(
    FilterPreviewLoader loader, {
    String id = 'one',
    String? stamp,
    String? directory,
    String? preview = 'https://example.invalid/one.png',
    Future<Uint8List?> Function()? package,
  }) =>
      loader.load(
          identity: id,
          preview: preview,
          directory: directory ?? root.path,
          packageStamp: stamp,
          packagePreview: package ?? () async => null);

  test('memory and disk survive loader recreation without network', () async {
    int downloads = 0;
    final first = FilterPreviewLoader(
        validate: validate,
        download: (_) async {
          downloads++;
          return good;
        });
    expect(await load(first), good);
    expect(await load(first), good);
    final second = FilterPreviewLoader(
        validate: validate,
        download: (_) async {
          downloads++;
          throw const SocketException('offline');
        });
    expect(await load(second), good);
    expect(downloads, 1);
  });

  test('corrupt disk thumbnail is replaced from network', () async {
    final first =
        FilterPreviewLoader(validate: validate, download: (_) async => good);
    await load(first);
    final file = root.listSync().whereType<File>().single;
    await file.writeAsBytes([0]);
    int downloads = 0;
    final second = FilterPreviewLoader(
        validate: validate,
        download: (_) async {
          downloads++;
          return good;
        });
    expect(await load(second), good);
    expect(downloads, 1);
  });

  test('failed URL uses cached package fallback without repeated extraction',
      () async {
    int extractions = 0;
    int downloads = 0;
    final loader = FilterPreviewLoader(
        validate: validate,
        download: (_) async {
          downloads++;
          return null;
        });
    Future<Uint8List?> package() async {
      extractions++;
      return good;
    }

    expect(await load(loader, stamp: 'file-v1', package: package), good);
    expect(await load(loader, stamp: 'file-v1', package: package), good);
    expect(extractions, 1);
    expect(downloads, 1);
    int reopenedDownloads = 0;
    final reopened = FilterPreviewLoader(
        validate: validate,
        download: (_) async {
          reopenedDownloads++;
          return null;
        });
    expect(await load(reopened, stamp: 'file-v1', package: package), good);
    expect(reopenedDownloads, 0);
    expect(extractions, 1);
    expect(await load(loader, stamp: 'file-v2', package: package), good);
    expect(extractions, 2);
  });

  test('package is never extracted when a remote image succeeds', () async {
    final loader =
        FilterPreviewLoader(validate: validate, download: (_) async => good);
    expect(
        await load(loader,
            stamp: 'v1',
            package: () async => fail('Unexpected package extraction')),
        good);
  });

  test(
      'oversized and undecodable sources fall back; unavailable package is safe',
      () async {
    final loader = FilterPreviewLoader(
        validate: validate,
        download: (_) async =>
            Uint8List(FilterPreviewLoader.maxImageBytes + 1));
    expect(await load(loader, stamp: 'v1', package: () async => good), good);
    final invalid = FilterPreviewLoader(
        validate: validate, download: (_) async => Uint8List.fromList([0]));
    expect(
        await load(invalid,
            id: 'other', stamp: 'none', package: () async => null),
        isNull);
  });

  test('identical parallel requests share one download', () async {
    int downloads = 0;
    final done = Completer<Uint8List?>();
    final loader = FilterPreviewLoader(
        validate: validate,
        download: (_) {
          downloads++;
          return done.future;
        });
    final futures = List.generate(12, (_) => load(loader));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(downloads, 1);
    done.complete(good);
    expect(await Future.wait(futures), everyElement(good));
  });

  test('concurrency is bounded to three requests', () async {
    int active = 0, peak = 0;
    final loader = FilterPreviewLoader(
        validate: validate,
        download: (_) async {
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          active--;
          return good;
        });
    await Future.wait(List.generate(10, (i) => load(loader, id: 'item-$i')));
    expect(peak, 3);
  });

  test('account directories and filter versions do not share entries',
      () async {
    int downloads = 0;
    final loader = FilterPreviewLoader(
        validate: validate,
        download: (_) async {
          downloads++;
          return good;
        });
    await load(loader, id: 'id-v1', directory: '${root.path}/a');
    await load(loader, id: 'id-v1', directory: '${root.path}/b');
    await load(loader, id: 'id-v2', directory: '${root.path}/a');
    expect(downloads, 3);
  });

  test(
      'expired entries are refetched and cache pruning leaves unrelated files intact',
      () async {
    int downloads = 0;
    final loader = FilterPreviewLoader(
        validate: validate,
        download: (_) async {
          downloads++;
          return good;
        });
    await load(loader);
    final file = root.listSync().whereType<File>().single;
    await file
        .setLastModified(DateTime.now().subtract(const Duration(days: 8)));
    final reopened = FilterPreviewLoader(
        validate: validate,
        download: (_) async {
          downloads++;
          return good;
        });
    await load(reopened);
    expect(downloads, 2);
    final unrelated = File('${root.path}/do-not-delete.nosmai');
    await unrelated.writeAsBytes([1]);
    for (int i = 0; i < 130; i++) {
      await load(reopened, id: 'prune-$i');
    }
    expect(root.listSync().whereType<File>().length, lessThanOrEqualTo(129));
    expect(await unrelated.exists(), isTrue);
  });

  test('legacy encoded image and empty preview remain supported', () async {
    final loader = FilterPreviewLoader(validate: validate);
    expect(await load(loader, preview: 'BwEC'), good);
    expect(await load(loader, preview: 'data:image/png;base64,BwEC'), good);
    expect(
        await load(loader, preview: '', stamp: 'v1', package: () async => good),
        good);
    expect(await load(loader, preview: 'not an image'), isNull);
  });
}
