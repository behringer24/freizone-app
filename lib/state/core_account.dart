// The app's view of one open account in the shared core (SRV-23 stage 6).
//
// Everything the UI needs about chats, messages, contacts and groups comes
// through here. The core owns the state; this owns the handle, the models the
// widgets read, and one rule the shell cannot delegate:
//
// **A call that touches the network runs in an isolate. A call that reads local
// state does not.**
//
// That split is not an optimisation, it is the difference between a list that
// scrolls and an app that freezes. Reading the chat list is a few small file
// reads and answers in microseconds; sending a message opens a connection,
// maybe claims a prekey bundle, and takes as long as the network takes. Both
// are one synchronous C call, and only knowing which is which keeps the second
// kind off the UI thread.
//
// The isolate entry points are top-level functions taking plain values, because
// an isolate cannot capture a [FreizoneCore] -- it holds native pointers. The
// handle is a number and the library is already loaded in the process, so
// opening the bindings again inside the isolate is cheap.
import 'dart:async';
import 'dart:isolate';

import '../ffi/core_models.dart';
import '../ffi/freizone_core.dart';

/// One open account, addressed by the handle the core gave us.
class CoreAccount {
  CoreAccount({required this.core, required this.handle, this.libraryPath});

  final FreizoneCore core;
  final int handle;

  /// Passed to every isolate: null lets the platform find the library, which is
  /// right in the app, but a host test loaded it from a path and an isolate
  /// cannot find it by name.
  final String? libraryPath;

  // --- local reads ---------------------------------------------------------

  /// The chat list, peers and groups in one list ordered by one clock.
  List<ChatSummary> chats() => core.coreChats(handle);

  /// One chat's whole transcript.
  List<CoreMessage> messages(String chatId) =>
      core.coreMessages(handle, chatId);

  /// Everything about a group: membership, roles, and how far each member has
  /// got with our messages.
  GroupInfo groupInfo(String groupId) => core.coreGroupInfo(handle, groupId);

  /// Tells the core which chat is on screen, which is the only thing that
  /// suppresses a notification. Passing null means none is.
  void setOpenChat(String? chatId) =>
      core.coreSetOpenChat(handle, chatId ?? '');

  void blockPeer(String accountId, {String server = ''}) =>
      core.coreBlockPeer(handle, accountId, server);

  void unblockPeer(String accountId) => core.coreUnblockPeer(handle, accountId);

  /// Accepts a message request, which is also what makes the sender known --
  /// so deleting the chat later and hearing from them again does not arrive as
  /// a fresh request.
  void acceptRequest(String accountId) =>
      core.coreAcceptRequest(handle, accountId);

  /// Deletes a chat locally. The secure session deliberately survives: the peer
  /// does not know their chat was deleted here, and discarding it would make
  /// their next message look like a desync.
  void deleteChat(String chatId) => core.coreDeleteChat(handle, chatId);

  // --- network -------------------------------------------------------------

  /// Sends into a chat, whichever kind it is -- the id says which.
  ///
  /// The transcript line exists either way: it is written before the network is
  /// touched, so a failure leaves it marked failed rather than losing what the
  /// user typed. That is why a caller should refresh on both outcomes.
  Future<CoreMessage> send(
    String chatId,
    String text, {
    String? replyToId,
    String? replyPreviewText,
    bool? replyPreviewMine,
    String? mediaPath,
    String? thumbPath,
    String? mimeType,
    int width = 0,
    int height = 0,
  }) async {
    final raw = await _run({
      'call': 'send',
      'handle': handle,
      'chat_id': chatId,
      'text': text,
      'reply_to_id': ?replyToId,
      'reply_preview_text': ?replyPreviewText,
      'reply_preview_mine': ?replyPreviewMine,
      'media_path': ?mediaPath,
      'thumb_path': ?thumbPath,
      'mime_type': ?mimeType,
      if (width > 0) 'width': width,
      if (height > 0) 'height': height,
    });
    return CoreMessage.fromJson(raw);
  }

  Future<CoreMessage> retry(String chatId, String messageId) async {
    final raw = await _run({
      'call': 'retry',
      'handle': handle,
      'chat_id': chatId,
      'message_id': messageId,
    });
    return CoreMessage.fromJson(raw);
  }

  /// Clears the unread flag and confirms to the sender that it was read.
  Future<void> markRead(String chatId) =>
      _run({'call': 'mark_read', 'handle': handle, 'chat_id': chatId});

  Future<ChatSummary> startConversation(
    String address, {
    String server = '',
  }) async {
    final raw = await _run({
      'call': 'start_conversation',
      'handle': handle,
      'address': address,
      'server': server,
    });
    return ChatSummary.fromJson(raw);
  }

  /// Where a message's picture is on disk, downloading it first if it has not
  /// been downloaded. Empty when there is nothing to show yet, which is the
  /// normal state of a picture nobody has looked at and not an error.
  Future<String> attachmentPath(
    String chatId,
    String messageId, {
    bool thumb = false,
  }) async {
    final raw = await _run({
      'call': 'attachment_path',
      'handle': handle,
      'chat_id': chatId,
      'message_id': messageId,
      'thumb': thumb,
    });
    return raw['path'] as String? ?? '';
  }

  /// The housekeeping a fresh connection should do: top up the prekey pool,
  /// settle group facts owed, re-establish sessions the evidence says are
  /// broken. Never throws for a part that failed -- see [MaintenanceReport].
  Future<MaintenanceReport> maintain() async {
    final raw = await _run({'call': 'maintain', 'handle': handle});
    return MaintenanceReport.fromJson(raw);
  }

  Future<void> resetSession(String accountId) => _run({
    'call': 'reset_session',
    'handle': handle,
    'account_id': accountId,
  });

  // --- groups --------------------------------------------------------------

  Future<String> createGroup(String name) async {
    final raw = await _run({
      'call': 'group_create',
      'handle': handle,
      'name': name,
    });
    return raw['group_id'] as String;
  }

  Future<void> invite(String groupId, String address, {String server = ''}) =>
      _run({
        'call': 'group_invite',
        'handle': handle,
        'group_id': groupId,
        'account_id': address,
        'server': server,
      });

  Future<void> acceptInvitation(String groupId) =>
      _run({'call': 'group_accept', 'handle': handle, 'group_id': groupId});

  Future<void> setRole(
    String groupId,
    String accountId,
    String role, {
    required bool grant,
  }) => _run({
    'call': 'group_set_role',
    'handle': handle,
    'group_id': groupId,
    'account_id': accountId,
    'role': role,
    'grant': grant,
  });

  Future<void> removeMember(String groupId, String accountId) => _run({
    'call': 'group_remove',
    'handle': handle,
    'group_id': groupId,
    'account_id': accountId,
  });

  Future<void> leaveGroup(String groupId) =>
      _run({'call': 'group_leave', 'handle': handle, 'group_id': groupId});

  Future<void> setGroupMeta(String groupId, String name, String topic) => _run({
    'call': 'group_set_meta',
    'handle': handle,
    'group_id': groupId,
    'name': name,
    'topic': topic,
  });

  Future<void> dissolveGroup(String groupId) =>
      _run({'call': 'group_dissolve', 'handle': handle, 'group_id': groupId});

  Future<Map<String, dynamic>> _run(Map<String, dynamic> request) {
    final path = libraryPath;
    return Isolate.run(() => coreCallInIsolate(request, path));
  }
}

/// Runs one blocking core call. Top-level and taking only plain values, because
/// an isolate entry point cannot capture anything holding a native pointer.
///
/// The `call` key names which one, rather than passing a function: a closure
/// over a Dart function value cannot cross into an isolate either, and a name
/// that no case matches fails loudly here instead of silently doing nothing.
Map<String, dynamic> coreCallInIsolate(
  Map<String, dynamic> request,
  String? libraryPath,
) {
  final core = FreizoneCore(libraryPath: libraryPath);
  final name = request['call'] as String;
  final handle = request['handle'] as int;

  switch (name) {
    case 'send':
      return core.coreSendRaw(request);
    case 'retry':
      return core.coreRetryRaw(request);
    case 'mark_read':
      return core.coreMarkReadRaw(request);
    case 'start_conversation':
      return core.coreStartConversationRaw(request);
    case 'attachment_path':
      return core.coreAttachmentPathRaw(request);
    case 'maintain':
      return core.coreMaintainRaw({'handle': handle});
    case 'reset_session':
      return core.coreResetSessionRaw(request);
    case 'group_create':
      return core.coreGroupCreateRaw(request);
    case 'group_invite':
      return core.coreGroupInviteRaw(request);
    case 'group_accept':
      return core.coreGroupAcceptRaw(request);
    case 'group_set_role':
      return core.coreGroupSetRoleRaw(request);
    case 'group_remove':
      return core.coreGroupRemoveRaw(request);
    case 'group_leave':
      return core.coreGroupLeaveRaw(request);
    case 'group_set_meta':
      return core.coreGroupSetMetaRaw(request);
    case 'group_dissolve':
      return core.coreGroupDissolveRaw(request);
  }
  throw ArgumentError('unknown core call "$name"');
}
