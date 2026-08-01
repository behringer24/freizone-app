// Automatic recovery from a ratchet desync (SRV-03): the evidence this device
// collects per peer, and the policy that decides when that evidence justifies
// throwing the local session away and re-keying via X3DH.
//
// Split out from the code that acts on it (AppSession._recoverDesyncedSessions)
// so the policy -- which is all thresholds and tie-breaks and therefore the
// part that can be wrong in subtle ways -- is a pure function over a clock and
// two account ids, testable without a live session, a server, or the core.
//
// Recovery is a *last* resort, not a routine correction: it discards any
// message still queued on the old chain, so the bar is "this session provably
// cannot decrypt any more", never "something looked odd once".
import '../ffi/models.dart';

/// How many distinct envelopes from one peer must be given up on before the
/// session is presumed desynced.
///
/// One is enough, and deliberately so. An envelope only reaches this point
/// after [maxDecryptAttempts] failures (see AppState.recordDecryptFailure) with
/// a failure code that means diverged keys, and decrypting the same ciphertext
/// against the same session is deterministic -- so this is already proof, not
/// suspicion. Waiting for a second envelope would strand any conversation where
/// the peer sent exactly one message and then reasonably waited for an answer.
const int minDesyncEvidence = 1;

/// How long the higher-id side waits before re-keying on its own initiative.
///
/// Both sides can detect the same desync, and if both re-key at once each
/// adopts a fresh responder session built from the other's `prekey` block while
/// discarding the initiator session the other just adopted -- leaving both
/// broken again, symmetrically, round after round. So the order is fixed by
/// comparing account ids (see [shouldAutoRekey]): the lower id re-keys
/// immediately, the higher id only if that hasn't already fixed things.
///
/// Five minutes because the lower-id side's re-key lands within seconds when it
/// is online at all, and any successful decrypt -- including adopting that very
/// re-key -- clears the evidence and cancels this side's attempt. Long enough
/// to make the overlap rare, short enough that a peer who is simply offline
/// doesn't leave this side stuck waiting.
const Duration autoRekeyResponderGrace = Duration(minutes: 5);

/// Minimum spacing between two automatic re-keys with the same peer.
///
/// The backstop for everything the ordering rule doesn't catch: if a re-key
/// somehow doesn't fix the conversation, this bounds the damage to one attempt
/// per interval instead of a tight loop of X3DH establishments (each of which
/// burns one of the peer's one-time prekeys).
const Duration minAutoRekeyInterval = Duration(minutes: 15);

/// What this device knows about one peer's session going wrong -- absent from
/// AppState.peerSessionHealth entirely while the session is healthy, so the
/// common case costs nothing in the profile.
///
/// Persisted rather than in-memory for the same reason the per-message failure
/// counts are: the background push isolate is torn down between wakes, and the
/// isolate that *notices* a desync (a wake, with no sending capability) is
/// usually not the one that can *act* on it (a live AppSession). Evidence
/// written by one is read by the other.
class PeerSessionHealth {
  PeerSessionHealth({
    this.desyncEvidence = 0,
    this.firstFailureAt,
    this.lastRekeyAt,
  });

  factory PeerSessionHealth.fromJson(Map<String, dynamic> j) =>
      PeerSessionHealth(
        desyncEvidence: j['desync_evidence'] as int? ?? 0,
        firstFailureAt: j['first_failure_at'] == null
            ? null
            : decodeTime(j['first_failure_at'] as String),
        lastRekeyAt: j['last_rekey_at'] == null
            ? null
            : decodeTime(j['last_rekey_at'] as String),
      );

  Map<String, dynamic> toJson() => {
    if (desyncEvidence != 0) 'desync_evidence': desyncEvidence,
    if (firstFailureAt != null) 'first_failure_at': encodeTime(firstFailureAt!),
    if (lastRekeyAt != null) 'last_rekey_at': encodeTime(lastRekeyAt!),
  };

  /// How many distinct envelopes from this peer have been given up on since the
  /// last successful decrypt, counting only failures whose code implies
  /// diverged keys (CoreErrorCode.suggestsDesync) -- a redelivery or an
  /// undiagnosed error is not evidence of anything.
  int desyncEvidence;

  /// When the first of those was given up on. Anchors
  /// [autoRekeyResponderGrace]; null exactly when [desyncEvidence] is 0.
  DateTime? firstFailureAt;

  /// When this device last re-keyed with this peer automatically. Outlives the
  /// evidence it was triggered by, since it exists to space *future* attempts
  /// ([minAutoRekeyInterval]) -- and is itself dropped along with the whole
  /// entry by AppState.clearDesyncEvidence once a message decrypts again.
  DateTime? lastRekeyAt;
}

/// Whether the evidence in [health] justifies discarding the local session with
/// [peerAccountId] and re-establishing it.
///
/// [myAccountId] is this account's own id, used only to break the tie over who
/// re-keys first (see [autoRekeyResponderGrace]) -- ids are globally unique
/// hashes of a root key, so the comparison is total and both sides compute the
/// same answer without exchanging anything.
///
/// Callers still apply their own eligibility rules on top (a blocked peer, an
/// unaccepted message request, or a conversation whose server has federation
/// switched off is never worth sending to); this function answers only the
/// crypto-state question.
bool shouldAutoRekey({
  required PeerSessionHealth? health,
  required String myAccountId,
  required String peerAccountId,
  required DateTime now,
}) {
  if (health == null) return false;
  if (health.desyncEvidence < minDesyncEvidence) return false;

  final since = health.lastRekeyAt;
  if (since != null && now.difference(since) < minAutoRekeyInterval) {
    return false;
  }

  // Higher id: hold back, and give the other side's re-key time to arrive.
  if (myAccountId.compareTo(peerAccountId) > 0) {
    final detected = health.firstFailureAt;
    if (detected == null) return false; // evidence without a timestamp: wait.
    if (now.difference(detected) < autoRekeyResponderGrace) return false;
  }
  return true;
}
