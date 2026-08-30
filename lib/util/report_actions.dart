// Reporting a contact to an operator (APP-28), shared by every surface that
// offers it so the wording and the order of questions stay in one place.
//
// The order matters and is not arbitrary: discover whether reporting is even
// possible, then ask, then send. A button that appears and fails is worse than
// one that was never there, and the compatibility rule this repo works under
// says capability is discovered, never assumed.
import 'package:flutter/material.dart';

import '../state/app_session.dart';
import '../state/core_account.dart';
import '../util/errors.dart';
import '../widgets/report_dialog.dart';

// Whether this account's own server accepts reports is [AppSession
// .reportsEnabled] -- fetched with the rest of the server status and read
// synchronously, so an entry is absent rather than drawn and then failing. The
// *reported* account's server is a second question, asked below only when
// there is one to ask.

/// Asks, then reports. Returns true when something was actually sent.
///
/// [peerServer] is the reported account's home server, empty for somebody on
/// this one. [assertedName] is what they call themselves, which travels as
/// evidence -- never the name this device gave them.
Future<bool> reportContact(
  BuildContext context,
  AppSession session, {
  required String accountId,
  required String peerServer,
  String? assertedName,
  bool reportingOwnAdmin = false,
}) async {
  final federated = peerServer.isNotEmpty && peerServer != session.state.server;

  // Their server is a second, separate question -- and one whose answer
  // decides whether the option is shown at all rather than offered and then
  // refused.
  var theirServerAccepts = false;
  if (federated) {
    try {
      theirServerAccepts = await session.coreAccount.reportsEnabled(
        server: peerServer,
      );
    } catch (_) {
      // Their server could not be asked. Not offering to forward is the safe
      // reading: the report still reaches this user's own operator, which is
      // the half that always happens anyway.
    }
  }
  if (!context.mounted) return false;

  final choice = await showDialog<ReportChoice>(
    context: context,
    builder: (context) => ReportDialog(
      ownServer: session.state.server,
      theirServer: federated ? peerServer : null,
      theirServerAcceptsReports: theirServerAccepts,
      assertedName: assertedName,
      reportingOwnAdmin: reportingOwnAdmin,
    ),
  );
  if (choice == null || !context.mounted) return false;

  try {
    await session.coreAccount.report(
      accountId,
      choice.category,
      alsoTheirServer: choice.alsoTheirServer,
    );
    if (!context.mounted) return true;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Reported to the operator')));
    return true;
  } catch (e) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(describeError(e))));
    return false;
  }
}

/// Takes a report back.
///
/// Always offered rather than shown only where one is known to exist: nothing
/// tells this device what it has reported -- the server has no "my reports"
/// endpoint and this app keeps no record -- and withdrawing something that is
/// not there is not a failure, it is the outcome the user asked for. Worth
/// revisiting if it ever confuses somebody; it is honest, just not clever.
Future<void> withdrawReportFor(
  BuildContext context,
  AppSession session,
  String accountId,
) async {
  try {
    await session.coreAccount.withdrawReport(accountId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Report withdrawn')));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(describeError(e))));
  }
}
