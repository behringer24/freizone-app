// Everything needed to deliver an encrypted message to one account.
//
// Split out of Conversation for groups (APP-16). A group member is reachable
// in exactly the way a one-to-one peer is -- and the ratchet session is
// literally the same one, since AppState.sessions is keyed by peer account id
// and pairwise fan-out means a group message to Ben rides Ben's own session.
// What was missing was somewhere to keep the *address* half for a member this
// account has no one-to-one conversation with. Without this, a fan-out would
// have had to create a conversation per member and litter the chat list.
//
// Deliberately not persisted on its own: [deviceId] and [devicePubKey] are a
// cache of one cheap lookup, and a Conversation that has one stores it as part
// of itself.
import 'dart:typed_data';

class PeerEndpoint {
  PeerEndpoint({
    required this.accountId,
    this.server,
    this.deviceId,
    this.devicePubKey,
  });

  final String accountId;

  /// This peer's home server, normalized (see server_url.dart), if it differs
  /// from ours -- null means "the same server as us", the common case.
  String? server;

  /// The peer's active device, resolved on first use and cached. Null until
  /// then: an account that has only ever written to us was never looked up.
  String? deviceId;
  Uint8List? devicePubKey;

  bool get isFederated => server != null;
}
