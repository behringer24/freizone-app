// A session re-key signal -- the invisible control envelope that carries an
// automatic recovery from a ratchet desync (docs/PROTOCOL.md §6, freizone-
// server). Sent over the exact same encrypted pipeline as a chat message
// (AppSession._encryptAndSend / processIncomingMessage), never shown and never
// stored as a StoredMessage, exactly like a receipt (receipt_signal.dart).
//
// Its entire job is to *exist*: the sender has just discarded its local
// session, so the very act of sending anything re-runs X3DH and puts a fresh
// `prekey` block on the wire, which the recipient adopts as a re-key (§5).
// The payload it carries is therefore deliberately almost empty -- what
// matters is the envelope wrapped around it.
//
// Why a message has to be sent at all, rather than just waiting: a desync is
// asymmetric. What breaks is *receiving*, so the peer keeps sending into a
// session we can no longer read, and nothing they do will fix it. Only a fresh
// `prekey` block from this side re-points them at a working session -- and
// waiting for the user to happen to type something means a conversation stays
// broken for as long as they stay quiet.
//
// Own "v": 3, following receipt_signal.dart's reasoning -- MessageContent's
// "v": 1 stays chat text forever, receipts own 2. A build predating this
// version renders it as MessageContent.decode's "newer app feature"
// placeholder rather than nothing at all; unavoidable (an older build has no
// rule that would tell it to ignore an envelope it has never heard of) and
// self-limiting, since recovery already requires the peer to be running a
// build that accepts re-keys at all.
import 'dart:convert';
import 'dart:typed_data';

/// Why the sender re-keyed. Carried for the receiving side's transcript
/// marker and for diagnostics -- never used to decide anything security
/// relevant, so an unrecognized value is simply treated as [unspecified].
enum RekeyReason {
  /// Repeated undecryptable messages from this peer (the automatic path).
  decryptFailures('decrypt_failures'),

  /// The user asked for it explicitly ("Reset secure session").
  userRequested('user_requested'),

  /// A sender that didn't say, or said something this build doesn't know.
  unspecified('unspecified');

  const RekeyReason(this.wireName);

  /// Spelled out rather than derived from [name]: this is a wire value other
  /// clients parse (docs/PROTOCOL.md §6), so it must not follow Dart's
  /// camelCase or change if the enum is ever renamed.
  final String wireName;
}

class RekeySignal {
  const RekeySignal({this.reason = RekeyReason.unspecified});

  final RekeyReason reason;

  static const _version = 3;
  static const _kind = 'rekey';

  Uint8List encode() {
    final json = <String, dynamic>{
      'v': _version,
      'kind': _kind,
      'reason': reason.wireName,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// Returns null for anything that isn't a well-formed re-key envelope -- an
  /// ordinary chat message, a receipt, garbage, or a future shape -- so the
  /// caller falls through to its normal handling.
  static RekeySignal? tryDecode(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['v'] != _version || decoded['kind'] != _kind) return null;
      var reason = RekeyReason.unspecified;
      for (final r in RekeyReason.values) {
        if (r.wireName == decoded['reason']) reason = r;
      }
      return RekeySignal(reason: reason);
    } catch (_) {
      return null;
    }
  }
}
