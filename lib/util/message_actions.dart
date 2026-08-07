// Shared long-press actions on a single message -- used from chat_screen.dart
// and group_chat_screen.dart, so pinning and deleting behave, and are worded,
// identically in a one-to-one chat and in a group (APP-21).
//
// Both are purely local: nothing here is sent to the peer, to the group or to
// the server. That is also why the wording matters enough to keep in one
// place -- "delete" in a messenger usually means "for everyone", and here it
// never does.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../state/app_session.dart';
import '../state/chat_target.dart';
import '../state/media_store.dart';
import 'gallery.dart';

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

/// The picture [message] carries, if there is one on this device right now
/// (APP-20) -- otherwise null.
///
/// Null covers every reason there is nothing to act on, and callers use it to
/// leave the save/share entries *out* of a menu rather than showing entries
/// that would fail: no attachment, an attachment that is not a picture, a
/// system line, or -- the case worth naming -- a picture whose download has
/// not finished, since the file is the only record that it has (see
/// MediaStore's header).
Future<File?> attachedPictureFile(
  AppSession session, {
  required String chatId,
  required StoredMessage message,
}) async {
  if (message.kind != StoredMessageKind.normal) return null;
  if (!message.hasAttachments) return null;
  if (!message.attachments.first.isImage) return null;
  final media = await MediaStore.instance();
  final file = media.fileFor(
    accountId: session.state.accountId,
    chatId: chatId,
    messageId: message.id,
  );
  return await file.exists() ? file : null;
}

/// Whether a picture in [message] may be saved to the gallery.
///
/// Only a *received* one. A picture this account sent came out of this
/// device's own gallery to begin with, so saving it would file a second copy
/// of something already there. (Worth revisiting once APP-04's camera capture
/// lands: a self-taken picture is written to the app's cache, not the gallery,
/// and would then be one that exists nowhere else.) Sharing is not limited
/// this way -- a different destination each time is the point of it.
bool maySavePicture(StoredMessage message) => !message.mine;

/// Copies a picture into the device gallery and reports what happened.
///
/// Shared by both chat screens and the full-screen viewer so the wording is
/// identical everywhere, and because what it has to say is not obvious: this
/// is the moment a picture leaves the app's private storage, and a refused
/// permission has to leave it where it was and say so rather than fail mute.
Future<void> savePictureToGallery(BuildContext context, File file) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await saveImageToGallery(file);
  if (!context.mounted) return;
  final text = switch (result) {
    GallerySaveResult.saved => 'Saved to your gallery',
    GallerySaveResult.permissionDenied =>
      'Freizone needs permission to write to your gallery. The picture is '
          'still here -- try again to be asked once more.',
    GallerySaveResult.failed => 'Could not save the picture',
    GallerySaveResult.unsupported => 'Saving to the gallery is not available here',
  };
  messenger.showSnackBar(SnackBar(content: Text(text)));
}

/// Hands a picture to whatever app the user picks in the system share sheet.
///
/// Save and share are both offered because they are different destinations,
/// not two names for one thing: saving files a copy in the gallery, sharing
/// hands the bytes straight to another app without one ever landing there.
Future<void> sharePicture(File file) async {
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
}
