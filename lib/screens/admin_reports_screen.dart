// The moderation queue (APP-28): the cases behind the counters.
//
// Its own screen rather than a sort order on the user list, because on a
// healthy server nothing is reported -- a column that is zero for two hundred
// rows is a poor way in, and it would crowd out the activity signals that
// actually vary (SRV-09).
//
// The working unit here is the **case**, not the counter. A number tells a
// moderator nothing they can act on; who reported, when, which category and
// what the account calls itself is what a decision is made from.
import 'package:flutter/material.dart';

import '../net/dto.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../state/contact_store.dart';
import '../util/address_format.dart';
import '../util/errors.dart';
import 'admin_account_screen.dart';

class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({
    super.key,
    required this.session,
    required this.settings,
    required this.contacts,
  });

  final AppSession session;
  final AppSettings settings;
  final ContactStore contacts;

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await widget.session.refreshReports();
    } catch (e) {
      if (mounted) _snack(describeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _resolve(AdminReport report, String outcome) async {
    try {
      await widget.session.resolveReport(report.id, outcome);
      if (!mounted) return;
      _snack(switch (outcome) {
        'actioned' => 'Marked as dealt with',
        'dismissed' => 'Dismissed',
        _ => 'Marked as an abusive report',
      });
    } catch (e) {
      if (mounted) _snack(describeError(e));
    }
  }

  /// Opens the admin view of an account, which is where every action already
  /// lives -- block, delete, and a chat with them.
  ///
  /// Reachable from **both** sides of a case: the reported account, and the
  /// reporter. Asking the reporter what happened is the main thing an operator
  /// does with a report, and it is only possible because reporting is named.
  void _openAccount(String address) {
    final id = address.split('*').first;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminAccountScreen(
          session: widget.session,
          settings: widget.settings,
          contacts: widget.contacts,
          accountId: id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final reports = widget.session.openReports;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Reports'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: _loading ? null : _load,
              ),
            ],
          ),
          body: _loading && reports.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : reports.isEmpty
              ? const _NothingReported()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: reports.length + 1,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index == 0) return const _QueueNote();
                      return _ReportCard(
                        report: reports[index - 1],
                        onOpenAccount: _openAccount,
                        onResolve: _resolve,
                      );
                    },
                  ),
                ),
        );
      },
    );
  }
}

class _NothingReported extends StatelessWidget {
  const _NothingReported();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        'Nothing reported.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

/// The one thing a moderator has to understand before acting on any of this.
class _QueueNote extends StatelessWidget {
  const _QueueNote();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(
      'Messages are end-to-end encrypted, so a report is somebody\'s account '
      'of what happened, not evidence. It is a reason to look into it -- and '
      'to ask the person who reported.',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    required this.report,
    required this.onOpenAccount,
    required this.onResolve,
  });

  final AdminReport report;
  final void Function(String address) onOpenAccount;
  final Future<void> Function(AdminReport report, String outcome) onResolve;

  static const _categoryLabels = {
    'spam': 'Spam',
    'harassment': 'Harassment',
    'fraud': 'Fraud or impersonation',
    'other': 'Something else',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _categoryLabels[report.category] ?? report.category,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _AddressRow(
            label: 'Reported',
            address: report.reported,
            onTap: () => onOpenAccount(report.reported),
          ),
          _AddressRow(
            label: 'Reported by',
            address: report.reporter,
            onTap: () => onOpenAccount(report.reporter),
          ),
          const SizedBox(height: 8),
          // The line most decisions get made from, which is why it reads as a
          // sentence rather than as a field. "Verified" says this server could
          // check the signature -- never that the name is true.
          Text(_evidenceLine(), style: muted),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: () => onResolve(report, 'actioned'),
                child: const Text('Dealt with'),
              ),
              OutlinedButton(
                onPressed: () => onResolve(report, 'dismissed'),
                child: const Text('Dismiss'),
              ),
              // The counterweight to reporting being named: without it,
              // accusing somebody costs nothing.
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                onPressed: () => onResolve(report, 'abusive'),
                child: const Text('Report was abusive'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _evidenceLine() {
    if (report.evidence.isEmpty) {
      return 'This account gives no name of its own.';
    }
    final checked = report.evidenceVerified
        ? 'signature checked'
        : 'signature not checked here';
    if (report.evidence.length == 1) {
      return 'Calls itself "${report.evidence.first}" ($checked).';
    }
    // The sequence is often the point: an account that called itself one thing
    // while it was doing something, and another by the time it was reported.
    final previous = report.evidence.skip(1).map((n) => '"$n"').join(', ');
    return 'Calls itself "${report.evidence.first}" ($checked). '
        'Previously: $previous.';
  }
}

class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.label,
    required this.address,
    required this.onTap,
  });

  final String label;
  final String address;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final id = address.split('*').first;
    final server = address.contains('*') ? address.split('*').last : null;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 100,
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Text(
                server == null
                    ? formatAccountIdForDisplay(id)
                    : '${formatAccountIdForDisplay(id)} · $server',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }
}
