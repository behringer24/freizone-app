// Server Admin area: registration policy + the user list (roles,
// block/unblock, delete). Admins can change anything here. Moderators see
// everything but may only block/unblock a regular member (SRV-08) -- roles,
// deletion and the server settings stay admin-only. Enforced server-side
// regardless; mirrored client-side so no offered action is a dead end.
import 'package:flutter/material.dart';

import '../net/dto.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../state/contact_store.dart';
import '../util/address_format.dart';
import '../util/admin_format.dart';
import '../util/admin_list_view.dart';
import '../util/errors.dart';
import '../util/role_icon.dart';
import '../widgets/admin_search_field.dart';
import '../widgets/verified_badge.dart';
import 'admin_account_screen.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({
    super.key,
    required this.session,
    required this.settings,
    required this.contacts,
  });

  final AppSession session;

  /// Only needed to hand on to ChatScreen, which the detail view can open
  /// (APP-11) -- nothing on this screen itself reads it.
  final AppSettings settings;

  /// Passed through to the screens that show a peer name (APP-19).
  final ContactStore contacts;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  bool _loading = true;
  String? _policy;
  bool? _federationEnabled;
  String? _error;

  /// Incremental search text and chosen ordering (APP-10) -- view state only,
  /// applied to the already-fetched list, never sent anywhere.
  String _query = '';
  AdminSortOrder _order = AdminSortOrder.created;
  final _searchController = TextEditingController();

  bool get _isAdmin => widget.session.myRole == 'admin';
  bool get _isModerator => widget.session.myRole == 'moderator';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.session.refreshMyRole();
      final policy = await widget.session.getRegistrationPolicy();
      final federationEnabled = await widget.session.getFederationEnabled();
      // Public GET /v1/server-status, not one of the admin-only calls above
      // -- this is what populates ownAttestation (SRV-19 / APP-22), same as
      // every other screen that shows it.
      await widget.session.refreshRegistrationPolicy();
      if (!mounted) return;
      setState(() {
        _policy = policy;
        _federationEnabled = federationEnabled;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeError(e);
        _loading = false;
      });
    }
  }

  Future<void> _setPolicy(String policy) async {
    final previous = _policy;
    setState(() => _policy = policy);
    try {
      await widget.session.setRegistrationPolicy(policy);
    } catch (e) {
      if (!mounted) return;
      setState(() => _policy = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to change policy: ${describeError(e)}')),
      );
    }
  }

  Future<void> _showRolePicker(AdminAccountSummary account) async {
    final role = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Set role for ${formatAccountIdForDisplay(account.id)}'),
        children: [
          for (final r in const ['user', 'moderator', 'admin'])
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(r),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: r == account.role
                        ? const Icon(Icons.check, size: 18)
                        : null,
                  ),
                  Text(r[0].toUpperCase() + r.substring(1)),
                ],
              ),
            ),
        ],
      ),
    );
    if (role == null || role == account.role || !mounted) return;
    try {
      await widget.session.setAccountRole(account.id, role);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to set role: ${describeError(e)}')),
        );
      }
    }
  }

  Future<void> _toggleBlock(AdminAccountSummary account) async {
    try {
      if (account.status == 'active') {
        await widget.session.blockAccount(account.id);
      } else {
        await widget.session.unblockAccount(account.id);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed: ${describeError(e)}')));
      }
    }
  }

  Future<void> _confirmDelete(AdminAccountSummary account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: Text(
          'This permanently removes ${formatAccountIdForDisplay(account.id)} and its message queue -- this cannot be undone.',
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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: ${describeError(e)}')),
        );
      }
    }
  }

  Future<void> _setFederationEnabled(bool enabled) async {
    final previous = _federationEnabled;
    setState(() => _federationEnabled = enabled);
    try {
      await widget.session.setFederationEnabled(enabled);
    } catch (e) {
      if (!mounted) return;
      setState(() => _federationEnabled = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to change federation: ${describeError(e)}'),
        ),
      );
    }
  }

  Widget _buildFederationSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Federation',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        SwitchListTile(
          title: const Text('Accept messages from other servers'),
          subtitle: const Text(
            'When off, this server rejects incoming federated messages, and '
            'accounts on it can no longer message contacts on other servers '
            '(existing cross-server chats are locked).',
          ),
          value: _federationEnabled ?? true,
          onChanged: _isAdmin && _federationEnabled != null
              ? (v) => _setFederationEnabled(v)
              : null,
        ),
      ],
    );
  }

  /// Own-server attestation status (SRV-19 / APP-22): unlike every other
  /// placement, this one states "not attested" plainly rather than showing
  /// nothing -- an operator needs to know their configuration took effect,
  /// which is a different question from a visitor reading a badge as a
  /// judgment about the server. Also the one placement carrying an expiry
  /// warning: without it, the first sign of lapse is a badge that silently
  /// stopped appearing elsewhere, discovered by a user rather than by the
  /// operator who could have renewed it.
  Widget _buildAttestationSection(BuildContext context) {
    final attestation = widget.session.ownAttestation;
    const daysBeforeExpiryWarning = 30;
    final daysLeft = attestation?.expiresAt.difference(DateTime.now()).inDays;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Attestation',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: attestation == null
              ? Text(
                  'This server carries no attestation from the Freizone project.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                )
              // Single Row with the glyph as a leading icon and everything
              // else -- tier line, "Operated by", "Valid until", the expiry
              // warning -- in one indented Column beside it, so the whole
              // block reads as one attestation rather than an icon glued to
              // just its first line.
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const VerifiedBadgeGlyph(size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(attestationTierDescription(attestation.tier)),
                          if (attestation.subject.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text('Operated by: ${attestation.subject}'),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            'Valid until ${formatAttestationDate(attestation.expiresAt)}',
                          ),
                          if (daysLeft != null &&
                              daysLeft < daysBeforeExpiryWarning) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  Icons.warning_amber,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    daysLeft < 0
                                        ? 'This attestation has expired -- contact the Freizone project for a renewal.'
                                        : 'This attestation expires in $daysLeft day${daysLeft == 1 ? '' : 's'} -- contact the Freizone project for a renewal.',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildPolicySection(BuildContext context) {
    const options = [
      ('open', 'Open', 'Anyone can self-register.'),
      ('invite', 'Invite', 'Registration requires an invite code.'),
      (
        'closed',
        'Closed',
        'Registration is fully blocked -- no new accounts, not even with an invite code. Switch to '
            'Invite or Open first to let new people join.',
      ),
    ];
    return RadioGroup<String>(
      groupValue: _policy,
      onChanged: (v) {
        if (_isAdmin && v != null) _setPolicy(v);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Registration policy',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          for (final (value, title, subtitle) in options)
            RadioListTile<String>(
              value: value,
              title: Text(title),
              subtitle: Text(subtitle),
              enabled: _isAdmin,
            ),
        ],
      ),
    );
  }

  // Blocked status wins over role -- a lock says "can't sign in right
  // now" at a glance, which matters more than what they could do if
  // unblocked. Otherwise: filled person+hat for admin, filled plain
  // person for moderator, outline person for a regular member -- same
  // Material "person" icon family throughout so the three read as
  // variants of one glyph rather than unrelated symbols.
  Icon _roleIcon(AdminAccountSummary account) {
    if (account.status != 'active') return const Icon(Icons.lock);
    return Icon(roleBadgeIcon(account.role) ?? Icons.person_outline);
  }

  /// Whether the signed-in user may block/unblock [account] server-wide
  /// (SRV-08). Admins may act on anyone; a moderator only on regular members,
  /// because blocking staff would amount to removing them -- the server
  /// enforces exactly this and answers 403 otherwise, so mirroring the rule
  /// here only avoids offering an action that would fail.
  bool _canToggleBlock(AdminAccountSummary account) =>
      _isAdmin || (_isModerator && account.role == 'user');

  /// The activity line under a row (SRV-09): what is waiting for this account
  /// and what it has stored, so an abandoned account is visible without
  /// drilling into anything. Null on a server that doesn't report these, which
  /// keeps the row looking exactly as it did rather than claiming zeroes it
  /// doesn't know (see AdminAccountSummary.hasActivitySignals).
  ///
  /// Storage is only mentioned once there is any: an empty figure on every row
  /// would bury the one row that matters. The queue half does the same, so an
  /// account with nothing going on shows no second line at all -- which is
  /// itself the signal.
  String? _activityLine(AdminAccountSummary account) {
    if (!account.hasActivitySignals) return null;
    final parts = <String>[
      // `?` drops the entry when there is nothing queued (use_null_aware_elements).
      ?formatPendingSummary(
        account.pendingMessages,
        account.oldestPendingAt,
        now: DateTime.now().toUtc(),
      ),
      if (account.blobBytes > 0)
        formatQuotaUsage(account.blobBytes, account.blobBytesLimit),
    ];
    return parts.isEmpty ? null : parts.join(' -- ');
  }

  /// The "Users" heading, the search box, and the sort control (APP-10). The
  /// count reads "showing N of M" only while a search is narrowing things, so
  /// the unfiltered case stays quiet.
  Widget _buildUsersHeader(
    BuildContext context,
    List<AdminAccountSummary> all,
    List<AdminAccountSummary> shown,
  ) {
    final filtered = shown.length != all.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        children: [
          const Text('Users', style: TextStyle(fontWeight: FontWeight.bold)),
          if (filtered)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '${shown.length} of ${all.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const Spacer(),
          AdminSearchField(
            controller: _searchController,
            onChanged: (v) => setState(() => _query = v),
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
          PopupMenuButton<AdminSortOrder>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort order',
            initialValue: _order,
            onSelected: (order) => setState(() => _order = order),
            itemBuilder: (context) => [
              for (final order in AdminSortOrder.values)
                // Ordering by figures this server doesn't report would do
                // nothing at all, so it isn't offered.
                if (adminSortOrderApplies(order, all))
                  PopupMenuItem(value: order, child: Text(_sortLabel(order))),
            ],
          ),
        ],
      ),
    );
  }

  /// Labels name the direction, not just the field: "Role" alone leaves the
  /// user guessing which end of the list they are about to get.
  String _sortLabel(AdminSortOrder order) => switch (order) {
    AdminSortOrder.id => 'Account id',
    AdminSortOrder.created => 'Oldest first',
    AdminSortOrder.role => 'Role, admins first',
    AdminSortOrder.status => 'Blocked first',
    AdminSortOrder.pending => 'Most queued first',
    AdminSortOrder.oldestPending => 'Longest waiting first',
  };

  Widget _buildAccountRow(BuildContext context, AdminAccountSummary account) {
    final blocked = account.status != 'active';
    final canBlock = _canToggleBlock(account);
    final activity = _activityLine(account);
    return ListTile(
      isThreeLine: activity != null,
      leading: _roleIcon(account),
      // The row opens the detail view; the overflow menu stays so the two
      // most-used actions remain one tap away from the list (APP-11).
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AdminAccountScreen(
            session: widget.session,
            settings: widget.settings,
            accountId: account.id,
            contacts: widget.contacts,
          ),
        ),
      ),
      title: Text(formatAccountIdForDisplay(account.id)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${account.role}${blocked ? ' -- blocked for all' : ''}'),
          if (activity != null)
            Text(
              activity,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
      trailing: canBlock
          ? PopupMenuButton<String>(
              onSelected: (action) {
                switch (action) {
                  case 'set_role':
                    _showRolePicker(account);
                  case 'toggle_block':
                    _toggleBlock(account);
                  case 'delete':
                    _confirmDelete(account);
                }
              },
              itemBuilder: (context) => [
                // Role and delete stay admin-only, so a moderator's menu holds
                // the block entry alone.
                if (_isAdmin)
                  const PopupMenuItem(value: 'set_role', child: Text('Set role')),
                if (canBlock)
                  PopupMenuItem(
                    value: 'toggle_block',
                    // "for all" spelled out because the app also has a
                    // personal, per-contact block (peer_profile_screen.dart)
                    // that affects nobody but the blocker -- next to that, a
                    // bare "Block" here would be genuinely ambiguous.
                    child: Text(blocked ? 'Unblock for all' : 'Block for all'),
                  ),
                if (_isAdmin)
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server Admin')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!),
              ),
            )
          : ListenableBuilder(
              listenable: widget.session,
              builder: (context, _) {
                final accounts = widget.session.adminAccounts;
                final shown = adminListView(
                  accounts,
                  query: _query,
                  order: _order,
                );
                return ListView(
                  children: [
                    _buildPolicySection(context),
                    const Divider(height: 32),
                    _buildFederationSection(context),
                    const Divider(height: 32),
                    _buildAttestationSection(context),
                    const Divider(height: 32),
                    _buildUsersHeader(context, accounts, shown),
                    // A search that matches nothing needs saying out loud --
                    // an empty list under a filled-in search box otherwise
                    // reads as "this server has no accounts".
                    if (shown.isEmpty && accounts.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Text('No account matches that.'),
                      ),
                    for (final account in shown)
                      _buildAccountRow(context, account),
                  ],
                );
              },
            ),
    );
  }
}
