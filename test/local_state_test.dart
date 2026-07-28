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

  group('AppState.processedMessageIds', () {
    test('defaults to empty and stays out of toJson while empty', () {
      final state = _minimalState();
      expect(state.processedMessageIds, isEmpty);
      expect(state.toJson().containsKey('processed_message_ids'), isFalse);
    });

    test('round-trips through toJson/fromJson', () {
      final state = _minimalState();
      state.markMessageProcessed('msg-1');
      state.markMessageProcessed('msg-2');

      final restored = AppState.fromJson(state.toJson());
      expect(restored.processedMessageIds, {'msg-1', 'msg-2'});
    });

    test('recording the same id twice keeps a single entry', () {
      final state = _minimalState();
      state.markMessageProcessed('msg-1');
      state.markMessageProcessed('msg-1');
      expect(state.processedMessageIds, hasLength(1));
    });

    test('evicts oldest entries past the cap, keeping the newest', () {
      final state = _minimalState();
      for (var i = 0; i < maxProcessedMessageIds + 10; i++) {
        state.markMessageProcessed('msg-$i');
      }

      expect(state.processedMessageIds, hasLength(maxProcessedMessageIds));
      // The 10 oldest are gone, the newest are retained -- redelivery happens
      // close in time, so recency is what matters.
      expect(state.processedMessageIds.contains('msg-0'), isFalse);
      expect(state.processedMessageIds.contains('msg-9'), isFalse);
      expect(state.processedMessageIds.contains('msg-10'), isTrue);
      expect(
        state.processedMessageIds.contains(
          'msg-${maxProcessedMessageIds + 9}',
        ),
        isTrue,
      );
    });
  });
}
