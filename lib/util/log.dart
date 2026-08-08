// Diagnostics that reach a connected debugger *and*, in a debug build, logcat.
//
// developer.log alone goes to the VM service, which means it is visible in the
// IDE and nowhere else: `adb logcat` shows nothing, so a problem on a real
// device can only be described rather than read. That is a poor trade when the
// device is the only place a problem reproduces -- which, for anything touching
// the network, is most of them.
//
// print() is what reaches logcat, as `I/flutter`. It is gated on kDebugMode
// here so a release build stays quiet: these lines carry account ids, server
// addresses and failure text, and logcat is readable by more than the app.
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Logs one diagnostic line.
///
/// [name] groups related lines and is what a `logcat | grep` looks for -- keep
/// it short and stable ("freizone", "push", "receipts") rather than describing
/// the individual event.
void logDiagnostic(String message, {String name = 'freizone'}) {
  developer.log(message, name: name);
  if (kDebugMode) {
    // ignore: avoid_print
    print('[$name] $message');
  }
}
