// The gallery channel (APP-20) is the one place a picture leaves the app's
// private storage, so what the platform answered must never be rounded up to
// "saved". These tests pin the mapping from the native reply to
// GallerySaveResult -- in particular that an unrecognised reply, a
// PlatformException and a missing implementation are three distinct outcomes:
// a refused permission has to be reportable ("the picture is still here, try
// again") while a channel that simply isn't there must stay quiet, because
// the automatic save runs where there may be no handler at all.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/util/gallery.dart';

void main() {
  const channel = MethodChannel('freizone/gallery');
  late File picture;
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('freizone_gallery_test');
    picture = File('${tempDir.path}${Platform.pathSeparator}p.jpg')
      ..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  void mockReply(Object? Function(MethodCall call) reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => reply(call));
  }

  test('a native "saved" is the only reply that reads as saved', () async {
    mockReply((_) => 'saved');
    expect(await saveImageToGallery(picture), GallerySaveResult.saved);

    mockReply((_) => 'permission_denied');
    expect(
      await saveImageToGallery(picture),
      GallerySaveResult.permissionDenied,
    );

    mockReply((_) => 'failed');
    expect(await saveImageToGallery(picture), GallerySaveResult.failed);

    // Anything the Dart side does not recognise -- including a null reply --
    // is a failure, never an optimistic success.
    mockReply((_) => 'something-new');
    expect(await saveImageToGallery(picture), GallerySaveResult.failed);

    mockReply((_) => null);
    expect(await saveImageToGallery(picture), GallerySaveResult.failed);
  });

  test('an automatic save asks the platform not to prompt', () async {
    MethodCall? seen;
    mockReply((call) {
      seen = call;
      return 'saved';
    });

    await saveImageToGallery(picture, mayPrompt: false);
    expect(seen!.method, 'save');
    expect((seen!.arguments as Map)['path'], picture.path);
    expect((seen!.arguments as Map)['mayPrompt'], isFalse);

    // The manual save is the moment a permission request can be explained, so
    // it keeps the prompt.
    await saveImageToGallery(picture);
    expect((seen!.arguments as Map)['mayPrompt'], isTrue);
  });

  test('no platform implementation is not a failure', () async {
    // No mock handler registered at all -- the background isolate's engine,
    // iOS, or a plain unit test. The automatic save has to stay silent here
    // rather than report a problem the user cannot act on.
    expect(await saveImageToGallery(picture), GallerySaveResult.unsupported);
    expect(await ensureGalleryPermission(), isFalse);
  });

  test('a platform exception fails rather than escaping', () async {
    mockReply((_) => throw PlatformException(code: 'boom'));
    expect(await saveImageToGallery(picture), GallerySaveResult.failed);
    expect(await ensureGalleryPermission(), isFalse);
  });

  test('the permission is only granted when the platform says so', () async {
    mockReply((_) => 'granted');
    expect(await ensureGalleryPermission(), isTrue);

    mockReply((_) => 'permission_denied');
    expect(await ensureGalleryPermission(), isFalse);
  });
}
