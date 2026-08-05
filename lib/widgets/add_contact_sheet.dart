// Creating a contact by hand, from an address (APP-19).
//
// The only path that has to resolve an address itself: a contact made by naming
// somebody in a chat or a group already has their canonical id. Here the user
// types it, so it may be a prefix -- and a contact keyed by a prefix is one that
// fails the first time it is used. See contact_resolver.dart.
import 'package:flutter/material.dart';

import '../state/contact_resolver.dart';
import '../state/contact_store.dart';
import '../widgets/qr_scan_button.dart';
import '../screens/qr_scan_screen.dart';
import '../util/errors.dart';
import '../util/invite_uri.dart';

class AddContactSheet extends StatefulWidget {
  const AddContactSheet({
    super.key,
    required this.contacts,
    required this.fallbackServer,
  });

  final ContactStore contacts;

  /// Which server to ask when the typed address names none -- the active
  /// account's, the same convention the new-chat sheet uses for a bare id.
  final String fallbackServer;

  @override
  State<AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<AddContactSheet> {
  final _addressController = TextEditingController();
  final _nameController = TextEditingController();
  bool _resolving = false;
  String? _error;

  /// True when the failure said nothing about the address -- the server could
  /// not be asked -- so the button becomes "Try again" rather than leaving the
  /// user to guess whether their input was wrong.
  bool _retryable = false;

  @override
  void dispose() {
    _addressController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final address = _addressController.text.trim();
    final name = _nameController.text.trim();
    if (address.isEmpty || name.isEmpty) return;

    setState(() {
      _resolving = true;
      _error = null;
      _retryable = false;
    });
    try {
      final resolved = await resolveContactAddress(
        address,
        fallbackServer: widget.fallbackServer,
      );
      // Only now, and only the canonical form. Nothing is written before the
      // address is known to exist: a contact that could not be resolved would
      // be discovered as broken later, by which time nobody remembers typing it.
      await widget.contacts.setName(
        resolved.accountId,
        name: name,
        server: resolved.server,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ContactResolutionException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _retryable = e.worthRetrying;
        _resolving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeError(e);
        _resolving = false;
      });
    }
  }

  /// Same pre-fill as the new-chat sheet: a chat-invite QR carries an address
  /// and often a name, and both belong in exactly these two fields.
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
      _addressController.text = '${invite.id}*${invite.server}';
      if (invite.name != null && _nameController.text.isEmpty) {
        _nameController.text = invite.name!;
      }
      _error = null;
      _retryable = false;
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
            'Add a contact',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _addressController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Address'),
                  enabled: !_resolving,
                ),
              ),
              const SizedBox(width: 12),
              QrScanButton(
                onPressed: _resolving ? null : _scanQr,
                tooltip: 'Scan a chat invite QR code',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Full id, first 5 characters, or a full address like id*server. '
            'It is checked before the contact is saved.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Name'),
            enabled: !_resolving,
            textCapitalization: TextCapitalization.words,
            onSubmitted: (_) => _save(),
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
            onPressed: _resolving ? null : _save,
            child: _resolving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_retryable ? 'Try again' : 'Save contact'),
          ),
        ],
      ),
    );
  }
}
