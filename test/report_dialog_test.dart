// The report dialog's job is to make one thing unmissable before anything is
// sent: the operator sees who reported. Everything else here guards a rule
// that would be invisible if it broke.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/core_account.dart';
import 'package:freizone/widgets/report_dialog.dart';

Future<ReportChoice?> showIt(
  WidgetTester tester, {
  String ownServer = 'https://home.test',
  String? theirServer,
  bool theirServerAcceptsReports = false,
  String? assertedName,
  bool reportingOwnAdmin = false,
}) async {
  ReportChoice? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showDialog<ReportChoice>(
              context: context,
              builder: (context) => ReportDialog(
                ownServer: ownServer,
                theirServer: theirServer,
                theirServerAcceptsReports: theirServerAcceptsReports,
                assertedName: assertedName,
                reportingOwnAdmin: reportingOwnAdmin,
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('says the operator sees the reporter, before anything is sent', (
    tester,
  ) async {
    await showIt(tester);
    // Responsibility somebody was not told they were taking is a trap, not a
    // principle -- so this sentence is on the dialog, not in a help page.
    expect(
      find.textContaining('sees this report with your address'),
      findsOneWidget,
    );
  });

  testWidgets('has no free-text field', (tester) async {
    await showIt(tester);
    // A text field on a server is a store of personal allegations, and a
    // channel for writing at the operator that nothing moderates.
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('cannot be sent without a category', (tester) async {
    await showIt(tester);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Report'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('names the asserted name that travels as evidence', (
    tester,
  ) async {
    await showIt(tester, assertedName: 'Bank Support');
    expect(find.textContaining('"Bank Support"'), findsOneWidget);
  });

  testWidgets('says so when there is nothing to send', (tester) async {
    await showIt(tester);
    // Absent evidence is stated rather than filled in with the local name,
    // which lives in another store precisely so it cannot end up here.
    expect(find.textContaining('gives no name of its own'), findsOneWidget);
  });

  testWidgets('does not offer to tell a server that refuses reports', (
    tester,
  ) async {
    await showIt(tester, theirServer: 'https://elsewhere.test');
    expect(find.textContaining('Also tell'), findsNothing);
  });

  testWidgets('offers to tell their server, and says what that costs', (
    tester,
  ) async {
    await showIt(
      tester,
      theirServer: 'https://elsewhere.test',
      theirServerAcceptsReports: true,
    );
    expect(find.textContaining('Also tell'), findsOneWidget);
    // An operator they have no relationship with -- worth stating, since it is
    // the whole reason this is a choice and not automatic.
    expect(find.textContaining('operator you do not know'), findsOneWidget);
  });

  testWidgets('never offers to forward for somebody on the same server', (
    tester,
  ) async {
    await showIt(tester, theirServerAcceptsReports: true);
    expect(find.textContaining('Also tell'), findsNothing);
  });

  testWidgets('warns when the report reaches the person it is about', (
    tester,
  ) async {
    await showIt(tester, reportingOwnAdmin: true);
    // Nothing sits above one's own operator in a federated system. The least
    // this can do is say so before the fact rather than after.
    expect(
      find.textContaining('This account runs the server'),
      findsOneWidget,
    );
  });

  testWidgets('returns the category and the forwarding choice', (tester) async {
    ReportChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<ReportChoice>(
                context: context,
                builder: (context) => const ReportDialog(
                  ownServer: 'https://home.test',
                  theirServer: 'https://elsewhere.test',
                  theirServerAcceptsReports: true,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Harassment'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Also tell'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Report'));
    await tester.pumpAndSettle();

    expect(result?.category, ReportCategory.harassment);
    expect(result?.alsoTheirServer, isTrue);
  });
}
