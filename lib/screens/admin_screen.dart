// Server Admin area: registration policy + the user list (roles,
// block/unblock, delete). Moderators see everything read-only (no tap
// targets at all); only admins can change anything -- enforced server-
// side regardless, but hidden client-side too so it isn't a dead end.
import 'package:flutter/material.dart';

import '../net/dto.dart';
import '../state/app_session.dart';
import '../util/address_format.dart';
import '../util/errors.dart';
import '../util/role_icon.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  bool _loading = true;
  String? _policy;
  bool? _federationEnabled;
  String? _error;

  bool get _isAdmin => widget.session.myRole == 'admin';

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

  Widget _buildAccountRow(BuildContext context, AdminAccountSummary account) {
    final blocked = account.status != 'active';
    return ListTile(
      leading: _roleIcon(account),
      title: Text(formatAccountIdForDisplay(account.id)),
      subtitle: Text('${account.role}${blocked ? ' -- blocked' : ''}'),
      trailing: _isAdmin
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
                const PopupMenuItem(value: 'set_role', child: Text('Set role')),
                PopupMenuItem(
                  value: 'toggle_block',
                  child: Text(blocked ? 'Unblock' : 'Block'),
                ),
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
                return ListView(
                  children: [
                    _buildPolicySection(context),
                    const Divider(height: 32),
                    _buildFederationSection(context),
                    const Divider(height: 32),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        'Users',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    for (final account in accounts)
                      _buildAccountRow(context, account),
                  ],
                );
              },
            ),
    );
  }
}
