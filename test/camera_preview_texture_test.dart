import 'dart:async';

import 'package:flutter/material.dart';
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
  final calls = <MethodCall>[];
  late NosmaiFlutterPlatform previousPlatform;
  late int nextId;
  Object? createResult;
  Future<Object?>? pendingCreation;
  bool bindSucceeds = true;
  bool bindThrows = false;
  Future<Object?>? pendingReinitialize;

  Future<void> native(String method, [Object? arguments]) async {
    final response = Completer<void>();
    // Simulate the real native-to-Dart method-channel delivery.
    // ignore: deprecated_member_use
    messenger.handlePlatformMessage(
      'nosmai_camera_sdk',
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {
        response.complete();
      },
    );
    await response.future;
  }

  Future<void> visible(int id, bool value) => native('onPreviewStateChanged', {
        'textureId': id,
        'visible': value,
        'error': null,
      });
  Future<void> ready(int id) async {
    await visible(id, true);
    await native('onCameraReady');
  }

  Future<void> mount(
    WidgetTester tester, {
    Key? key,
    VoidCallback? onInitialized,
    Function(String)? onError,
    NosmaiCameraPreviewController? controller,
    NosmaiGameTapCallback? onGameTap,
    bool enableGameTapHandling = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NosmaiCameraPreview(
          key: key,
          onInitialized: onInitialized,
          onError: onError,
          controller: controller,
          onGameTap: onGameTap,
          enableGameTapHandling: enableGameTapHandling,
        ),
      ),
    );
    await tester.pump();
  }

  setUp(() async {
    previousPlatform = NosmaiFlutterPlatform.instance;
    NosmaiFlutterPlatform.instance = MethodChannelNosmaiFlutter();
    calls.clear();
    nextId = 1 << 34;
    createResult = null;
    pendingCreation = null;
    bindSucceeds = true;
    bindThrows = false;
    pendingReinitialize = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'createTexture':
          return pendingCreation ?? createResult ?? nextId++;
        case 'setRenderSurface':
          if (bindThrows) throw PlatformException(code: 'SURFACE_ERROR');
          return bindSucceeds;
        case 'clearRenderSurface':
          return true;
        case 'initWithLicense':
          return true;
        case 'getLocalFilters':
          return <Object?>[];
        case 'pauseCamera':
        case 'resumeCamera':
          return true;
        case 'reinitializePreview':
          return pendingReinitialize;
        case 'isGameReady':
          return true;
        case 'sendGameTap':
          return true;
        default:
          return null;
      }
    });
    await NosmaiFlutter.initialize('unit-test-license');
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    NosmaiFlutterPlatform.instance = previousPlatform;
  });

  testWidgets(
    'Android uses a 64-bit Texture and waits for its own GPU output',
    (tester) async {
      final controller = NosmaiCameraPreviewController();
      int notifications = 0;
      await mount(
        tester,
        controller: controller,
        onInitialized: () {
          notifications++;
        },
      );
      final texture = tester.widget<Texture>(find.byType(Texture));
      expect(texture.textureId, 1 << 34);
      expect(find.byType(AndroidView), findsNothing);
      expect(
        find.byKey(const ValueKey('nosmai-preview-cover')),
        findsOneWidget,
      );
      expect(calls.firstWhere((c) => c.method == 'createTexture').arguments, {
        'width': 720.0,
        'height': 1280.0,
      });
      expect(
        calls.firstWhere((c) => c.method == 'setRenderSurface').arguments,
        {'textureId': texture.textureId, 'width': 720.0, 'height': 1280.0},
      );
      await native('onCameraReady');
      await tester.pump();
      expect(controller.isInitialized, false);
      await ready(texture.textureId + 1);
      await tester.pump();
      expect(notifications, 0);
      await ready(texture.textureId);
      await tester.pump();
      expect(controller.isInitialized, true);
      expect(notifications, 1);
      expect(find.byKey(const ValueKey('nosmai-preview-cover')), findsNothing);
      await ready(texture.textureId);
      await tester.pump();
      expect(notifications, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(
        calls.where((c) => c.method == 'clearRenderSurface').single.arguments,
        {'textureId': texture.textureId},
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'late texture allocation after disposal is released without binding',
    (tester) async {
      final response = Completer<Object?>();
      pendingCreation = response.future;
      await mount(tester);
      await tester.pumpWidget(const SizedBox());
      response.complete(701);
      await tester.pump();
      await tester.pump();
      expect(calls.where((c) => c.method == 'setRenderSurface'), isEmpty);
      expect(
        calls.where((c) => c.method == 'clearRenderSurface').single.arguments,
        {'textureId': 701},
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'overlapping routes release only their own texture and ignore old state',
    (tester) async {
      int notifications = 0;
      await mount(tester, key: const ValueKey('first'));
      final first = tester.widget<Texture>(find.byType(Texture)).textureId;
      await ready(first);
      await tester.pump();
      await mount(
        tester,
        key: const ValueKey('second'),
        onInitialized: () {
          notifications++;
        },
      );
      final second = tester.widget<Texture>(find.byType(Texture)).textureId;
      expect(second, isNot(first));
      expect(
        calls.where((c) => c.method == 'clearRenderSurface').single.arguments,
        {'textureId': first},
      );
      await ready(first);
      await tester.pump();
      expect(notifications, 0);
      await ready(second);
      await tester.pump();
      expect(notifications, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(
        calls.where((c) => c.method == 'clearRenderSurface').last.arguments,
        {'textureId': second},
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'binding failure is surfaced, releases output and supports Retry',
    (tester) async {
      bindSucceeds = false;
      final errors = <String>[];
      await mount(tester, onError: errors.add);
      await tester.pump();
      expect(errors.single, contains('could not be attached'));
      expect(find.text('Camera Error'), findsOneWidget);
      expect(calls.where((c) => c.method == 'clearRenderSurface').length, 1);
      bindSucceeds = true;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      final id = tester.widget<Texture>(find.byType(Texture)).textureId;
      await ready(id);
      await tester.pump();
      expect(find.text('Camera Error'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'native binding errors reach onError and are not converted to ready',
    (tester) async {
      bindThrows = true;
      final errors = <String>[];
      await mount(tester, onError: errors.add);
      await tester.pump();
      expect(errors.single, contains('SURFACE_ERROR'));
      expect(find.byType(Texture), findsNothing);
      expect(calls.where((c) => c.method == 'clearRenderSurface').length, 1);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('startup timeout releases the native producer', (tester) async {
    final errors = <String>[];
    await mount(tester, onError: errors.add);
    await tester.pump(const Duration(seconds: 13));
    await tester.pump();
    expect(errors.single, contains('did not become ready'));
    expect(calls.where((c) => c.method == 'clearRenderSurface').length, 1);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'switch and resume gates hide old frames without reallocating output',
    (tester) async {
      int notifications = 0;
      await mount(
        tester,
        onInitialized: () {
          notifications++;
        },
      );
      final id = tester.widget<Texture>(find.byType(Texture)).textureId;
      await ready(id);
      await tester.pump();
      await visible(id, false);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('nosmai-preview-cover')),
        findsOneWidget,
      );
      await ready(id);
      await tester.pump();
      expect(notifications, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(calls.any((c) => c.method == 'pauseCamera'), true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.any((c) => c.method == 'resumeCamera'), true);
      expect(
        find.byKey(const ValueKey('nosmai-preview-cover')),
        findsOneWidget,
      );
      await ready(id);
      await tester.pump();
      expect(notifications, 1);
      expect(calls.where((c) => c.method == 'createTexture').length, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'manual reinitialization keeps texture id and awaits fresh output',
    (tester) async {
      final controller = NosmaiCameraPreviewController();
      int notifications = 0;
      await mount(
        tester,
        controller: controller,
        onInitialized: () {
          notifications++;
        },
      );
      final id = tester.widget<Texture>(find.byType(Texture)).textureId;
      await ready(id);
      await tester.pump();
      final reinitialized = controller.reinitialize();
      await tester.pump();
      expect(controller.isInitializing, true);
      expect(
        find.byKey(const ValueKey('nosmai-preview-cover')),
        findsOneWidget,
      );
      await ready(id);
      await tester.pump();
      await reinitialized;
      expect(controller.isInitialized, true);
      expect(notifications, 2);
      expect(calls.where((c) => c.method == 'createTexture').length, 1);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, id);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'disposal while native reinitialization is pending ignores late replies',
    (tester) async {
      final controller = NosmaiCameraPreviewController();
      await mount(tester, controller: controller);
      final id = tester.widget<Texture>(find.byType(Texture)).textureId;
      await ready(id);
      await tester.pump();
      final response = Completer<Object?>();
      pendingReinitialize = response.future;
      final reinitialized = controller.reinitialize();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      response.complete(null);
      await tester.pump();
      await reinitialized;
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('game tap forwarding keeps normalized preview coordinates', (
    tester,
  ) async {
    await mount(tester);
    final id = tester.widget<Texture>(find.byType(Texture)).textureId;
    await ready(id);
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.byType(Texture)));
    await tester.pump();
    final tap = calls.firstWhere((c) => c.method == 'sendGameTap');
    expect(tap.arguments, {'x': 0.5, 'y': 0.5});
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('GPU output corrects vertical orientation without mirroring X',
      (tester) async {
    await mount(tester);
    final texture = tester.renderObject<RenderBox>(find.byType(Texture));
    final rawTopLeft = texture.localToGlobal(Offset.zero);
    final rawBottomLeft = texture.localToGlobal(Offset(0, texture.size.height));
    final rawBottomRight =
        texture.localToGlobal(Offset(texture.size.width, texture.size.height));
    expect(rawTopLeft.dy, greaterThan(rawBottomLeft.dy));
    expect(rawBottomLeft.dx, lessThan(rawBottomRight.dx));
    expect(rawTopLeft.dx, closeTo(rawBottomLeft.dx, .001));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('custom and disabled game tap policies remain intact', (
    tester,
  ) async {
    NosmaiGameTapDetails? tap;
    await mount(
      tester,
      key: const ValueKey('custom'),
      onGameTap: (value) {
        tap = value;
      },
    );
    final texture = find.byType(Texture);
    final rect = tester.getRect(texture);
    await tester.tapAt(
      rect.topLeft + Offset(rect.width * .25, rect.height * .75),
    );
    await tester.pump();
    expect(tap!.normalizedX, closeTo(.25, .001));
    expect(tap!.normalizedY, closeTo(.75, .001));
    expect(calls.where((c) => c.method == 'sendGameTap'), isEmpty);
    await mount(
      tester,
      key: const ValueKey('disabled'),
      enableGameTapHandling: false,
    );
    calls.clear();
    await tester.tapAt(tester.getCenter(find.byType(Texture)));
    await tester.pump();
    expect(calls.where((c) => c.method == 'isGameReady'), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
