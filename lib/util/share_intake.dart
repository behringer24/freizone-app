// Receiving a share from another app (APP-15).
//
// The Android side (MainActivity.kt) captures an ACTION_SEND intent, copies
// any shared image out of the sending app's content:// URI into our cache, and
// parks the result. This is the Dart half.
//
// Pull-based on purpose: a share can arrive as a *cold start*, where the
// process exists only because the user picked Freizone in the share sheet. At
// that moment nothing in Dart is ready to show a target picker, so the native
// side never pushes -- it waits to be asked, once accounts are loaded.
// [onShareReceived] exists only for the warm case, where the app was already
// running and should react immediately.
import 'package:flutter/services.dart';

import '../state/outgoing_attachment.dart';

const _channel = MethodChannel('freizone/share_intake');

/// What another app handed us. At least one of [text] and [imagePath] is
/// non-null; both can be set (an image with a caption).
class IncomingShare {
  const IncomingShare({this.text, this.imagePath, this.shortcutId});

  final String? text;

  /// A file in our own cache, already copied out of the sender's URI. Not
  /// trusted to be an image -- the caller decodes it to find out.
  final String? imagePath;

  /// Set when the share came through one of our own sharing shortcuts, which
  /// already identifies the target conversation, so the picker can be skipped.
  /// Format is `<accountId>|<peerAccountId>` (see share_shortcuts.dart).
  final String? shortcutId;

  bool get isEmpty => (text == null || text!.isEmpty) && imagePath == null;

  static IncomingShare? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final share = IncomingShare(
      text: map['text'] as String?,
      imagePath: map['imagePath'] as String?,
      shortcutId: map['shortcutId'] as String?,
    );
    return share.isEmpty ? null : share;
  }
}

/// Collects a share the platform is holding, if any, and clears it there --
/// so a rotation or a resume cannot deliver the same share twice.
Future<IncomingShare?> takePendingShare() async {
  try {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'takePendingShare',
    );
    return IncomingShare.fromMap(result);
  } on MissingPluginException {
    return null; // not Android, or the channel isn't wired up
  } on PlatformException {
    return null;
  }
}

/// Downscales and JPEG-re-encodes a shared image to the same constraints a
/// gallery pick gets, returning the new path (the original is removed) or null
/// if it couldn't be decoded.
///
/// This has to happen, and it has to happen natively. A gallery pick is
/// downscaled and re-encoded by image_picker before Dart ever sees it, so a
/// *shared* picture must get the same treatment or it would go out at full
/// camera resolution — costing the recipient quota and bandwidth, and running
/// into the receiving server's `max_blob_bytes` (SRV-07) where a gallery pick
/// never would. Natively, because dart:ui can only encode PNG, which for a
/// photo is larger than the JPEG it started as.
///
/// The limits are passed in rather than duplicated on the platform side, so
/// [maxSentImageEdge] and [sentImageQuality] stay the single source of truth.
Future<String?> normalizeSharedImage(String path) async {
  try {
    return await _channel.invokeMethod<String>('normalizeImage', {
      'path': path,
      'maxEdge': maxSentImageEdge,
      'quality': sentImageQuality,
    });
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// Called when a share arrives while the app is already running. The payload
/// still has to be fetched with [takePendingShare]; this is only the nudge.
void onShareReceived(void Function() handler) {
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'shareReceived') handler();
    return null;
  });
}
