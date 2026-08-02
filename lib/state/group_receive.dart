// The receiving half of groups (APP-16), as top-level functions rather than
// AppSession methods.
//
// That is not a style choice. processIncomingMessage advances the ratchet and
// marks an envelope processed before it looks at the payload, and both of those
// are irreversible -- so whoever decrypts a group envelope has to *handle* it
// too, or the facts inside are gone for good. The background push isolate
// decrypts (push_manager.dart) and has no AppSession, so this has to be
// reachable without one.
//
// Sending is the one thing that stays with AppSession: answering a sync
// request, or a state_hash mismatch, needs somewhere to send from.
import '../ffi/freizone_core.dart';
import '../ffi/models.dart';
import 'chat_target.dart';
import 'group_control.dart';
import 'group_conversation.dart';
import 'group_store.dart';
import 'local_state.dart';
import 'message_content.dart';

/// How many not-yet-admissible events one group may hold.
///
/// Holding is for envelopes that overtook the ones they depend on, which is a
/// handful in practice. An unbounded buffer would just be somewhere for a
/// hostile peer to put things.
const int maxHeldGroupEvents = 64;

/// What handling a group control envelope changed, for a caller that can act
/// on it.
class GroupControlOutcome {
  const GroupControlOutcome({
    required this.groupId,
    required this.peerStateHash,
    this.wantsSnapshot = false,
  });

  final String groupId;

  /// The sender's own view, so a mismatch is visible without asking.
  final String peerStateHash;

  /// They asked for our fact set outright.
  final bool wantsSnapshot;
}

/// Applies a group control envelope to this account's stored fact set.
///
/// Never stores anything in a transcript and never notifies: membership is not
/// a message. The envelope is still acknowledged and deleted from the queue
/// like any other processed one.
Future<GroupControlOutcome> applyGroupControl(
  AppState state,
  FreizoneCore core,
  GroupControl control,
) async {
  if (control.kind == GroupControlKind.syncRequest) {
    return GroupControlOutcome(
      groupId: control.groupId,
      peerStateHash: control.stateHash,
      wantsSnapshot: true,
    );
  }

  final stored = await GroupStateStore.load(state.accountId, control.groupId);
  final held = state.pendingGroupEvents.remove(control.groupId) ?? const [];

  // Retried together with the new facts: delivery is unordered, so a
  // membership event easily arrives before the snapshot carrying the genesis
  // it depends on.
  final batch = [...held, ...control.events];
  final result = core.groupApplyEvents(
    state: stored ?? const <String, dynamic>{},
    events: batch,
  );

  // The blob decides its own id -- a snapshot carries the genesis, and the id
  // follows from the key in it rather than from whatever the sender claimed.
  final groupId = result.groupId.isEmpty ? control.groupId : result.groupId;
  if (result.groupId.isNotEmpty) {
    await GroupStateStore.save(state.accountId, groupId, result.state);
    // Being told about a group is how an invitation arrives, so the transcript
    // is created here rather than waiting for a message to land in it.
    state.groups.putIfAbsent(groupId, () => GroupConversation(groupId: groupId));
  }

  _holdPremature(state, groupId, batch, result);

  return GroupControlOutcome(
    groupId: groupId,
    peerStateHash: control.stateHash,
  );
}

/// Keeps the events that could not be admitted *yet*, so a later arrival can
/// unblock them.
///
/// An event rejected for a reason no later fact can change -- a bad signature,
/// another group's id -- is dropped rather than held: retrying it forever
/// would be pointless, and is exactly what a hostile peer would want.
void _holdPremature(
  AppState state,
  String groupId,
  List<Map<String, dynamic>> batch,
  GroupStateResult result,
) {
  final keep = <Map<String, dynamic>>[];
  for (final rejection in result.rejected) {
    if (!rejection.isPremature) continue;
    if (keep.length >= maxHeldGroupEvents) break;
    if (rejection.index >= 0 && rejection.index < batch.length) {
      keep.add(batch[rejection.index]);
    }
  }
  if (keep.isEmpty) {
    state.pendingGroupEvents.remove(groupId);
  } else {
    state.pendingGroupEvents[groupId] = keep;
  }
}

/// Files a decrypted group message into its transcript.
///
/// The group may be one this device has not heard of yet: delivery is
/// unordered, so a message can overtake the snapshot that introduces its
/// group. The transcript is created anyway rather than dropping the message --
/// the ratchet has already advanced past this envelope, so there is no second
/// chance at it -- and it simply shows an unnamed group until the facts catch
/// up.
StoredMessage storeGroupMessage(
  AppState state,
  MessageContent content,
  String senderAccountId,
  DateTime receivedAt, {
  String? openChatId,
}) {
  final groupId = content.groupId!;
  final chat = state.groups.putIfAbsent(
    groupId,
    () => GroupConversation(groupId: groupId),
  );

  final message = StoredMessage(
    id: content.id,
    text: content.text,
    mine: false,
    timestamp: receivedAt,
    senderSentAt: content.sentAt,
    // What a one-to-one transcript never needs: in a group the conversation
    // does not answer who wrote this, so the bubble has to.
    senderAccountId: senderAccountId,
    replyToId: content.replyToId,
    replyPreviewText: content.replyPreview?.text,
    replyPreviewMine: content.replyPreview?.mine,
    attachments: content.attachments,
  );

  chat.messages.add(message);
  chat.lastActivityAt = receivedAt;
  if (openChatId != groupId) chat.hasUnread = true;
  return message;
}
