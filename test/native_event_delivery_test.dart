import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';
import 'package:nosmai_effects_sdk/src/platform/method_channel.dart';
import 'package:nosmai_effects_sdk/src/platform/platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nosmai_camera_sdk');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final sdk = NosmaiFlutter.instance;
  final calls = <MethodCall>[];
  final subscriptions = <StreamSubscription<dynamic>>[];
  late NosmaiFlutterPlatform previousPlatform;

  Future<void> native(String method, [Object? arguments]) async {
    final response = Completer<void>();
    // Exercise the same native-to-Dart channel used by Android and iOS.
    // ignore: deprecated_member_use
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (reply) {
        try {
          if (reply != null) codec.decodeEnvelope(reply);
          response.complete();
        } catch (error, stack) {
          response.completeError(error, stack);
        }
      },
    );
    await response.future;
  }

  Future<void> emitEvents() async {
    await native('onError', {'code': 'CAMERA_UNAVAILABLE', 'message': 'Busy'});
    await native('onDownloadProgress', {
      'filterId': 'sample',
      'progress': 0.5,
      'bytesDownloaded': 50,
      'totalBytes': 100,
    });
    await native('onRecordingProgress', {'duration': 2.5});
    await native('onLicenseStatusChanged', {'status': 'valid'});
    await native('onActiveEffectsChanged', {'modeName': 'effectsFilters'});
    await native('onPipelineStateChanged', {'modeName': 'idle'});
    await native('onGameEvent', {
      'event': 'score',
      'game': 'sample',
      'sequence': 1,
      'data': {'score': 4},
    });
    await native('onCameraProcessingStopped');
    await pumpEventQueue();
  }

  for (final target in [TargetPlatform.android, TargetPlatform.iOS]) {
    group(target.name, () {
      setUp(() async {
        debugDefaultTargetPlatformOverride = target;
        previousPlatform = NosmaiFlutterPlatform.instance;
        NosmaiFlutterPlatform.instance = MethodChannelNosmaiFlutter();
        calls.clear();
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'initWithLicense':
            case 'startRecording':
            case 'setGameEventListenerEnabled':
              return true;
            case 'getLocalFilters':
              return <dynamic>[];
            case 'stopRecording':
              return {'success': true, 'duration': 0.0, 'fileSize': 0};
            default:
              return null;
          }
        });
        expect(await NosmaiFlutter.initialize('test-license'), isTrue);
        await pumpEventQueue();
      });

      tearDown(() async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        subscriptions.clear();
        await sdk.cleanup();
        sdk.dispose();
        await pumpEventQueue();
        messenger.setMockMethodCallHandler(channel, null);
        NosmaiFlutterPlatform.instance = previousPlatform;
        debugDefaultTargetPlatformOverride = null;
      });

      test(
          'grayscale toggle uses the boolean contract and preserves legacy calls',
          () async {
        calls.clear();
        await sdk.setGrayscaleEnabled(true);
        await sdk.setGrayscaleEnabled(false);
        await sdk.applyGrayscaleFilter();
        // ignore: deprecated_member_use_from_same_package
        await sdk.removeBuiltInFilterByName('GrayscaleFilter');
        expect(calls.map((call) => call.method), [
          'setGrayscaleEnabled',
          'setGrayscaleEnabled',
          'applyGrayscaleFilter',
          'removeBuiltInFilterByName',
        ]);
        expect(calls[0].arguments, {'enabled': true});
        expect(calls[1].arguments, {'enabled': false});
        expect(calls[3].arguments, {'filterName': 'GrayscaleFilter'});
      });

      test(
          'grayscale toggle reports native failures and requires initialization',
          () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'setGrayscaleEnabled') {
            throw PlatformException(code: 'PREVIEW_NOT_READY');
          }
          return null;
        });
        await expectLater(
            sdk.setGrayscaleEnabled(true),
            throwsA(
              isA<PlatformException>()
                  .having((error) => error.code, 'code', 'PREVIEW_NOT_READY'),
            ));
        await sdk.cleanup();
        await expectLater(
            sdk.setGrayscaleEnabled(false), throwsA(isA<NosmaiError>()));
      });

      test('native callbacks reach every public stream and update state',
          () async {
        final errors = <NosmaiError>[];
        final downloads = <NosmaiDownloadProgress>[];
        final durations = <double>[];
        final licenses = <NosmaiLicenseStatus>[];
        final states = <NosmaiActiveEffects>[];
        final games = <NosmaiGameEvent>[];
        subscriptions.addAll([
          sdk.onError.listen(errors.add),
          sdk.onDownloadProgress.listen(downloads.add),
          sdk.onRecordingProgress.listen(durations.add),
          sdk.onLicenseStatusChanged.listen(licenses.add),
          sdk.onActiveEffectsChanged.listen(states.add),
          sdk.onGameEvent.listen(games.add),
        ]);
        await sdk.startProcessing();
        expect(await sdk.startRecording(), isTrue);
        expect(sdk.isProcessing, isTrue);
        expect(sdk.isRecording, isTrue);

        await emitEvents();

        expect(errors.single.code, 'CAMERA_UNAVAILABLE');
        expect(downloads.single.filterId, 'sample');
        expect(downloads.single.progress, 0.5);
        expect(durations, [2.5]);
        expect(licenses, [NosmaiLicenseStatus.valid]);
        expect(states.map((state) => state.activeMode), [
          NosmaiActiveEffectsMode.effectsFilters,
          NosmaiActiveEffectsMode.idle,
        ]);
        expect(games.single.data, {'score': 4});
        expect(sdk.isProcessing, isFalse);
        expect(sdk.isRecording, isFalse);
        expect(
            calls.any((call) =>
                call.method == 'setGameEventListenerEnabled' &&
                call.arguments['enabled'] == true),
            isTrue);
        await subscriptions.removeLast().cancel();
        await pumpEventQueue();
        expect(
            calls
                .lastWhere(
                    (call) => call.method == 'setGameEventListenerEnabled')
                .arguments['enabled'],
            isFalse);
      });

      test(
          'late callbacks are ignored after dispose and work after reinitialize',
          () async {
        final oldErrors = <NosmaiError>[];
        subscriptions.add(sdk.onError.listen(oldErrors.add));
        await sdk.cleanup();
        sdk.dispose();
        await pumpEventQueue();
        await emitEvents();
        expect(oldErrors, isEmpty);

        expect(await NosmaiFlutter.initialize('test-license'), isTrue);
        final errors = <NosmaiError>[];
        final games = <NosmaiGameEvent>[];
        subscriptions.add(sdk.onError.listen(errors.add));
        subscriptions.add(sdk.onGameEvent.listen(games.add));
        await emitEvents();
        expect(errors, hasLength(1));
        expect(games, hasLength(1));
        expect(oldErrors, isEmpty);
      });
    });
  }
}
