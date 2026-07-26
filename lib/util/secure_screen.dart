// Toggles Android's FLAG_SECURE for the current window via a MethodChannel
// (handled in MainActivity.kt), so a screen showing the recovery phrase can't
// be captured by a screenshot or screen recording. Best-effort and a no-op on
// non-Android platforms; a deliberate photo with a second camera is still
// possible -- that stays the user's own choice.
import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('freizone/secure_screen');

Future<void> enableSecureScreen() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod('enable');
  } on PlatformException {
    // Best-effort: if the platform side isn't available, showing the phrase is
    // still more important than blocking on screenshot protection.
  }
}

Future<void> disableSecureScreen() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod('disable');
  } on PlatformException {
    // ignore
  }
}
