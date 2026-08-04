// Shared long-press actions on a single message -- used from chat_screen.dart
// and group_chat_screen.dart, so pinning and deleting behave, and are worded,
// identically in a one-to-one chat and in a group (APP-21).
//
// Both are purely local: nothing here is sent to the peer, to the group or to
// the server. That is also why the wording matters enough to keep in one
// place -- "delete" in a messenger usually means "for everyone", and here it
// never does.
import 'package:flutter/material.dart';

import '../state/app_session.dart';

/// Asks before dropping a message from this device's own history, and drops it
/// on confirmation. `chatId` is a peer account id or a group id -- see
/// AppSession.chatTarget.
Future<void> confirmAndDeleteMessage(
  BuildContext context,
  AppSession session, {
  required String chatId,
  required String messageId,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete message?'),
      content: const Text(
        'This removes the message from this device only -- everyone else keeps '
        'their copy, and this cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await session.deleteMessageLocally(chatId, messageId);
  }
}
