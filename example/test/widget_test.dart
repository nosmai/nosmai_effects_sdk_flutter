import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_effects_sdk_example/main.dart';

void main() {
  testWidgets('shows the camera entry screen', (WidgetTester tester) async {
    await tester.pumpWidget(const NosmaiCameraApp());

    expect(find.text('Nosmai Effects'), findsOneWidget);
    expect(find.text('Open Camera'), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt_rounded), findsOneWidget);
  });
}
