// Filling AppState from the core (SRV-23 stage 6, the cut).
//
// The screens read `session.state` at 83 places, so the cheapest correct swap
// is not to rewrite them: AppState stays as the view model and stops being the
// source of truth. Conversation, GroupConversation and StoredMessage remain the
// shapes widgets draw; what changes is where their contents come from.
//
// **Rebuilt whole, not merged.** A merge would need a rule for every field
// about which side wins, and the answer is always the same one -- the core --
// so the rule is better expressed as "there is nothing to merge". It also makes
// the failure mode loud: if something is missing from the core it is missing on
// screen, rather than lingering from a stale copy and looking fine until a
// reinstall.
//
// The cost is reading every transcript on every refresh. At the real scale
// measured on a device -- 11 accounts, 34 chats, 828 messages -- that is a few
// milliseconds of small file reads, and a diffing bridge is an optimisation to
// reach for when something has actually been measured, not before.
import 'dart:typed_data';

import '../ffi/core_models.dart';
import 'chat_target.dart';
import 'conversation.dart';
import 'group_conversation.dart';
import 'local_state.dart';
import 'message_content.dart';
import 'core_account.dart';

/// Replaces [state]'s chats with what the core holds.
///
/// Everything else on [state] -- the account id, the keys, the server -- is
/// identity and is not touched: the core has its own copy, and the app's is
/// what set it there in the first place.
void applyCoreState(AppState state, CoreAccount account) {
  final chats = account.chats();

  final conversations = <String, Conversation>{};
  final groups = <String, GroupConversation>{};

  for (final chat in chats) {
    final messages = account
        .messages(chat.chatId)
        .map(_toStoredMessage)
        .toList();

    if (chat.isGroup) {
      groups[chat.chatId] = _toGroupConversation(chat, messages, account);
    } else {
      conversations[chat.chatId] = _toConversation(chat, messages);
    }
  }

  state.conversations
    ..clear()
    ..addAll(conversations);
  state.groups
    ..clear()
    ..addAll(groups);
}

/// Refreshes one chat, for the common case where only one changed.
///
/// Same rebuild, narrower: a message arriving in one conversation should not
/// cost a read of every other one. Falls back to the full rebuild when the chat
/// is new to [state], since a row the list has never shown has to come from
/// somewhere.
void applyCoreChat(AppState state, CoreAccount account, String chatId) {
  final chats = account.chats();
  final chat = chats.where((c) => c.chatId == chatId).firstOrNull;
  if (chat == null) {
    // Gone -- deleted, or a group whose facts were dropped. Removing it here is
    // what keeps a deletion in the core from leaving a ghost row on screen.
    state.conversations.remove(chatId);
    state.groups.remove(chatId);
    return;
  }

  final messages = account.messages(chatId).map(_toStoredMessage).toList();
  if (chat.isGroup) {
    state.groups[chatId] = _toGroupConversation(chat, messages, account);
  } else {
    state.conversations[chatId] = _toConversation(chat, messages);
  }
}

Conversation _toConversation(ChatSummary chat, List<StoredMessage> messages) =>
    Conversation(
      peerAccountId: chat.chatId,
      peerServer: chat.peerServer.isEmpty ? null : chat.peerServer,
      // The device id and its key deliberately do not come across. They are the
      // core's business now -- it resolves, caches and forgets them as the
      // stale-device rule requires -- and a copy here could only go stale.
      messages: messages,
      lastActivityAt: chat.lastActivityAt,
      hasUnread: chat.hasUnread,
      pinnedMessageIds: List<String>.from(chat.pinnedMessageIds),
      blocked: chat.blocked,
      pendingApproval: chat.pendingApproval,
      peerDeliveredUpTo: chat.peerDeliveredUpTo,
      peerReadUpTo: chat.peerReadUpTo,
    );

GroupConversation _toGroupConversation(
  ChatSummary chat,
  List<StoredMessage> messages,
  CoreAccount account,
) {
  // Per-member read watermarks live with the membership rather than on the
  // summary: a chat list has no use for them, and a group screen asks for the
  // membership anyway.
  final memberReadUpTo = <String, DateTime>{};
  try {
    for (final member in account.groupInfo(chat.chatId).members) {
      final readUpTo = member.readUpTo;
      if (readUpTo != null) memberReadUpTo[member.accountId] = readUpTo;
    }
  } catch (_) {
    // A group whose facts have not arrived yet still has a transcript -- a
    // message can overtake the snapshot that introduces its group -- so it is
    // shown without membership rather than not at all.
  }

  return GroupConversation(
    groupId: chat.chatId,
    displayName: chat.title.isEmpty ? null : chat.title,
    messages: messages,
    lastActivityAt: chat.lastActivityAt,
    hasUnread: chat.hasUnread,
    pinnedMessageIds: List<String>.from(chat.pinnedMessageIds),
    invitePending: chat.invited,
    memberReadUpTo: memberReadUpTo,
  );
}

StoredMessage _toStoredMessage(CoreMessage m) => StoredMessage(
  id: m.id,
  text: m.text,
  mine: m.mine,
  timestamp: m.timestamp,
  senderSentAt: m.senderSentAt,
  senderAccountId: m.senderAccountId.isEmpty ? null : m.senderAccountId,
  replyToId: m.replyToId.isEmpty ? null : m.replyToId,
  replyPreviewText: m.replyPreviewText.isEmpty ? null : m.replyPreviewText,
  replyPreviewMine: m.replyPreviewMine,
  replyPreviewAuthorId: m.replyPreviewAuthorId.isEmpty
      ? null
      : m.replyPreviewAuthorId,
  kind: m.isSystem ? StoredMessageKind.systemInfo : StoredMessageKind.normal,
  sendState: _sendState(m.sendState),
  attachments: m.attachments.map(_toAttachment).toList(),
  deliveries: m.deliveries
      .map(
        (d) => GroupDelivery(
          accountId: d.accountId,
          wireMessageId: '',
          state: _sendState(d.state),
        ),
      )
      .toList(),
);

/// The attachment as a bubble needs it: shape, type and whether it is still on
/// its way. No key and no blob id, because fetching goes through the core --
/// [CoreAccount.attachmentPath] -- and a widget holding a decryption key would
/// be carrying something it can do nothing with.
MessageAttachment _toAttachment(CoreAttachment a) => MessageAttachment(
  kind: a.kind,
  blobId: a.blobId,
  // Empty on purpose: the shell never opens a blob, so it has no use for a
  // key and every reason not to hold one.
  key: Uint8List(0),
  mimeType: a.mimeType,
  byteSize: a.byteSize,
  width: a.width,
  height: a.height,
);

MessageSendState _sendState(String raw) => switch (raw) {
  'pending' => MessageSendState.pending,
  'failed' => MessageSendState.failed,
  _ => MessageSendState.sent,
};
