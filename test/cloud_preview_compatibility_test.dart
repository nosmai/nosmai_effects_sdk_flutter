import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_effects_sdk/src/platform/method_channel.dart';
import 'package:nosmai_effects_sdk/src/types/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'https://example.invalid/preview.png?signature=unchanged';
  const encoded = 'aW1hZ2U=';

  NosmaiFilter parse(Map<String, dynamic> values) => NosmaiFilter.fromMap({
        'id': 'cloud-preview',
        'name': 'Cloud Preview',
        'type': 'cloud',
        ...values,
      });

  test('cloud URL is unchanged before and after a native cache hit', () {
    final cold = parse({'previewUrl': url});
    final warm = parse({
      'previewUrl': url,
      'previewImageBase64': encoded,
    });
    expect(cold.previewUrl, url);
    expect(warm.previewUrl, cold.previewUrl);
    expect(warm.toMap()['previewUrl'], url);
  });

  test('cloud thumbnail URL takes precedence over cached image data', () {
    expect(
        parse({
          'thumbnailUrl': url,
          'previewImageBase64': encoded,
        }).previewUrl,
        url);
  });

  test('empty cloud preview fields do not hide a thumbnail URL', () {
    for (final empty in [null, '', '   ']) {
      expect(
          parse({
            'previewUrl': empty,
            'thumbnailUrl': url,
            'previewImageBase64': encoded,
          }).previewUrl,
          url);
    }
  });

  test('explicit cloud preview URL retains precedence over thumbnail', () {
    expect(
        parse({
          'previewUrl': url,
          'thumbnailUrl': 'https://example.invalid/other.png',
          'previewImageBase64': encoded,
        }).previewUrl,
        url);
  });

  test('local encoded preview behavior is unchanged', () {
    expect(
        parse({
          'type': 'local',
          'previewUrl': url,
          'previewImageBase64': encoded,
        }).previewUrl,
        encoded);
  });

  test('legacy image-only cloud preview remains supported', () {
    expect(parse({'previewImageBase64': encoded}).previewUrl, encoded);
    expect(parse({}).previewUrl, isNull);
  });

  test('existing cloud channel call needs no cache argument or new method',
      () async {
    const channel = MethodChannel('nosmai_camera_sdk');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getCloudFilters');
      expect(call.arguments, {'fetchAllPages': true, 'version': '2.0.0'});
      return {
        'filters': [
          {'id': 'cloud-preview', 'type': 'cloud', 'previewUrl': url},
        ],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final filters = await MethodChannelNosmaiFlutter().getCloudFilters();
    expect(
        NosmaiFilter.fromMap(Map<String, dynamic>.from(filters.single))
            .previewUrl,
        url);
  });
}
