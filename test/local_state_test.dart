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

  group('AppState.pendingGroupEvents', () {
    test('omitted when empty, so existing profiles are unchanged', () {
      expect(
        _minimalState().toJson().containsKey('pending_group_events'),
        isFalse,
      );
    });

    test('held facts survive a restart', () {
      // They have to. Delivery is unordered, so an events envelope routinely
      // overtakes the snapshot carrying the genesis it needs -- and the
      // ratchet has already advanced past the envelope they arrived in, so
      // dropping them on close would be final.
      final state = _minimalState();
      state.pendingGroupEvents['p2xjx0000000000000000'] = [
        {'type': 'member_add', 'subject': 'qben000000000000000b'},
      ];

      final restored = AppState.fromJson(state.toJson());
      final held = restored.pendingGroupEvents['p2xjx0000000000000000']!;
      expect(held, hasLength(1));
      expect(held.single['type'], 'member_add');
    });
  });

  group('AppState.groupSnapshotDebts', () {
    test('omitted when empty, so existing profiles are unchanged', () {
      expect(
        _minimalState().toJson().containsKey('group_snapshot_debts'),
        isFalse,
      );
    });

    test('what a member was never told survives a restart', () {
      // The point of persisting it: the failure that creates a debt is usually
      // the app losing its network, and being closed in that state is exactly
      // when it must not be forgotten -- nothing in the protocol tells a member
      // what they never received.
      final state = _minimalState();
      state.groupSnapshotDebts['p2xjx0000000000000000'] = {
        'qben000000000000000b',
        'qcaro00000000000000c',
      };

      final restored = AppState.fromJson(state.toJson());
      expect(restored.groupSnapshotDebts['p2xjx0000000000000000'], {
        'qben000000000000000b',
        'qcaro00000000000000c',
      });
    });
  });

  group('AppState.groupPeerStateHashes', () {
    test('omitted when empty, so existing profiles are unchanged', () {
      expect(
        _minimalState().toJson().containsKey('group_peer_state_hashes'),
        isFalse,
      );
    });

    test('what each member was last known to be on survives a restart', () {
      // Without persisting it, every first message in every group after a
      // restart would carry a whole snapshot again -- the fan-out only knows a
      // member is level with us because we remember their last hash.
      final state = _minimalState();
      state.groupPeerStateHashes['p2xjx0000000000000000'] = {
        'qben000000000000000b': 'abc123',
      };

      final restored = AppState.fromJson(state.toJson());
      expect(
        restored.groupPeerStateHashes['p2xjx0000000000000000'],
        {'qben000000000000000b': 'abc123'},
      );
    });
  });

  group('AppState.inboundSessions', () {
    test('omitted when empty, so existing profiles are unchanged', () {
      expect(_minimalState().toJson().containsKey('inbound_sessions'), isFalse);
    });

    test('survives a round trip, separately from the sending session', () {
      // The losing half of a simultaneous establishment. It has to persist:
      // the peer keeps sending on it until our next message reaches them, and
      // those follow-ups carry no X3DH initial, so nothing else could read
      // them after a restart.
      final state = _minimalState();
      state.sessions['peer1'] = {'which': 'ours, for sending'};
      state.inboundSessions['peer1'] = {'which': 'theirs, for reading'};

      final restored = AppState.fromJson(state.toJson());
      expect(restored.sessions['peer1'], {'which': 'ours, for sending'});
      expect(restored.inboundSessions['peer1'], {
        'which': 'theirs, for reading',
      });
    });
  });
}
