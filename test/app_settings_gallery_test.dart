// APP-20's automatic gallery save is the one setting whose default decides
// whether pictures leave the app's sandbox, so the risk worth testing is not
// that the toggle works but that it is *off* unless somebody turned it on --
// including on an install that predates the setting, whose stored preferences
// have no such key. An update must never start copying pictures out.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/app_settings.dart';

void main() {
  late Directory tempDir;

  File settingsFile() =>
      File('${tempDir.path}${Platform.pathSeparator}freizone_settings.json');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('freizone_settings_test');
    // path_provider has no implementation under `flutter test`, so point
    // AppSettings at a scratch directory via its platform channel.
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

  test('a fresh install does not save pictures to the gallery', () async {
    final settings = await AppSettings.load();
    expect(settings.autoSavePicturesToGallery, isFalse);
  });

  test('an install predating the setting reads as off', () async {
    // Exactly what an older build wrote: every other key, and no gallery one.
    settingsFile().writeAsStringSync(
      json.encode({
        'theme_mode': 'dark',
        'read_receipts_enabled': true,
        'direct_share_enabled': true,
      }),
    );

    final settings = await AppSettings.load();
    expect(settings.autoSavePicturesToGallery, isFalse);
    // The unrelated settings still came through, so this is really the
    // missing-key path and not a file that failed to parse.
    expect(settings.directShareEnabled, isTrue);
  });

  test('the choice survives a reload', () async {
    final settings = await AppSettings.load();
    await settings.setAutoSavePicturesToGallery(true);
    expect((await AppSettings.load()).autoSavePicturesToGallery, isTrue);

    await settings.setAutoSavePicturesToGallery(false);
    expect((await AppSettings.load()).autoSavePicturesToGallery, isFalse);
  });
}
