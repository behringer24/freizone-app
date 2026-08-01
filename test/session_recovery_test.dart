import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/conversation.dart';
import 'package:freizone/state/local_state.dart';
import 'package:freizone/state/session_recovery.dart';

// Two ids whose ordering is obvious at a glance, so the tie-break tests read
// as intent rather than as string trivia.
const _lowId = 'aaa111';
const _highId = 'zzz999';

/// A state with a conversation for each of [peers] -- evidence is only kept for
/// peers there is one for (see AppState.recordDesyncEvidence).
AppState _minimalState({
  String accountId = _lowId,
  List<String> peers = const [_highId],
}) {
  final state = AppState(
    server: 'chat.example.org',
    accountId: accountId,
    rootPub: Uint8List(0),
    rootPriv: Uint8List(0),
    deviceId: 'device1',
    devicePub: Uint8List(0),
    devicePriv: Uint8List(0),
  );
  for (final peer in peers) {
    state.conversations[peer] = Conversation(peerAccountId: peer);
  }
  return state;
}

final _now = DateTime.utc(2026, 8, 1, 12, 0, 0);

void main() {
  group('AppState desync evidence', () {
    test('healthy peers cost nothing in the profile', () {
      final state = _minimalState();
      expect(state.peerSessionHealth, isEmpty);
      expect(state.toJson().containsKey('peer_session_health'), isFalse);
    });

    test('round-trips through toJson/fromJson', () {
      final state = _minimalState();
      state.recordDesyncEvidence(_highId, _now);
      state.recordDesyncEvidence(_highId, _now.add(const Duration(minutes: 1)));

      final restored = AppState.fromJson(state.toJson());
      final health = restored.peerSessionHealth[_highId]!;
      expect(health.desyncEvidence, 2);
      expect(health.firstFailureAt, _now, reason: 'anchored on the FIRST failure');
    });

    test('a successful decrypt forgets everything, including the spacing', () {
      final state = _minimalState();
      state.recordDesyncEvidence(_highId, _now);
      state.recordAutoRekey(_highId, _now);
      state.clearDesyncEvidence(_highId);
      expect(state.peerSessionHealth, isEmpty);
    });

    test('an auto re-key spends the evidence but keeps the timestamp', () {
      final state = _minimalState();
      state.recordDesyncEvidence(_highId, _now);
      state.recordAutoRekey(_highId, _now.add(const Duration(seconds: 5)));

      final health = state.peerSessionHealth[_highId]!;
      expect(health.desyncEvidence, 0);
      expect(health.firstFailureAt, isNull);
      expect(health.lastRekeyAt, _now.add(const Duration(seconds: 5)));
    });

    test('evidence is tracked per peer, not globally', () {
      final state = _minimalState(peers: const ['peer1', 'peer2']);
      state.recordDesyncEvidence('peer1', _now);
      state.clearDesyncEvidence('peer2');
      expect(state.peerSessionHealth.keys, ['peer1']);
    });

    // Otherwise a stranger sending undecryptable envelopes under invented
    // sender ids could grow the profile without limit -- and there would be
    // nowhere to send a recovery to anyway.
    test('a peer with no conversation is not tracked at all', () {
      final state = _minimalState(peers: const []);
      state.recordDesyncEvidence(_highId, _now);
      expect(state.peerSessionHealth, isEmpty);
    });
  });

  group('shouldAutoRekey', () {
    bool decide(
      PeerSessionHealth? health, {
      String me = _lowId,
      String peer = _highId,
      Duration elapsed = Duration.zero,
    }) => shouldAutoRekey(
      health: health,
      myAccountId: me,
      peerAccountId: peer,
      now: _now.add(elapsed),
    );

    test('a healthy peer is never re-keyed', () {
      expect(decide(null), isFalse);
      expect(decide(PeerSessionHealth()), isFalse);
    });

    test('one exhausted envelope is enough for the lower-id side', () {
      final health = PeerSessionHealth(desyncEvidence: 1, firstFailureAt: _now);
      expect(decide(health), isTrue);
    });

    // The ordering rule is the whole defence against both sides re-keying at
    // once and leaving each other broken again, round after round.
    test('the higher-id side waits out the grace period first', () {
      final health = PeerSessionHealth(desyncEvidence: 1, firstFailureAt: _now);
      expect(
        decide(health, me: _highId, peer: _lowId),
        isFalse,
        reason: 'should hold back and let the lower id go first',
      );
      expect(
        decide(
          health,
          me: _highId,
          peer: _lowId,
          elapsed: autoRekeyResponderGrace + const Duration(seconds: 1),
        ),
        isTrue,
        reason: 'a peer that never fixed it must not leave this side stuck',
      );
    });

    test('a recent re-key blocks another one, whichever side we are', () {
      final health = PeerSessionHealth(
        desyncEvidence: 1,
        firstFailureAt: _now,
        lastRekeyAt: _now,
      );
      expect(decide(health), isFalse);
      expect(
        decide(health, elapsed: minAutoRekeyInterval + const Duration(seconds: 1)),
        isTrue,
      );
    });

    test('evidence without a timestamp never triggers the delayed side', () {
      // Only reachable from a hand-edited or truncated profile, but the grace
      // period has nothing to measure from, so the safe answer is "wait".
      final health = PeerSessionHealth(desyncEvidence: 5);
      expect(decide(health, me: _highId, peer: _lowId), isFalse);
    });
  });
}
