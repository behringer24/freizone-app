// One account, seen from the Server Admin side (APP-11): what the server knows
// about it, and the actions an operator has over it.
//
// Deliberately NOT peer_profile_screen.dart, even though the two look alike.
// That screen's actions belong to a *conversation partner*: its block toggle is
// a personal, single-user block that means nothing when applied to an arbitrary
// account the operator has never chatted with, and "Reset secure session"
// assumes a ratchet session that generally doesn't exist here. Sharing the
// screen would have meant hiding half of it and re-labelling the rest.
//
// The one action the two do share is starting a chat -- and here it is
// explicitly the operator's *own*, personal act: it goes out from their
// account like any other message, and the recipient sees nothing that marks it
// as coming from an admin.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/dto.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../state/contact_store.dart';
import '../util/address_format.dart';
import '../util/admin_format.dart';
import '../util/errors.dart';
import '../util/freizone_address.dart';
import '../util/role_icon.dart';
import '../widgets/peer_avatar.dart';
import 'chat_screen.dart';

class AdminAccountScreen extends StatefulWidget {
  const AdminAccountScreen({
    super.key,
    required this.session,
    required this.settings,
    required this.contacts,
    required this.accountId,
  });

  final AppSession session;
  final AppSettings settings;

  /// Passed through to the screens that show a peer name (APP-19).
  final ContactStore contacts;

  /// Looked up from [AppSession.adminAccounts] on every build rather than
  /// passed as a snapshot, so blocking or unblocking is reflected here the
  /// moment the list refreshes -- and so a deleted account is noticed at all.
  final String accountId;

  @override
  State<AdminAccountScreen> createState() => _AdminAccountScreenState();
}

class _AdminAccountScreenState extends State<AdminAccountScreen> {
  bool get _isAdmin => widget.session.myRole == 'admin';
  bool get _isModerator => widget.session.myRole == 'moderator';

  /// Mirrors the server's rule (SRV-08): a moderator may only block a regular
  /// member, because blocking staff would amount to removing them.
  bool _canToggleBlock(AdminAccountSummary account) =>
      _isAdmin || (_isModerator && account.role == 'user');

  bool get _isSelf => widget.accountId == widget.session.state.accountId;

  Future<void> _toggleBlock(AdminAccountSummary account) async {
    try {
      if (account.status == 'active') {
        await widget.session.blockAccount(account.id);
      } else {
        await widget.session.unblockAccount(account.id);
      }
    } catch (e) {
      _snack('Failed: ${describeError(e)}');
    }
  }

  Future<void> _confirmDelete(AdminAccountSummary account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: Text(
          'This permanently removes ${formatAccountIdForDisplay(account.id)} and its '
          'message queue -- this cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.session.deleteAccount(account.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _snack('Failed to delete: ${describeError(e)}');
    }
  }

  /// Opens a chat with this account, resolving and creating the conversation
  /// first if there isn't one yet ([AppSession.startConversation] is a no-op
  /// for an existing one). This is the operator's own conversation, so it
  /// behaves exactly like starting any other chat -- including arriving as a
  /// message request on the other side if they've never heard from them.
  Future<void> _openChat() async {
    try {
      await widget.session.startConversation(widget.accountId);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            session: widget.session,
            peerAccountId: widget.accountId,
            contacts: widget.contacts,
            settings: widget.settings,
          ),
        ),
      );
    } catch (e) {
      _snack('Could not open a chat: ${describeError(e)}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Same wording and feedback as both profile screens, so copying an address
  /// behaves identically wherever one is shown.
  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    _snack('$label copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final account = widget.session.adminAccounts
              .where((a) => a.id == widget.accountId)
              .firstOrNull;
          // Gone from the list: deleted, here or elsewhere. Say so rather than
          // leaving a screen full of stale figures.
          if (account == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('This account no longer exists on this server.'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            children: _details(context, account),
          );
        },
      ),
    );
  }

  List<Widget> _details(BuildContext context, AdminAccountSummary account) {
    final theme = Theme.of(context);
    final blocked = account.status != 'active';
    final hasConversation = widget.session.state.conversations.containsKey(
      account.id,
    );
    // Every account on this list is on this server: the admin API only ever
    // reports the server's own accounts, so there is no per-account server to
    // resolve the way a federated peer needs one.
    final server = widget.session.state.server;
    final shortId = account.id.substring(0, accountIdPrefixLength);
    final shortAddress = buildFreizoneAddress(id: shortId, server: server);
    final fullAddress = buildFreizoneAddress(id: account.id, server: server);
    final roleLabel = switch (account.role) {
      'admin' => 'Admin',
      'moderator' => 'Moderator',
      _ => null,
    };

    return [
      // The same header the two profile screens have -- large avatar, the
      // status/role chip, the short id in headline size, the server beneath.
      // An operator looking up an account wants to recognize it as the same
      // object they see everywhere else in the app, and the id in a 32px row
      // did not read as a person at all.
      Center(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            PeerAvatar(accountId: account.id, radius: 48),
            if (roleBadgeIcon(account.role) case final icon?)
              Positioned(
                bottom: -4,
                right: -4,
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.white,
                  child: Icon(icon, size: 22, color: Colors.black87),
                ),
              ),
          ],
        ),
      ),
      // One row rather than two stacked chips: an account can be both a
      // moderator and blocked, and that is one fact about it, not two sections.
      if (roleLabel != null || blocked) ...[
        const SizedBox(height: 12),
        Center(
          child: Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (roleLabel != null)
                Chip(
                  label: Text(roleLabel),
                  visualDensity: VisualDensity.compact,
                ),
              if (blocked)
                Chip(
                  label: const Text('Blocked for all'),
                  backgroundColor: theme.colorScheme.error,
                  labelStyle: TextStyle(color: theme.colorScheme.onError),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 16),
      Center(
        child: Text(
          shortId,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      const SizedBox(height: 4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          server,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      const SizedBox(height: 24),
      // Copyable, which the old SelectableText id only half was: an operator
      // moving an address into a ticket or a chat wants the whole thing,
      // including the server, and wants it in one tap.
      ListTile(
        title: const Text('Short address'),
        subtitle: Text(shortAddress),
        trailing: IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy short address',
          onPressed: () => _copy('Short address', shortAddress),
        ),
      ),
      ListTile(
        title: const Text('Full address'),
        subtitle: Text(fullAddress),
        trailing: IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy full address',
          onPressed: () => _copy('Full address', fullAddress),
        ),
      ),

      // The friendly action sits above the figures; the consequential ones are
      // kept together at the bottom, the shape both profile screens use.
      // Hidden for the operator's own account: startConversation refuses a
      // self-chat outright, so offering it would only produce an error.
      if (!_isSelf) ...[
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.tonalIcon(
            onPressed: _openChat,
            icon: const Icon(Icons.chat_bubble_outline),
            label: Text(hasConversation ? 'Open chat' : 'Start a chat'),
          ),
        ),
      ],
      // Sending to a blocked account is still worth allowing -- the message
      // queues server-side and arrives if the block is ever lifted -- but
      // saying nothing would make it look delivered.
      if (!_isSelf && blocked)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'While blocked for all, they cannot fetch messages -- anything you '
            'send waits until the block is lifted.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),

      const SizedBox(height: 16),
      const Divider(),
      _row(context, 'Role', account.role),
      _row(context, 'Status', blocked ? 'Blocked for all' : 'Active'),
      _row(context, 'Registered', _formatDate(account.createdAt)),
      if (account.hasActivitySignals) ...[
        _row(context, 'Devices', '${account.deviceCount}'),
        _row(
          context,
          'Queued messages',
          account.pendingMessages == 0
              ? 'None'
              : formatPendingSummary(
                      account.pendingMessages,
                      account.oldestPendingAt,
                      now: DateTime.now().toUtc(),
                    ) ??
                    '${account.pendingMessages}',
        ),
        _row(
          context,
          'Attachments',
          account.blobCount == 0
              ? 'None'
              : '${account.blobCount} -- '
                    '${formatQuotaUsage(account.blobBytes, account.blobBytesLimit)}',
        ),
      ],
      // Admins only (SRV-14): the server doesn't send this to a moderator at
      // all, so showing an empty row to them would only invite the question of
      // why it is empty. "Unknown" rather than "nobody": the field is equally
      // absent for an account that needed no invite and for one whose inviter
      // has since been deleted.
      if (_isAdmin) _invitedByRow(context, account),

      // Both action areas follow profile_screen.dart and
      // peer_profile_screen.dart: a coloured section heading, a sentence saying
      // what the action actually does, then the button. A ListTile row invites a
      // tap before it has been read, which is the wrong shape for two actions
      // that reach every device this account owns.
      if (_canToggleBlock(account)) ...[
        const SizedBox(height: 16),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Moderation',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            blocked
                ? 'Lets this account use the server again. Anything queued for '
                      'it while it was blocked is delivered on its next fetch.'
                : 'Stops this account from using the server at all -- every '
                      'device it has, not just your own view of it. Messages '
                      'others send keep queueing and arrive if it is unblocked.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: blocked
              ? FilledButton.icon(
                  onPressed: () => _toggleBlock(account),
                  icon: const Icon(Icons.lock_open),
                  label: const Text('Unblock for all'),
                )
              : OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(color: theme.colorScheme.error),
                  ),
                  onPressed: () => _toggleBlock(account),
                  icon: const Icon(Icons.block),
                  label: const Text('Block for all'),
                ),
        ),
      ],
      if (_isAdmin) ...[
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Danger zone',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.error,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _isSelf
                ? 'Permanently removes your own account and its message queue '
                      'from this server. There is no way back to this identity.'
                : 'Permanently removes the account and its message queue. The '
                      'holder is not notified, and anyone messaging them '
                      'afterwards gets an immediate "unknown recipient" error.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
              side: BorderSide(color: theme.colorScheme.error),
            ),
            onPressed: () => _confirmDelete(account),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete account'),
          ),
        ),
      ],
    ];
  }

  Widget _invitedByRow(BuildContext context, AdminAccountSummary account) {
    final inviter = account.invitedBy;
    if (inviter == null) {
      return _row(context, 'Invited by', 'Unknown');
    }
    // Tappable, because "who vouched for this account" is usually the start of
    // a chain rather than the end of a question. The inviter is always still on
    // this server when the field is set -- the invite row would have gone with
    // them otherwise.
    return ListTile(
      dense: true,
      title: Text('Invited by', style: Theme.of(context).textTheme.bodySmall),
      subtitle: Text(formatAccountIdForDisplay(inviter)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AdminAccountScreen(
            session: widget.session,
            settings: widget.settings,
            accountId: inviter,
            contacts: widget.contacts,
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) => ListTile(
    dense: true,
    title: Text(label, style: Theme.of(context).textTheme.bodySmall),
    subtitle: Text(value),
  );

  /// Absolute, not relative: for "when did this account join" the actual date
  /// is what an operator wants, unlike the queue ages elsewhere on this screen
  /// where the point is how long something has been waiting.
  String _formatDate(DateTime utc) {
    final d = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}
