import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nosmai_camera_sdk');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    await NosmaiFlutter.instance.cleanup();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'waits for verification and shares a verified session across calls',
    () async {
      final verification = Completer<bool>();
      final received = Completer<void>();
      int attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initWithLicense') {
          attempts++;
          received.complete();
          return verification.future;
        }
        return null;
      });

      final first = NosmaiFlutter.initialize('test-A');
      final second = NosmaiFlutter.initialize('test-A');
      await received.future;
      expect(NosmaiFlutter.instance.isInitialized, isFalse);
      verification.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(attempts, 1);
    },
  );

  test(
    'rejects a conflicting key until cleanup, then verifies the new key',
    () async {
      final keys = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initWithLicense') {
          keys.add(call.arguments['licenseKey'] as String);
          return keys.last != 'denied';
        }
        return null;
      });

      expect(await NosmaiFlutter.initialize('denied'), isFalse);
      expect(await NosmaiFlutter.initialize('test-A'), isTrue);
      expect(await NosmaiFlutter.initialize('test-B'), isFalse);
      expect(NosmaiFlutter.instance.isInitialized, isTrue);
      final cleanup = NosmaiFlutter.instance.cleanup();
      final next = NosmaiFlutter.initialize('test-B');
      await cleanup;
      expect(await next, isTrue);
      expect(keys, ['denied', 'test-A', 'test-B']);
    },
  );

  test('dispose during verification cannot validate a later session', () async {
    final verification = Completer<bool>();
    final received = Completer<void>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initWithLicense') {
        final key = call.arguments['licenseKey'] as String;
        calls.add(key);
        if (key == 'test-A') {
          received.complete();
          return verification.future;
        }
        return true;
      }
      if (call.method == 'cleanup') calls.add('cleanup');
      return null;
    });
    final first = NosmaiFlutter.initialize('test-A');
    await received.future;
    NosmaiFlutter.instance.dispose();
    final next = NosmaiFlutter.initialize('test-B');
    verification.complete(true);
    expect(await first, isFalse);
    expect(await next, isTrue);
    expect(calls, ['test-A', 'cleanup', 'test-B']);
  });

  test(
    'a second dispose cancels initialization queued after the first dispose',
    () async {
      final keys = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initWithLicense') {
          keys.add(call.arguments['licenseKey'] as String);
          return true;
        }
        return null;
      });
      expect(await NosmaiFlutter.initialize('test-A'), isTrue);
      NosmaiFlutter.instance.dispose();
      final pending = NosmaiFlutter.initialize('test-B');
      NosmaiFlutter.instance.dispose();
      expect(await pending, isFalse);
      expect(keys, ['test-A']);
      expect(NosmaiFlutter.instance.isInitialized, isFalse);
    },
  );

  test(
    'opt-out reaches native before initialization and can be reversed',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setPerformanceReportingEnabled') {
          calls.add('reporting=${call.arguments['enabled']}');
        } else if (call.method == 'initWithLicense') {
          calls.add('init');
          return true;
        }
        return null;
      });
      await NosmaiFlutter.setPerformanceReportingEnabled(false);
      expect(await NosmaiFlutter.initialize('test-A'), isTrue);
      await NosmaiFlutter.setPerformanceReportingEnabled(true);
      expect(calls, ['reporting=false', 'init', 'reporting=true']);
    },
  );
}
