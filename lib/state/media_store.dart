// Where attachment files live on disk, and what the UI knows about ones
// still being fetched (APP-04).
//
// Two deliberately separate kinds of state:
//
//   * The FILES are the persistent truth. A picture exists locally exactly
//     when its file exists -- no bookkeeping to keep in sync, and nothing to
//     repair after a crash.
//   * The IN-FLIGHT state (downloading, failed) lives only in memory. It is
//     meaningless after a restart: an interrupted download simply starts
//     again when the bubble scrolls back into view.
//
// Image bytes never go into AppState. That whole profile is rewritten on
// every message (see LocalStateStore.saveProfile), so a picture in there
// would make every single chat write cost megabytes.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// What the UI should show for an attachment that isn't on disk yet.
enum MediaFetchState { idle, downloading, failed }

/// Resolves attachment file paths and tracks in-flight downloads.
class MediaStore extends ChangeNotifier {
  MediaStore._(this._root);

  static Future<MediaStore>? _instance;

  /// The one store for this isolate. A single instance keeps the in-flight
  /// map meaningful across screens; the background push isolate gets its
  /// own, which is fine -- it only writes thumbnails, never downloads.
  ///
  /// What is cached is the *future*, not the resolved store: finding the
  /// documents directory is a platform-channel round trip, and two callers
  /// arriving while it is still in flight -- an arriving picture's prefetch
  /// and the bubble that draws it, routinely at once when a notification
  /// cold-starts the app -- each used to build a store of their own. They
  /// agreed about the files, since every path is derived from ids, but not
  /// about the in-flight map: whichever store lost the assignment had
  /// listeners nobody would ever notify again, so a picture whose download
  /// somebody else had already claimed spun until its bubble was rebuilt
  /// from scratch.
  static Future<MediaStore> instance() => _instance ??= _create();

  static Future<MediaStore> _create() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return MediaStore._(dir.path);
    } catch (_) {
      // Deliberately not left cached: a rejected future would turn one
      // transient failure into a permanent one for the whole isolate.
      _instance = null;
      rethrow;
    }
  }

  final String _root;

  /// In-flight downloads, keyed exactly like the file each one is fetching.
  ///
  /// A message id alone is *not* that key, which is what this used to use. One
  /// received message id exists once per account that received it, and every
  /// account has its own file to fetch: with several accounts on one device --
  /// all of them members of the same group, which is exactly how this app gets
  /// tested -- the first account's download made every other account's look
  /// already claimed. They waited for it instead of starting their own, and the
  /// file they were waiting for was never theirs, so the notification when it
  /// landed left them with nothing to adopt and nothing further to wait for:
  /// a picture that spun until its bubble was rebuilt from scratch.
  final Map<String, MediaFetchState> _fetching = {};

  static String _fetchKey(String accountId, String chatId, String messageId) =>
      '$accountId/$chatId/$messageId';

  MediaFetchState stateFor({
    required String accountId,
    required String chatId,
    required String messageId,
  }) =>
      _fetching[_fetchKey(accountId, chatId, messageId)] ?? MediaFetchState.idle;

  void markFetching({
    required String accountId,
    required String chatId,
    required String messageId,
  }) {
    _fetching[_fetchKey(accountId, chatId, messageId)] =
        MediaFetchState.downloading;
    notifyListeners();
  }

  void markFailed({
    required String accountId,
    required String chatId,
    required String messageId,
  }) {
    _fetching[_fetchKey(accountId, chatId, messageId)] = MediaFetchState.failed;
    notifyListeners();
  }

  void clearFetchState({
    required String accountId,
    required String chatId,
    required String messageId,
  }) {
    _fetching.remove(_fetchKey(accountId, chatId, messageId));
    notifyListeners();
  }

  /// Directory holding one account's media, one subdirectory per chat.
  ///
  /// Nesting by chat makes deleting a conversation a single recursive
  /// directory removal rather than a hunt for individual files.
  Directory accountDir(String accountId) =>
      Directory(_join([_root, 'media', accountId]));

  /// [chatId] is a [ChatTarget]'s id: a peer's account id for a one-to-one
  /// chat, a group id for a group. Both are 21-character bech32m strings, so
  /// the layout on disk is the same either way and needs no second scheme.
  Directory chatDir(String accountId, String chatId) =>
      Directory(_join([_root, 'media', accountId, chatId]));

  /// The full-resolution file for one message's attachment.
  ///
  /// Derived from ids rather than stored: the documents directory moves
  /// between app versions and device restores, so a persisted absolute path
  /// would eventually point nowhere. Message ids are already 16 random
  /// bytes, so they collide with nothing and leak nothing.
  File fileFor({
    required String accountId,
    required String chatId,
    required String messageId,
    String extension = 'jpg',
  }) => File(_join([
    _root,
    'media',
    accountId,
    chatId,
    '$messageId.$extension',
  ]));

  /// The inline preview that arrived with the message, written separately so
  /// something can be shown before the real file downloads.
  File thumbFor({
    required String accountId,
    required String chatId,
    required String messageId,
  }) => File(_join([
    _root,
    'media',
    accountId,
    chatId,
    '$messageId.thumb.jpg',
  ]));

  /// Writes bytes to [target] via a temp file and an atomic rename, so a
  /// reader can never observe a half-written image -- the same approach
  /// LocalStateStore uses for the profile.
  Future<void> writeFile(File target, Uint8List bytes) async {
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }

  /// Deletes one chat's media. Called when it is cleared or deleted, so
  /// pictures don't outlive the conversation they belong to.
  Future<void> deleteChatMedia(String accountId, String chatId) =>
      _deleteDir(chatDir(accountId, chatId));

  /// Deletes every picture belonging to an account, for account removal.
  Future<void> deleteAccountMedia(String accountId) =>
      _deleteDir(accountDir(accountId));

  Future<void> _deleteDir(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best effort: a picture left behind wastes space but breaks nothing,
      // and the caller is usually mid-deletion of something more important.
    }
  }

  /// Removes media files with no message left to show them -- messages
  /// deleted while the app was closed, or an upload that never completed.
  /// Cheap enough to run at startup: it stats a directory, not the files.
  Future<int> sweepOrphans({
    required String accountId,
    required Set<String> liveMessageIds,
  }) async {
    final dir = accountDir(accountId);
    if (!await dir.exists()) return 0;

    var removed = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final messageId = name.split('.').first;
      if (liveMessageIds.contains(messageId)) continue;
      try {
        await entity.delete();
        removed++;
      } catch (_) {
        // Ignore: another isolate may have removed it already.
      }
    }
    return removed;
  }

  static String _join(List<String> parts) => parts.join(Platform.pathSeparator);
}
