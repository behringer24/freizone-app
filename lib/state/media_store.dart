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

  static MediaStore? _instance;

  /// The one store for this isolate. A single instance keeps the in-flight
  /// map meaningful across screens; the background push isolate gets its
  /// own, which is fine -- it only writes thumbnails, never downloads.
  static Future<MediaStore> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    return _instance = MediaStore._(dir.path);
  }

  final String _root;

  final Map<String, MediaFetchState> _fetching = {};

  MediaFetchState stateFor(String messageId) =>
      _fetching[messageId] ?? MediaFetchState.idle;

  void markFetching(String messageId) {
    _fetching[messageId] = MediaFetchState.downloading;
    notifyListeners();
  }

  void markFailed(String messageId) {
    _fetching[messageId] = MediaFetchState.failed;
    notifyListeners();
  }

  void clearFetchState(String messageId) {
    _fetching.remove(messageId);
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
