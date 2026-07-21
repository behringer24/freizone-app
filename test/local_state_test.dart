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
  group('AppState.knownPeerIds / blockedPeers', () {
    test('default to empty', () {
      final state = _minimalState();
      expect(state.knownPeerIds, isEmpty);
      expect(state.blockedPeers, isEmpty);
    });

    test('omitted from toJson when empty, so they stay compact', () {
      final json = _minimalState().toJson();
      expect(json.containsKey('known_peer_ids'), isFalse);
      expect(json.containsKey('blocked_peers'), isFalse);
    });

    test('knownPeerIds round-trips through toJson/fromJson', () {
      final state = _minimalState();
      state.knownPeerIds.add('peer1');
      state.knownPeerIds.add('peer2');
      final restored = AppState.fromJson(state.toJson());
      expect(restored.knownPeerIds, {'peer1', 'peer2'});
    });

    test('blockedPeers round-trips through toJson/fromJson, keyed by id', () {
      final state = _minimalState();
      state.blockedPeers['peer1'] = BlockedPeer(
        peerAccountId: 'peer1',
        peerServer: 'chat.other.org',
        displayName: 'Spammer',
      );
      final restored = AppState.fromJson(state.toJson());
      expect(restored.blockedPeers.keys, ['peer1']);
      expect(restored.blockedPeers['peer1']!.peerServer, 'chat.other.org');
      expect(restored.blockedPeers['peer1']!.displayName, 'Spammer');
    });

    test(
      'blockedPeers survives without peerServer/displayName snapshots',
      () {
        final state = _minimalState();
        state.blockedPeers['peer1'] = BlockedPeer(peerAccountId: 'peer1');
        final restored = AppState.fromJson(state.toJson());
        expect(restored.blockedPeers['peer1']!.peerServer, isNull);
        expect(restored.blockedPeers['peer1']!.displayName, isNull);
      },
    );
  });
}
