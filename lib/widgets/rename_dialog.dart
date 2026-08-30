// Shared "set/change/remove local alias" dialog -- used by chat_screen.dart
// (its AppBar edit icon) and peer_profile_screen.dart (its "Peer name" row),
// both of which just want back the new name (or '' for "remove") and leave
// actually saving it to the caller.
import 'package:flutter/material.dart';

class RenameDialog extends StatefulWidget {
  const RenameDialog({
    super.key,
    required this.initialName,
    this.suggestedName,
  });

  final String initialName;

  /// What this contact calls itself (APP-27), when it has said. Null when it
  /// has not, or when this dialog is naming something with no claim of its own.
  ///
  /// It changes what clearing the field *means*, which is why this dialog needs
  /// to know: with a suggestion, removing the local name does not leave the
  /// contact nameless, it hands the label back to them. The button says so
  /// rather than saying "Remove" and appearing to do something else.
  final String? suggestedName;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final suggested = widget.suggestedName;
    // Nothing to reset *to* unless they have named themselves and this device
    // has overridden it -- otherwise clearing the field is an ordinary removal.
    final canUseTheirs = suggested != null && widget.initialName.isNotEmpty;

    return AlertDialog(
      title: const Text('Edit name'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          if (suggested != null) ...[
            const SizedBox(height: 12),
            Text(
              'They call themselves $suggested.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          // Same action, honest wording: clearing the local name is exactly
          // what hands the label back to them, so calling it "Remove" where a
          // suggestion exists would describe an outcome that does not happen.
          child: Text(canUseTheirs ? 'Use their name' : 'Remove'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
