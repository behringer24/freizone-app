// Push diagnostics (APP-12): what is actually registered, per account.
//
// Exists because "I get no notifications" was, three times over, a question
// nobody could answer without logcat. It is deliberately a sub-screen: which
// mechanism is in use is an app-wide matter that Settings already shows, while
// "did *this* account's server accept our push endpoint" is a specialist
// question that would only clutter the main flow.
//
// The app-wide/per-account split is the thing to keep straight here. The
// mechanism comes from AppSettings plus device state (the chosen distributor,
// one FCM token per install), so it is resolved once. The registration is per
// account: each one signs its own request against its own server, so one can be
// fine while another's server was unreachable.
import 'package:flutter/material.dart';

import '../push/push_manager.dart';
import '../state/account_manager.dart';
import '../util/freizone_address.dart';

class PushStatusScreen extends StatefulWidget {
  const PushStatusScreen({super.key, required this.manager});

  final AccountManager manager;

  @override
  State<PushStatusScreen> createState() => _PushStatusScreenState();
}

class _PushStatusScreenState extends State<PushStatusScreen> {
  bool _reregistering = false;

  Future<void> _reregisterAll() async {
    setState(() => _reregistering = true);
    try {
      // App-wide, over every live session -- the same rule the push-preference
      // switch and the distributor picker in Settings already follow.
      for (final session in widget.manager.sessions) {
        await session.reregisterPush();
      }
    } finally {
      if (mounted) setState(() => _reregistering = false);
    }
  }

  /// Local date and time to the minute; seconds would be noise for something
  /// measured in hours or days.
  String _formatWhen(DateTime utc) {
    final local = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final sessions = widget.manager.orderedSessions;

    return Scaffold(
      appBar: AppBar(title: const Text('Push registrations')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Each account tells its own server where to send push wakes. '
              'They are listed separately because one can work while '
              "another's server was unreachable.",
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final session in sessions)
            ListTile(
              title: Text(
                shortFreizoneAddress(
                  id: session.state.accountId,
                  server: session.state.server,
                ),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                session.state.pushRegisteredAt == null
                    // Said out loud rather than shown as a blank: never having
                    // registered is the most informative state of all here.
                    ? 'Never registered on this device'
                    : 'Last registered '
                          '${_formatWhen(session.state.pushRegisteredAt!)}'
                          '\nvia ${_describeMechanism(session.state.pushMechanism)}',
              ),
              isThreeLine: session.state.pushRegisteredAt != null,
              leading: Icon(
                session.state.pushRegisteredAt == null
                    ? Icons.notifications_off_outlined
                    : Icons.notifications_active_outlined,
                color: session.state.pushRegisteredAt == null
                    ? colorScheme.error
                    : colorScheme.primary,
              ),
            ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _reregistering ? null : _reregisterAll,
              icon: _reregistering
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: const Text('Re-register now'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Registration also runs by itself: on every app start, and when '
              'the push service hands out a new address, even while the app is '
              'closed.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Turns the stored label (see AppState.pushMechanism) into something readable.
String _describeMechanism(String? stored) {
  if (stored == null || stored.isEmpty) return 'unknown';
  if (stored == 'fcm') return 'Firebase Cloud Messaging';
  if (stored.startsWith('unifiedpush:')) {
    final pkg = stored.substring('unifiedpush:'.length);
    return pkg.isEmpty
        ? 'UnifiedPush'
        : 'UnifiedPush (${describeDistributor(pkg)})';
  }
  return stored;
}
