// The "start a new chat" bottom sheet: an address to reach, an optional
// local alias, and an optional greeting sent right away.
//
// Lives here rather than inside chat_list_screen.dart because two places open
// it. The chat list's "+" button opens it empty; tapping a Freizone address
// inside a message (APP-14) opens it pre-filled via [initialId]. That
// pre-filled path is deliberately the *whole* interaction for a tapped
// address: nothing resolves until the user presses Start, because resolving a
// peer contacts that peer's server directly (federation is client-direct,
// PROTOCOL §9) -- so a tap that resolved by itself would hand the user's IP
// to a server chosen by whoever wrote the message.
//
// Pops the peer's account id on success, or null if dismissed.
import 'package:flutter/material.dart';

import '../screens/qr_scan_screen.dart';
import '../state/app_session.dart';
import '../state/contact_store.dart';
import '../util/errors.dart';
import '../util/invite_uri.dart';
import 'qr_scan_button.dart';

class NewChatSheet extends StatefulWidget {
  const NewChatSheet({
    super.key,
    required this.session,
    required this.contacts,
    this.initialId,
  });

  final AppSession session;

  /// Where the optional name goes (APP-19). Written only after
  /// [AppSession.startConversation] returns, because that is the first moment
  /// the peer's **canonical** id is known -- the field may hold a prefix, and a
  /// contact keyed by one would never match anything again.
  final ContactStore contacts;

  /// Pre-fills the address field, e.g. from a Freizone address tapped in a
  /// message. Null for the plain "new chat" case.
  final String? initialId;

  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  final _idController = TextEditingController();
  final _nameController = TextEditingController();
  final _greetingController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialId != null) _idController.text = widget.initialId!;
  }

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    _greetingController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final peerAccountId = _idController.text.trim();
    if (peerAccountId.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final convo = await widget.session.startConversation(peerAccountId);
      // Now, and keyed by the resolved id rather than by what was typed.
      final name = _nameController.text.trim();
      if (name.isNotEmpty) {
        await widget.contacts.setName(
          convo.peerAccountId,
          name: name,
          server: convo.peerServer,
        );
      }
      final greeting = _greetingController.text.trim();
      if (greeting.isNotEmpty) {
        // Contact is already added either way -- a failed greeting send
        // isn't worth blocking on, since it can just be retried manually
        // from the chat that's about to open.
        try {
          await widget.session.sendMessage(convo.peerAccountId, greeting);
        } catch (_) {
          // ignore
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(convo.peerAccountId);
    } catch (e) {
      setState(() {
        _error = describeError(e);
        _loading = false;
      });
    }
  }

  /// Pushes the QR scanner and, on a recognizable freizone://chat result
  /// (lib/util/invite_uri.dart), fills the address and name fields --
  /// same pre-fill pattern as the setup wizard's own invite scan.
  Future<void> _scanQr() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw == null || !mounted) return;

    final invite = parseChatInviteUri(raw);
    if (invite == null) {
      setState(() => _error = 'That QR code is not a Freizone chat invite');
      return;
    }

    setState(() {
      _idController.text = '${invite.id}*${invite.server}';
      if (invite.name != null) _nameController.text = invite.name!;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Start a new chat',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: _idController,
                  // Only when there is nothing to read yet: a pre-filled
                  // address is already what the user asked for, so popping
                  // the keyboard over it would just be in the way.
                  autofocus: widget.initialId == null,
                  decoration: const InputDecoration(
                    labelText: 'Peer account id',
                  ),
                  enabled: !_loading,
                ),
              ),
              const SizedBox(width: 12),
              QrScanButton(
                onPressed: _loading ? null : _scanQr,
                tooltip: 'Scan a chat invite QR code',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Full id, first 5 characters, or a full address like id*server',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Name (optional)'),
            enabled: !_loading,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _greetingController,
            decoration: const InputDecoration(
              labelText: 'Add a message (optional)',
              helperText:
                  'Sent right away -- helps them recognize who\'s reaching out',
            ),
            enabled: !_loading,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _start(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loading ? null : _start,
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Start chat'),
          ),
        ],
      ),
    );
  }
}
