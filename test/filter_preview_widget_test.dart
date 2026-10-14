import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nosmai_camera_sdk');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Uint8List png;
  NosmaiFilter filter(String id) => NosmaiFilter(
      id: id,
      name: id,
      description: '',
      displayName: id,
      path: '/cache/$id.nosmai',
      fileSize: 100,
      type: 'cloud');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nosmai-preview-widget-');
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
        .drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = Colors.red);
    final picture = recorder.endRecording();
    final image = await picture.toImage(4, 4);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  testWidgets('widget resolves package fallback internally and decodes it',
      (tester) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'getFilterPreviewContext') {
        return {'directory': root.path, 'packageStamp': 'package-v1'};
      }
      if (call.method == 'loadFilterPackagePreview') return png;
      fail('Unexpected filter/render operation: ${call.method}');
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: NosmaiFilterPreview(
        filter: filter('a'),
        width: 80,
        height: 80,
        placeholder: (_) => const Text('Loading'),
      )));
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(calls, ['getFilterPreviewContext', 'loadFilterPackagePreview']);
    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unavailable preview uses custom placeholder without applying a filter',
      (tester) async {
    messenger.setMockMethodCallHandler(channel,
        (call) async => {'directory': root.path, 'packageStamp': null});
    await tester.pumpWidget(MaterialApp(
        home: NosmaiFilterPreview(
            filter: filter('missing'),
            errorBuilder: (_) => const Text('No preview'))));
    await tester.pumpAndSettle();
    expect(find.text('No preview'), findsOneWidget);
  });

  testWidgets('disposed widget ignores late native responses', (tester) async {
    final response = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (_) => response.future);
    await tester.pumpWidget(
        MaterialApp(home: NosmaiFilterPreview(filter: filter('late'))));
    await tester.pumpWidget(const SizedBox());
    response.complete({'directory': root.path, 'packageStamp': null});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy base64 displays with an older native plugin',
      (tester) async {
    messenger.setMockMethodCallHandler(
        channel, (_) async => throw MissingPluginException());
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: NosmaiFilterPreview(
        filter: NosmaiFilter.fromMap(
            {...filter('legacy').toMap(), 'previewUrl': base64Encode(png)}),
      )));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing filter ignores an old pending preview', (tester) async {
    final old = Completer<Object?>();
    int extractions = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadFilterPackagePreview') {
        extractions++;
        return png;
      }
      if (call.arguments['filterId'] == 'old') return old.future;
      return {'directory': root.path, 'packageStamp': null};
    });
    Widget preview(String id) => MaterialApp(
        home: NosmaiFilterPreview(
            filter: filter(id),
            errorBuilder: (_) => const Text('New filter has no preview')));
    await tester.pumpWidget(preview('old'));
    await tester.pumpWidget(preview('new'));
    await tester.pumpAndSettle();
    old.complete({'directory': root.path, 'packageStamp': 'old-v1'});
    await tester.pumpAndSettle();
    expect(extractions, 0);
    expect(find.text('New filter has no preview'), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
