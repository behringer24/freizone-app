// Shared "set/change/remove local alias" dialog -- used by chat_screen.dart
// (its AppBar edit icon) and peer_profile_screen.dart (its "Peer name" row),
// both of which just want back the new name (or '' for "remove") and leave
// actually saving it to the caller.
import 'package:flutter/material.dart';

class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key, required this.initialName});

  final String initialName;

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
    return AlertDialog(
      title: const Text('Edit name'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('Remove'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
