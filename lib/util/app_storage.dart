// The one directory Freizone keeps its files in: profiles, settings, contacts
// and each account's core state (APP-03).
//
// On Android that is the app's documents directory, as it always was. On iOS it
// is the App Group container, because a push wake there is handled by a
// Notification Service Extension -- a separate process that has to open the
// very same accounts (see ios/Runner/SharedStorage.swift, which also moves an
// existing install's files there before Dart reads any of them). A build
// without the App Group falls back to the documents directory as well.
//
// Every place that used to ask path_provider for the documents directory asks
// here instead, so the two platforms cannot drift into reading different
// places.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

Future<Directory?>? _iosDirectory;

/// Freizone's data directory.
///
/// Only the iOS answer is remembered (it cannot change while the app runs);
/// everywhere else this asks path_provider every time, exactly as the callers
/// did before, so a test that points path_provider at a fresh directory per
/// test still gets that directory.
Future<Directory> appDataDirectory() async {
  if (Platform.isIOS) {
    final shared = await (_iosDirectory ??= _askIOS());
    if (shared != null) return shared;
  }
  return getApplicationDocumentsDirectory();
}

Future<Directory?> _askIOS() async {
  try {
    final path = await const MethodChannel(
      'freizone/storage',
    ).invokeMethod<String>('directory');
    return path == null ? null : Directory(path);
  } on MissingPluginException {
    // An engine without the app's own channels; documents it is.
  } on PlatformException {
    // Same.
  }
  return null;
}
