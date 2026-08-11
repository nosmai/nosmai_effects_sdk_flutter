import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_effects_sdk/src/platform/method_channel.dart';
import 'package:nosmai_effects_sdk/src/types/enums.dart';
import 'package:nosmai_effects_sdk/src/types/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('nosmai_camera_sdk');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MethodChannelNosmaiFlutter platform;

  setUp(() {
    platform = MethodChannelNosmaiFlutter();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('initialization propagates a native platform error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'INVALID_LICENSE');
    });

    await expectLater(
      platform.initWithLicense('invalid'),
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'INVALID_LICENSE'),
      ),
    );
  });

  test('cloud filters propagate network errors', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'NETWORK_UNAVAILABLE');
    });

    await expectLater(
      platform.getCloudFiltersWithOptions(
        filterType: NosmaiCloudFilterType.effects,
        page: 1,
        limit: 20,
        fetchAllPages: false,
      ),
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'NETWORK_UNAVAILABLE'),
      ),
    );
  });

  test('cloud filters send the default catalog version', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getCloudFilters');
      expect(call.arguments['version'], '2.0.0');
      return <String, dynamic>{'filters': <dynamic>[], 'pagination': null};
    });

    await platform.getCloudFiltersWithOptions();
  });

  test('beauty cloud filters use the canonical API bucket', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getCloudFilters');
      expect(call.arguments['filterType'], 'beauty_effect');
      return <String, dynamic>{'filters': <dynamic>[], 'pagination': null};
    });

    await platform.getCloudFiltersWithOptions(
      filterType: NosmaiCloudFilterType.beautyEffect,
      page: 1,
      fetchAllPages: false,
    );
  });

  test('cloud model keeps backend id but exposes downloadable filter id', () {
    final filter = NosmaiFilter.fromMap({
      'id': 'backend-record-uuid',
      'filterId': 'special-effects_void_eyes_2039',
      'name': 'Void Eyes',
      'type': 'cloud',
      'filterType': 'effect',
    });

    expect(filter.id, 'special-effects_void_eyes_2039');
    expect(filter.filterId, 'special-effects_void_eyes_2039');
    expect(filter.backendId, 'backend-record-uuid');
    expect(filter.cloudIdentifier, 'special-effects_void_eyes_2039');
  });

  test('applyEffect propagates native apply failures', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'EFFECT_LOAD_ERROR');
    });

    await expectLater(
      platform.applyEffect('/tmp/filter.nosmai'),
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'EFFECT_LOAD_ERROR'),
      ),
    );
  });

  test('filter parameter preserves current, default, range, and options', () {
    final parameter = FilterParameter.fromMap({
      'name': 'preset',
      'type': 'string',
      'displayName': 'Preset',
      'description': 'Select a packaged preset',
      'currentValue': 'soft',
      'defaultValue': 'natural',
      'hasRange': false,
      'minValue': 0,
      'maxValue': 1,
      'options': ['natural', 'soft'],
      'passId': 0,
    });

    expect(parameter.name, 'preset');
    expect(parameter.displayName, 'Preset');
    expect(parameter.currentValue, 'soft');
    expect(parameter.defaultValue, 'natural');
    expect(parameter.options, ['natural', 'soft']);
    expect(parameter.minValue, 0.0);
    expect(parameter.maxValue, 1.0);
  });
}
