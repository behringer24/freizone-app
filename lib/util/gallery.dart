// Copies a received picture out of the app's private storage and into the
// device's own gallery (APP-20), over a MethodChannel handled in
// MainActivity.kt -- the same shape as secure_screen.dart and
// share_intake.dart, and for the same reason: one platform call does not earn
// a dependency.
//
// This is the one place where a picture leaves the app's protection. Every
// other copy the app holds sits in its private directory, unreadable by other
// apps; a copy in the gallery is readable by anything holding media permission
// and, on most phones, uploaded to the user's cloud photo library within
// minutes. That is exactly what the user asked for when they tap Save -- and
// exactly why the automatic variant (AppSettings.autoSaveReceivedPictures) is
// opt-in and says so.
import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('freizone/gallery');

/// What became of a save. Every outcome is reportable to the user: a refusal
/// has to leave the picture where it was and say so, never fail silently.
enum GallerySaveResult {
  saved,

  /// The storage permission was refused (API 24-28 only -- from API 29 on the
  /// save needs no permission). Re-askable: the next attempt asks again.
  permissionDenied,

  /// The copy itself failed -- no space, an unreadable source, a provider that
  /// refused the insert.
  failed,

  /// No platform side at all: iOS, desktop, a unit test, or the background
  /// isolate, whose engine never registered the channel. Not an error, and
  /// deliberately distinct from [failed] so an automatic save can stay quiet
  /// while a manual one still reports something.
  ///
  /// Detected by the channel answering MissingPluginException rather than by
  /// asking Platform: whether this device can save a picture is exactly the
  /// question "is the handler there", and an isolate on Android with no
  /// handler registered would answer that question wrongly.
  unsupported,
}

/// Copies [file] into the device's picture gallery.
///
/// [mayPrompt] false suppresses the runtime permission dialog, for the
/// automatic save: a picture arriving in the background must not raise a
/// permission request with no visible action behind it. The manual save leaves
/// it true, so the first save is what explains why the permission is wanted.
Future<GallerySaveResult> saveImageToGallery(
  File file, {
  bool mayPrompt = true,
}) async {
  try {
    final outcome = await _channel.invokeMethod<String>('save', {
      'path': file.path,
      'mayPrompt': mayPrompt,
    });
    return switch (outcome) {
      'saved' => GallerySaveResult.saved,
      'permission_denied' => GallerySaveResult.permissionDenied,
      _ => GallerySaveResult.failed,
    };
  } on MissingPluginException {
    return GallerySaveResult.unsupported;
  } on PlatformException {
    return GallerySaveResult.failed;
  }
}

/// Asks for the storage permission without saving anything, returning whether
/// it is now held.
///
/// Used when the automatic-save setting is switched on, so the request arrives
/// while the user is looking at the toggle that explains it. On API 29+ this
/// grants immediately with no dialog, because nothing is needed there.
Future<bool> ensureGalleryPermission() async {
  try {
    final outcome = await _channel.invokeMethod<String>('requestPermission');
    return outcome == 'granted';
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}
