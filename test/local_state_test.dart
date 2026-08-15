import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/local_state.dart';

AppState _minimalState() => AppState(
  server: 'chat.example.org',
  accountId: 'abc123',
  rootPub: Uint8List(0),
  rootPriv: Uint8List(0),
  deviceId: 'device1',
  devicePub: Uint8List(0),
  devicePriv: Uint8List(0),
);

void main() {
  group('AppState.blockedPeers', () {
    test('defaults to empty', () {
      final state = _minimalState();
      expect(state.blockedPeers, isEmpty);
    });

    test('omitted from toJson when empty, so it stays compact', () {
      final json = _minimalState().toJson();
      expect(json.containsKey('blocked_peers'), isFalse);
    });

    // knownPeerIds was a second copy of a set the core owns, dropped
    // 2026-08-15. An old profile still carries the key and must load without
    // complaint -- it is simply not read any more.
    test('a profile from before the drop still loads, minus that key', () {
      final original = _minimalState();
      final json = original.toJson()..['known_peer_ids'] = ['peer1', 'peer2'];
      final restored = AppState.fromJson(json);
      expect(restored.accountId, original.accountId);
      expect(restored.toJson().containsKey('known_peer_ids'), isFalse);
    });

    test('blockedPeers round-trips through toJson/fromJson, keyed by id', () {
      final state = _minimalState();
      state.blockedPeers['peer1'] = BlockedPeer(
        peerAccountId: 'peer1',
        peerServer: 'chat.other.org',
      );
      final restored = AppState.fromJson(state.toJson());
      expect(restored.blockedPeers.keys, ['peer1']);
      expect(restored.blockedPeers['peer1']!.peerServer, 'chat.other.org');
      // No name snapshot any more (APP-19): the blocked list reads the contact
      // store, so a second copy here could only go stale on a rename.
      expect(state.blockedPeers['peer1']!.toJson().containsKey('display_name'), isFalse);
    });

    test('blockedPeers survives without a peerServer snapshot', () {
      final state = _minimalState();
      state.blockedPeers['peer1'] = BlockedPeer(peerAccountId: 'peer1');
      final restored = AppState.fromJson(state.toJson());
      expect(restored.blockedPeers['peer1']!.peerServer, isNull);
    });
  });

  // What used to be tested here besides these two -- ratchet sessions, the
  // prekey pool, processed-envelope ids, decrypt-failure counts, held group
  // facts, per-member state hashes -- is no longer AppState's to hold. The core
  // owns all of it and covers it with its own tests (freizone-server's
  // pkg/client), so a profile keeping a second copy could only disagree.
}
