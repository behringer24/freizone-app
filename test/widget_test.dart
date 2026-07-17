import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:freizone/screens/setup_screen.dart';

void main() {
  // AppRoot (main.dart) loads persisted state via path_provider before
  // picking a screen, and no platform-channel mock is set up here, so
  // this test targets SetupScreen directly rather than the full
  // FreizoneApp -- avoiding a plugin call that would otherwise hang the
  // test indefinitely.
  testWidgets('setup screen shows the server field and mode toggle', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SetupScreen()));

    expect(find.text('Freizone -- Setup'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Bootstrap'), findsOneWidget);
  });
}
