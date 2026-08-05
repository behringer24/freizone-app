// A one-to-one conversation: the UI-facing layer on top of the crypto layer
// (AppState.sessions, a ratchet.Session's own JSON form). Kept deliberately
// separate: this is what the chat list and chat screen render, the ratchet
// session is what the Go core consumes.
//
// Everything here is about *a peer*. What a transcript needs regardless of who
// is on the other end -- the messages, unread state, pins, the title -- lives
// in ChatTarget (chat_target.dart), which a group will share once APP-16
// lands. That file is re-exported below, so importing this one still brings
// StoredMessage and friends along.
import 'dart:typed_data';

import '../ffi/models.dart';
import '../util/freizone_address.dart';
import 'chat_target.dart';
import 'contact_store.dart';
import 'peer_endpoint.dart';

export 'chat_target.dart';

/// One peer conversation: who they are (resolved once, cached), and the
/// locally persisted message history with them.
class Conversation extends ChatTarget {
  Conversation({
    required String peerAccountId,
    String? peerServer,
    String? peerDeviceId,
    Uint8List? peerDevicePubKey,
    super.messages,
    super.lastActivityAt,
    super.hasUnread,
    super.pinnedMessageIds,
    this.blocked = false,
    this.pendingApproval = false,
    this.peerDeliveredUpTo,
    this.peerReadUpTo,
    this.sentDeliveredReceiptUpTo,
    this.sentReadReceiptUpTo,
  }) : peer = PeerEndpoint(
         accountId: peerAccountId,
         server: peerServer,
         deviceId: peerDeviceId,
         devicePubKey: peerDevicePubKey,
       );

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    peerAccountId: j['peer_account_id'] as String,
    peerServer: j['peer_server'] as String?,
    peerDeviceId: j['peer_device_id'] as String?,
    peerDevicePubKey: j['peer_device_pub_key'] == null
        ? null
        : decodeB64(j['peer_device_pub_key'] as String),
    messages: (j['messages'] as List<dynamic>?)
        ?.map((m) => StoredMessage.fromJson(m as Map<String, dynamic>))
        .toList(),
    lastActivityAt: decodeTime(j['last_activity_at'] as String),
    hasUnread: j['has_unread'] as bool? ?? false,
    pinnedMessageIds: (j['pinned_message_ids'] as List<dynamic>?)
        ?.cast<String>()
        .toList(),
    blocked: j['blocked'] as bool? ?? false,
    pendingApproval: j['pending_approval'] as bool? ?? false,
    peerDeliveredUpTo: j['peer_delivered_up_to'] == null
        ? null
        : decodeTime(j['peer_delivered_up_to'] as String),
    peerReadUpTo: j['peer_read_up_to'] == null
        ? null
        : decodeTime(j['peer_read_up_to'] as String),
    sentDeliveredReceiptUpTo: j['sent_delivered_receipt_up_to'] == null
        ? null
        : decodeTime(j['sent_delivered_receipt_up_to'] as String),
    sentReadReceiptUpTo: j['sent_read_receipt_up_to'] == null
        ? null
        : decodeTime(j['sent_read_receipt_up_to'] as String),
  );

  /// How to reach this peer -- the same object a group fan-out uses for a
  /// member (see peer_endpoint.dart). Held rather than inlined so both kinds
  /// of chat share one delivery path, and one device resolution.
  final PeerEndpoint peer;

  String get peerAccountId => peer.accountId;

  /// The peer's account id doubles as this chat's local key -- there is
  /// exactly one conversation per peer.
  @override
  String get id => peer.accountId;

  /// This peer's home server, normalized (see server_url.dart), if it's
  /// on a DIFFERENT server than this session's own -- null means "same
  /// server," the common case. Set explicitly when starting a federated
  /// conversation, and kept fresh on every incoming message that carries
  /// one (see AppSession._handleIncoming and message_content.dart's
  /// senderServer) so it self-heals if local state is ever lost.
  String? get peerServer => peer.server;
  set peerServer(String? value) => peer.server = value;

  String? get peerDeviceId => peer.deviceId;
  set peerDeviceId(String? value) => peer.deviceId = value;

  Uint8List? get peerDevicePubKey => peer.devicePubKey;
  set peerDevicePubKey(Uint8List? value) => peer.devicePubKey = value;

  /// True once this peer is blocked -- purely local (see
  /// AppSession.setBlocked): further incoming messages are decrypted
  /// (so the ratchet session and server-side queue both stay clean) but
  /// dropped before being stored or notified, and the chat screen
  /// disables sending. The peer is never told either way.
  bool blocked;

  /// True while this conversation is an unactioned "message request" --
  /// set only when [AppSession._handleIncoming] creates it for a peer
  /// that never existed before (an incoming first contact), never for one
  /// created by [AppSession.startConversation] (you reaching out doesn't
  /// need your own approval). Cleared by [AppSession.acceptConversation]
  /// or by blocking. Purely a display/composer-gating concern -- messages
  /// still arrive and get stored normally while pending, see
  /// _handleIncoming.
  bool pendingApproval;

  /// How far the PEER has confirmed receiving/reading MY messages -- one
  /// marker per conversation, not one per message (see receipt_signal
  /// .dart): a message of mine with `timestamp <= peerReadUpTo` is
  /// rendered as read, `<= peerDeliveredUpTo` as delivered. Monotonic --
  /// only ever moves forward, see AppSession.processIncomingMessage.
  /// Never set if [AppSettings.readReceiptsEnabled] is off, which is what
  /// makes disabling receipts reciprocal (nothing to render either way).
  ///
  /// A group needs one of these *per member* rather than one per chat,
  /// which is why they live here and not in ChatTarget.
  DateTime? peerDeliveredUpTo;
  DateTime? peerReadUpTo;

  /// How far I've already told the peer I've received/read THEIR
  /// messages -- purely local bookkeeping so AppSession doesn't re-send
  /// an identical receipt every time it re-checks (e.g. on every incoming
  /// message in a burst, or every time the conversation is reopened).
  DateTime? sentDeliveredReceiptUpTo;
  DateTime? sentReadReceiptUpTo;

  /// The contact's name if this device has named them, otherwise the peer's
  /// compact "shortid*domain" address -- which server they're actually on is
  /// worth always keeping visible (especially once federation means
  /// that isn't always this session's own server), more so than the
  /// full checksummed id. [localServer] fills in for [peerServer] ==
  /// null (this peer is on the same server as us).
  ///
  /// The name comes from [contacts] rather than from a field here (APP-19): it
  /// belongs to the person, not to this chat with them, and one of my accounts
  /// naming somebody names them for all of them. Falling back to the address is
  /// the same behaviour a never-named peer has always had, which is what makes
  /// "remove a contact" cost nothing but the label.
  @override
  String titleFor(String localServer, ContactStore contacts) =>
      contacts.nameFor(peerAccountId) ??
      shortFreizoneAddress(id: peerAccountId, server: peerServer ?? localServer);

  Map<String, dynamic> toJson() {
    final j = <String, dynamic>{'peer_account_id': peerAccountId};
    writeBaseJson(j);
    if (peerServer != null) j['peer_server'] = peerServer;
    if (peerDeviceId != null) j['peer_device_id'] = peerDeviceId;
    if (peerDevicePubKey != null) {
      j['peer_device_pub_key'] = encodeB64(peerDevicePubKey!);
    }
    if (blocked) j['blocked'] = blocked;
    if (pendingApproval) j['pending_approval'] = pendingApproval;
    if (peerDeliveredUpTo != null) {
      j['peer_delivered_up_to'] = encodeTime(peerDeliveredUpTo!);
    }
    if (peerReadUpTo != null) j['peer_read_up_to'] = encodeTime(peerReadUpTo!);
    if (sentDeliveredReceiptUpTo != null) {
      j['sent_delivered_receipt_up_to'] = encodeTime(sentDeliveredReceiptUpTo!);
    }
    if (sentReadReceiptUpTo != null) {
      j['sent_read_receipt_up_to'] = encodeTime(sentReadReceiptUpTo!);
    }
    return j;
  }
}
