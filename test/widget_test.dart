import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:freizone/screens/setup_screen.dart';

void main() {
  // AppRoot (main.dart) loads persisted state via path_provider before
  // picking a screen, and no platform-channel mock is set up here, so
  // this test targets SetupScreen directly rather than the full
  // FreizoneApp -- avoiding a plugin call that would otherwise hang the
  // test indefinitely.
  testWidgets('setup wizard starts by asking for the server address', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: SetupScreen(onRegistered: (_) async {})));

    expect(find.text('Freizone -- Setup'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Server address'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Continue'), findsOneWidget);
  });
}
