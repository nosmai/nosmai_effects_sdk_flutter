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

  test('game cloud filters use the games API bucket', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getCloudFilters');
      expect(call.arguments['filterType'], 'games');
      return <String, dynamic>{'filters': <dynamic>[], 'pagination': null};
    });

    await platform.getCloudFiltersWithOptions(
      filterType: NosmaiCloudFilterType.games,
      page: 1,
      fetchAllPages: false,
    );
  });

  test('game model keeps the game package type', () {
    final game = NosmaiFilter.fromMap({
      'id': 'fruit-catcher',
      'name': 'Fruit Catcher',
      'type': 'cloud',
      'filterType': 'games',
    });

    expect(game.isGame, isTrue);
    expect(game.sourceType, NosmaiFilterSourceType.game);
    expect(game.localFilterType, NosmaiLocalFilterType.game);
  });

  test('game events require a complete JSON-safe envelope', () {
    final event = NosmaiGameEvent.fromMap({
      'event': 'scoreChanged',
      'game': 'fruit-catcher',
      'sequence': 7,
      'data': {'score': 42},
    });

    expect(event.event, 'scoreChanged');
    expect(event.sequence, 7);
    expect(event.data, {'score': 42});
    expect(
      () => NosmaiGameEvent.fromMap({
        'event': '',
        'game': 'fruit-catcher',
        'sequence': 8,
        'data': <String, dynamic>{},
      }),
      throwsFormatException,
    );
  });

  test('active game is not reported as a normal effect', () {
    final game = NosmaiFilter.fromMap({
      'id': 'fruit-catcher',
      'type': 'local',
      'filterType': 'game',
    });
    final state = NosmaiActiveEffects(
      mode: 1,
      modeName: 'effectsFilters',
      activeMode: NosmaiActiveEffectsMode.effectsFilters,
      activeEffectPath: '/filters/fruit-catcher.nosmai',
      hasBackground: false,
      backgroundSource: 0,
      backgroundSourceName: 'none',
      activeBackgroundSource: NosmaiActiveBackgroundSource.none,
      hasBeautyEffect: false,
      hasManualBackground: false,
      activeEffect: game,
    );

    expect(state.hasActiveGame, isTrue);
    expect(state.hasEffect, isFalse);
    expect(state.hasArPackage, isTrue);
  });

  test('game input uses normalized method-channel arguments', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'sendGameInput');
      expect(call.arguments, {
        'name': 'flap',
        'x': 0.25,
        'y': 0.75,
        'value': 1.0,
      });
      return true;
    });

    await expectLater(
      platform.sendGameInput('flap', 0.25, 0.75, 1.0),
      completion(isTrue),
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
