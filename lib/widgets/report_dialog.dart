// Reporting an account to its operator (APP-28).
//
// The one sentence that has to be here, and has to be here *before* sending:
// the operator sees who reported. Reporting is named so that they can come back
// and ask what happened, which is the main thing an operator does with a
// report -- but responsibility somebody was not told they were taking is a
// trap, not a principle.
//
// What this screen deliberately does not have: a text field. The operator
// cannot read the conversation, so a report is a reason to look rather than
// evidence, and free text on a server is a store of personal allegations.
import 'package:flutter/material.dart';

import '../state/core_account.dart';

/// What the user chose, or null if they backed out.
class ReportChoice {
  const ReportChoice({required this.category, required this.alsoTheirServer});

  final ReportCategory category;
  final bool alsoTheirServer;
}

class ReportDialog extends StatefulWidget {
  const ReportDialog({
    super.key,
    required this.ownServer,
    this.theirServer,
    this.theirServerAcceptsReports = false,
    this.assertedName,
    this.reportingOwnAdmin = false,
  });

  /// Where the report always goes: the reporter's own operator, who knows them
  /// and is the one who can act on a federated account from here.
  final String ownServer;

  /// The reported account's home server, when it is not [ownServer]. Null for
  /// somebody on the same server, where there is only one operator to tell.
  final String? theirServer;

  /// Whether that server accepts reports at all. Discovered before opening
  /// this, so the second option is simply absent rather than offered and then
  /// failing.
  final bool theirServerAcceptsReports;

  /// The name that account asserts about itself, which travels as evidence.
  /// Null when it has asserted none -- then nothing goes, and the dialog says
  /// so rather than substituting the local name.
  final String? assertedName;

  /// Whether the reported account is this server's only admin, in which case
  /// the report reaches the person it is about. Nothing above one's own
  /// operator exists in a federated system; the least this can do is say so
  /// before the fact rather than after.
  final bool reportingOwnAdmin;

  @override
  State<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<ReportDialog> {
  ReportCategory? _category;
  bool _alsoTheirServer = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: const Text('Report to the operator'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The operator of ${widget.ownServer} sees this report with your '
              'address, and can contact you about it.',
              style: theme.textTheme.bodyMedium,
            ),
            if (widget.reportingOwnAdmin) ...[
              const SizedBox(height: 12),
              Text(
                'This account runs the server. Your report goes to them.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 16),
            RadioGroup<ReportCategory>(
              groupValue: _category,
              onChanged: (value) => setState(() => _category = value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final category in ReportCategory.values)
                    RadioListTile<ReportCategory>(
                      value: category,
                      title: Text(category.label),
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.assertedName == null
                  ? 'This account gives no name of its own, so nothing but the '
                        'address is sent. The operator cannot read your messages.'
                  : 'Sent with the report: the name this account gives itself, '
                        '"${widget.assertedName}". The operator cannot read '
                        'your messages.',
              style: muted,
            ),
            if (widget.theirServer case final theirServer?)
              if (widget.theirServerAcceptsReports) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: _alsoTheirServer,
                  onChanged: (value) =>
                      setState(() => _alsoTheirServer = value ?? false),
                  title: Text('Also tell $theirServer'),
                  subtitle: const Text(
                    'This hands your address to an operator you do not know.',
                  ),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _category == null
              ? null
              : () => Navigator.of(context).pop(
                  ReportChoice(
                    category: _category!,
                    alsoTheirServer: _alsoTheirServer,
                  ),
                ),
          child: const Text('Report'),
        ),
      ],
    );
  }
}
