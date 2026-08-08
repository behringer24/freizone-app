// The device-wide stores must survive a file they cannot read, and must not
// produce one.
//
// Both halves come from a real failure: an account reported "push registration
// failed: FormatException: Unexpected end of input (at character 1)". That is
// json.decode on an empty string, thrown out of AppSettings.load and caught
// several layers up by whatever happened to be asking -- here, the push
// registration that reads the settings on every stream reconnect.
//
// The file was intact by the time it was looked at, which is the tell. These
// stores used writeAsString, which truncates before it writes, so there is a
// window in which the file is empty; this app has several readers -- one per
// connected account, plus the background push isolate -- that can land in it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/app_settings.dart';
import 'package:freizone/state/contact_store.dart';

void main() {
  late Directory tempDir;

  File settingsFile() =>
      File('${tempDir.path}${Platform.pathSeparator}freizone_settings.json');
  File contactsFile() =>
      File('${tempDir.path}${Platform.pathSeparator}freizone_contacts.json');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('freizone_durability_test');
    // path_provider has no implementation under `flutter test`, so point the
    // stores at a scratch directory via its platform channel.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tempDir.path,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('AppSettings', () {
    test('an empty file loads as defaults instead of throwing', () async {
      await settingsFile().writeAsString('');

      // The exact shape the device reported: an empty file, read by something
      // that had no reason to expect one.
      final settings = await AppSettings.load();
      expect(settings.themeMode, ThemeMode.system);
      expect(settings.pushPreference, PushPreference.automatic);
    });

    test('a truncated file loads as defaults', () async {
      await settingsFile().writeAsString('{"theme_mode": "da');
      expect((await AppSettings.load()).themeMode, ThemeMode.system);
    });

    test('a good file still loads', () async {
      final settings = await AppSettings.load();
      await settings.setThemeMode(ThemeMode.dark);
      expect((await AppSettings.load()).themeMode, ThemeMode.dark);
    });

    // What this can and cannot show. The window a non-atomic write opens is
    // only visible *during* the write, so no test here proves atomicity --
    // that is the rename in _save, and the comment beside it. What is checked
    // is the observable postcondition: valid JSON afterwards, and no temp file
    // left lying around, which a rename cannot leave behind but a copy would.
    test('a save leaves valid JSON and no leftovers', () async {
      final settings = await AppSettings.load();
      await settings.setThemeMode(ThemeMode.dark);

      final written = await settingsFile().readAsString();
      expect(written, isNotEmpty);
      expect(
        () => json.decode(written),
        returnsNormally,
        reason: 'a reader arriving right after a save must find valid JSON',
      );
      // No temp file left over -- a rename moves it, it does not copy it.
      final leftovers = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });

  group('ContactStore', () {
    test('a damaged file is kept aside, not overwritten', () async {
      await contactsFile().writeAsString('{"contacts": [truncated');

      final store = await ContactStore.load();
      expect(store.isEmpty, isTrue);

      // Names the user chose are not settings: starting empty is acceptable,
      // silently destroying them is not.
      final kept = File('${contactsFile().path}.damaged');
      expect(kept.existsSync(), isTrue);
      expect(await kept.readAsString(), '{"contacts": [truncated');
      expect(contactsFile().existsSync(), isFalse);
    });

    test('a good file still loads, and saving leaves valid JSON', () async {
      final store = await ContactStore.load();
      await store.setName(
        'fz1peer',
        name: 'Someone',
        server: 'https://example.test',
      );

      final written = await contactsFile().readAsString();
      expect(() => json.decode(written), returnsNormally);
      expect((await ContactStore.load()).contacts, isNotEmpty);
    });
  });
}
