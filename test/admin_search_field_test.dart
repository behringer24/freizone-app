// The admin list's search box (APP-10). Geometry, not behaviour: the bug this
// guards against is the text sitting above the icons instead of beside them,
// which no behavioural test would notice and which is why the field is its own
// widget.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/widgets/admin_search_field.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    TextEditingController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AdminSearchField(
              controller: controller,
              onChanged: (_) {},
              onClear: controller.clear,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the text shares a centre line with the search icon', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'qk43r');
    addTearDown(controller.dispose);
    await pump(tester, controller);

    final text = tester.getCenter(find.byType(EditableText)).dy;
    final icon = tester.getCenter(find.byIcon(Icons.search)).dy;
    // One logical pixel of slack for rounding. Before the fix the text sat
    // several pixels high, because a dense field with no label anchors its
    // content to the top of a box the icons had stretched.
    expect(
      (text - icon).abs(),
      lessThan(1.0),
      reason: 'text at $text, search icon at $icon',
    );
  });

  testWidgets('the clear button lines up too, and only appears with a query', (
    tester,
  ) async {
    final empty = TextEditingController();
    addTearDown(empty.dispose);
    await pump(tester, empty);
    expect(find.byIcon(Icons.clear), findsNothing);

    final controller = TextEditingController(text: 'qk43r');
    addTearDown(controller.dispose);
    await pump(tester, controller);

    final text = tester.getCenter(find.byType(EditableText)).dy;
    final clear = tester.getCenter(find.byIcon(Icons.clear)).dy;
    expect(
      (text - clear).abs(),
      lessThan(1.0),
      reason: 'text at $text, clear icon at $clear',
    );
  });

  testWidgets('does not change height when the clear button appears', (
    tester,
  ) async {
    // The defect itself: an IconButton carries a 48x48 minimum in its
    // ButtonStyle, so typing the first character grew the field from 40 to 48
    // and moved the text with it. Same height empty or not, and compact enough
    // for the header row it sits in.
    final empty = TextEditingController();
    addTearDown(empty.dispose);
    await pump(tester, empty);
    final emptyHeight = tester.getSize(find.byType(TextField)).height;

    final controller = TextEditingController(text: 'qk43r');
    addTearDown(controller.dispose);
    await pump(tester, controller);
    final queriedHeight = tester.getSize(find.byType(TextField)).height;

    expect(queriedHeight, emptyHeight);
    expect(queriedHeight, lessThan(48));
  });
}
