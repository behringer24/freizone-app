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
import 'group_system_lines.dart';
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
    this.invited = false,
  });

  final String groupId;

  /// The sender's own view, so a mismatch is visible without asking.
  final String peerStateHash;

  /// They asked for our fact set outright.
  final bool wantsSnapshot;

  /// This envelope was an invitation *to us*, into a group this account had no
  /// facts about until now -- the one membership change that is worth waking
  /// the user for (see [applyGroupControl]).
  final bool invited;
}

/// Applies a group control envelope to this account's stored fact set.
///
/// Never stores anything in a transcript: membership is not a message. The
/// envelope is still acknowledged and deleted from the queue like any other
/// processed one.
///
/// The one thing it does report as notify-worthy is an invitation addressed to
/// this account (see [GroupControlOutcome.invited]) -- being asked into a group
/// is a decision waiting on the user, not group bookkeeping, and it is the
/// invitee's only sign that anything happened at all: nothing is ever sent to a
/// member who hasn't accepted, so without this a new group would just appear
/// silently in the chat list.
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
  // Whether this account had *any* facts about this group before now. The same
  // snapshot legitimately arrives from several members, so "the group is new to
  // us" is what tells a first invitation apart from a re-delivery of it.
  final isNewToUs = stored == null;
  final held = state.pendingGroupEvents.remove(control.groupId) ?? const [];

  // Retried together with the new facts: delivery is unordered, so a
  // membership event easily arrives before the snapshot carrying the genesis
  // it depends on.
  final batch = [...held, ...control.events];
  // Folded before applying, so the transcript can say what changed (see
  // group_system_lines.dart). One extra fold of a blob we already have, only on
  // a control envelope -- membership changes are rare next to messages, and
  // "who is in this group" changing silently is exactly what needs saying.
  final before = stored == null ? null : core.groupResolveState(stored).resolved;
  final result = core.groupApplyEvents(
    state: stored ?? const <String, dynamic>{},
    events: batch,
  );

  // The blob decides its own id -- a snapshot carries the genesis, and the id
  // follows from the key in it rather than from whatever the sender claimed.
  final groupId = result.groupId.isEmpty ? control.groupId : result.groupId;
  var invited = false;
  if (result.groupId.isNotEmpty) {
    await GroupStateStore.save(state.accountId, groupId, result.state);
    // Being told about a group is how an invitation arrives, so the transcript
    // is created here rather than waiting for a message to land in it.
    final chat = state.groups.putIfAbsent(
      groupId,
      () => GroupConversation(groupId: groupId),
    );
    // An outstanding invitation for us: a membership we did not have before and
    // have not accepted, so nothing will ever be sent into this group until the
    // user answers. Marked unread as well as notified -- the chat list is where
    // they will come looking for it.
    //
    // "Did not have before" rather than "the group is new to us", because being
    // re-invited after a removal is an invitation too: the fact set stays on this
    // device when a moderator removes us, so the group is *not* new the second
    // time round and that first version of this check said nothing at all.
    final meBefore = before?.memberById(state.accountId);
    final me = result.resolved.memberById(state.accountId);
    if (me != null && !me.joined && (isNewToUs || meBefore == null)) {
      invited = true;
      chat.hasUnread = true;
    }

    // Deliberately not marked unread: a membership change is worth recording
    // where it happened, not worth a badge -- the invitation above is the one
    // exception, and it has its own reason.
    appendGroupSystemLines(
      chat,
      groupStateChangeLines(
        before: before,
        after: result.resolved,
        myAccountId: state.accountId,
        events: batch,
      ),
      at: DateTime.now().toUtc(),
    );
  }

  _holdPremature(state, groupId, batch, result);

  return GroupControlOutcome(
    groupId: groupId,
    peerStateHash: control.stateHash,
    invited: invited,
  );
}

/// Appends [lines] to [chat]'s transcript as centered system lines, one second
/// apart from [at].
///
/// A transcript renders in insertion order, so the offsets are not what keeps
/// these in sequence -- they keep the *timestamps* from being identical, since
/// several changes can land in one batch ("invited" before "joined" is not the
/// same story as the other way round) and identical stamps would make the day
/// dividers and any future ordering by time arbitrary.
///
/// Shared by both apply paths -- our own actions (AppSession.applyGroupEvents)
/// and a peer's (applyGroupControl) -- so a change reads identically whoever
/// made it.
void appendGroupSystemLines(
  GroupConversation chat,
  List<String> lines, {
  required DateTime at,
}) {
  for (var i = 0; i < lines.length; i++) {
    chat.messages.add(
      StoredMessage.system(lines[i], at.add(Duration(seconds: i))),
    );
  }
  if (lines.isNotEmpty) chat.lastActivityAt = at;
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
