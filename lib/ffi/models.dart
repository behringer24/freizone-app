// Typed Dart models matching the JSON shapes crossing the FFI boundary
// (native/logic.go's request/response types, and the underlying
// freizone-server pkg/{devicecert,ratchet} types they wrap -- see that
// repo's docs/PROTOCOL.md for the canonical field-name reference). Two
// distinct "opaque blob" types (RatchetSession, and the certificate types)
// are kept as raw Map<String, dynamic> where nothing outside the core
// needs to inspect their fields -- only construct, persist, and pass back.
import 'dart:convert';
import 'dart:typed_data';

Uint8List decodeB64(String s) => base64.decode(s);
String encodeB64(Uint8List b) => base64.encode(b);

String encodeTime(DateTime t) => t.toUtc().toIso8601String();
DateTime decodeTime(String s) => DateTime.parse(s).toUtc();

/// A freshly generated account identity: root key, device key, derived
/// account id.
class Identity {
  Identity({
    required this.accountId,
    required this.rootPub,
    required this.rootPriv,
    required this.deviceId,
    required this.devicePub,
    required this.devicePriv,
  });

  factory Identity.fromJson(Map<String, dynamic> j) => Identity(
    accountId: j['account_id'] as String,
    rootPub: decodeB64(j['root_pub'] as String),
    rootPriv: decodeB64(j['root_priv'] as String),
    deviceId: j['device_id'] as String,
    devicePub: decodeB64(j['device_pub'] as String),
    devicePriv: decodeB64(j['device_priv'] as String),
  );

  final String accountId;
  final Uint8List rootPub;
  final Uint8List rootPriv;
  final String deviceId;
  final Uint8List devicePub;
  final Uint8List devicePriv;
}

/// A device certificate, signed by an account's root key
/// (pkg/devicecert.DeviceCertificate).
class DeviceCertificate {
  DeviceCertificate({
    required this.accountId,
    required this.deviceId,
    required this.devicePubKey,
    required this.issuedAt,
    required this.signature,
  });

  factory DeviceCertificate.fromJson(Map<String, dynamic> j) =>
      DeviceCertificate(
        accountId: j['account_id'] as String,
        deviceId: j['device_id'] as String,
        devicePubKey: decodeB64(j['device_pub_key'] as String),
        issuedAt: decodeTime(j['issued_at'] as String),
        signature: decodeB64(j['signature'] as String),
      );

  Map<String, dynamic> toJson() => {
    'account_id': accountId,
    'device_id': deviceId,
    'device_pub_key': encodeB64(devicePubKey),
    'issued_at': encodeTime(issuedAt),
    'signature': encodeB64(signature),
  };

  final String accountId;
  final String deviceId;
  final Uint8List devicePubKey;
  final DateTime issuedAt;
  final Uint8List signature;
}

/// A device's X3DH DH identity certificate, signed by the device's own
/// Ed25519 key (pkg/devicecert.DHIdentityCertificate).
class DHIdentityCertificate {
  DHIdentityCertificate({
    required this.accountId,
    required this.deviceId,
    required this.dhPubKey,
    required this.issuedAt,
    required this.signature,
  });

  factory DHIdentityCertificate.fromJson(Map<String, dynamic> j) =>
      DHIdentityCertificate(
        accountId: j['account_id'] as String,
        deviceId: j['device_id'] as String,
        dhPubKey: decodeB64(j['dh_pub_key'] as String),
        issuedAt: decodeTime(j['issued_at'] as String),
        signature: decodeB64(j['signature'] as String),
      );

  Map<String, dynamic> toJson() => {
    'account_id': accountId,
    'device_id': deviceId,
    'dh_pub_key': encodeB64(dhPubKey),
    'issued_at': encodeTime(issuedAt),
    'signature': encodeB64(signature),
  };

  final String accountId;
  final String deviceId;
  final Uint8List dhPubKey;
  final DateTime issuedAt;
  final Uint8List signature;
}

/// A device's rotatable signed prekey certificate, bound to a specific DH
/// identity key (pkg/devicecert.SignedPrekeyCertificate).
class SignedPrekeyCertificate {
  SignedPrekeyCertificate({
    required this.accountId,
    required this.deviceId,
    required this.keyId,
    required this.dhIdentityPubKey,
    required this.prekeyPubKey,
    required this.issuedAt,
    required this.signature,
  });

  factory SignedPrekeyCertificate.fromJson(Map<String, dynamic> j) =>
      SignedPrekeyCertificate(
        accountId: j['account_id'] as String,
        deviceId: j['device_id'] as String,
        keyId: j['key_id'] as int,
        dhIdentityPubKey: decodeB64(j['dh_identity_pub_key'] as String),
        prekeyPubKey: decodeB64(j['prekey_pub_key'] as String),
        issuedAt: decodeTime(j['issued_at'] as String),
        signature: decodeB64(j['signature'] as String),
      );

  Map<String, dynamic> toJson() => {
    'account_id': accountId,
    'device_id': deviceId,
    'key_id': keyId,
    'dh_identity_pub_key': encodeB64(dhIdentityPubKey),
    'prekey_pub_key': encodeB64(prekeyPubKey),
    'issued_at': encodeTime(issuedAt),
    'signature': encodeB64(signature),
  };

  final String accountId;
  final String deviceId;
  final int keyId;
  final Uint8List dhIdentityPubKey;
  final Uint8List prekeyPubKey;
  final DateTime issuedAt;
  final Uint8List signature;
}

/// An X25519 keypair (pub, priv), used for DH identity keys, signed
/// prekeys, and one-time prekeys alike.
class X25519KeyPair {
  X25519KeyPair({required this.pub, required this.priv});

  factory X25519KeyPair.fromJson(Map<String, dynamic> j) => X25519KeyPair(
    pub: decodeB64(j['pub'] as String),
    priv: decodeB64(j['priv'] as String),
  );

  final Uint8List pub;
  final Uint8List priv;
}

/// A claimed peer prekey bundle, ready to pass to
/// FreizoneCore.initiateSession.
class RemoteBundle {
  RemoteBundle({
    required this.dhIdentityPub,
    required this.signedPrekeyId,
    required this.signedPrekeyPub,
    this.oneTimePrekeyId,
    this.oneTimePrekeyPub,
  });

  Map<String, dynamic> toJson() => {
    'dh_identity_pub': encodeB64(dhIdentityPub),
    'signed_prekey_id': signedPrekeyId,
    'signed_prekey_pub': encodeB64(signedPrekeyPub),
    if (oneTimePrekeyId != null) 'one_time_prekey_id': oneTimePrekeyId,
    if (oneTimePrekeyPub != null)
      'one_time_prekey_pub': encodeB64(oneTimePrekeyPub!),
  };

  final Uint8List dhIdentityPub;
  final int signedPrekeyId;
  final Uint8List signedPrekeyPub;
  final int? oneTimePrekeyId;
  final Uint8List? oneTimePrekeyPub;
}

/// The X3DH material an initiator sends alongside its first message
/// (pkg/ratchet.InitialMessage) -- present only on a session's first
/// message.
class InitialMessage {
  InitialMessage({
    required this.senderDhIdentityPub,
    required this.senderEphemeralPub,
    required this.signedPrekeyId,
    this.oneTimePrekeyId,
  });

  factory InitialMessage.fromJson(Map<String, dynamic> j) => InitialMessage(
    senderDhIdentityPub: decodeB64(j['sender_dh_identity_pub'] as String),
    senderEphemeralPub: decodeB64(j['sender_ephemeral_pub'] as String),
    signedPrekeyId: j['signed_prekey_id'] as int,
    oneTimePrekeyId: j['one_time_prekey_id'] as int?,
  );

  Map<String, dynamic> toJson() => {
    'sender_dh_identity_pub': encodeB64(senderDhIdentityPub),
    'sender_ephemeral_pub': encodeB64(senderEphemeralPub),
    'signed_prekey_id': signedPrekeyId,
    if (oneTimePrekeyId != null) 'one_time_prekey_id': oneTimePrekeyId,
  };

  final Uint8List senderDhIdentityPub;
  final Uint8List senderEphemeralPub;
  final int signedPrekeyId;
  final int? oneTimePrekeyId;
}

/// A Double Ratchet message header (pkg/ratchet.Header).
class RatchetHeader {
  RatchetHeader({required this.dhPub, required this.pn, required this.n});

  factory RatchetHeader.fromJson(Map<String, dynamic> j) => RatchetHeader(
    dhPub: decodeB64(j['dh_pub'] as String),
    pn: j['pn'] as int,
    n: j['n'] as int,
  );

  Map<String, dynamic> toJson() => {
    'dh_pub': encodeB64(dhPub),
    'pn': pn,
    'n': n,
  };

  final Uint8List dhPub;
  final int pn;
  final int n;
}

/// A ratchet session's serialized state (pkg/ratchet.Session's own JSON
/// form). Deliberately opaque here: the app never inspects its fields,
/// only persists this map and passes it back into the next
/// encrypt/decrypt call.
typedef RatchetSessionJson = Map<String, dynamic>;

/// Result of FreizoneCore.initiateSession: a session ready to encrypt,
/// plus the InitialMessage the responder needs.
class InitiateSessionResult {
  InitiateSessionResult({required this.session, required this.initial});

  factory InitiateSessionResult.fromJson(Map<String, dynamic> j) =>
      InitiateSessionResult(
        session: j['session'] as Map<String, dynamic>,
        initial: InitialMessage.fromJson(j['initial'] as Map<String, dynamic>),
      );

  final RatchetSessionJson session;
  final InitialMessage initial;
}

/// Result of FreizoneCore.sessionEncrypt: the updated session (to
/// persist) plus the header/ciphertext to send.
class EncryptResult {
  EncryptResult({
    required this.session,
    required this.header,
    required this.ciphertext,
  });

  factory EncryptResult.fromJson(Map<String, dynamic> j) => EncryptResult(
    session: j['session'] as Map<String, dynamic>,
    header: RatchetHeader.fromJson(j['header'] as Map<String, dynamic>),
    ciphertext: decodeB64(j['ciphertext'] as String),
  );

  final RatchetSessionJson session;
  final RatchetHeader header;
  final Uint8List ciphertext;
}

/// Result of FreizoneCore.sessionDecrypt: the updated session (to
/// persist) plus the decrypted plaintext.
class DecryptResult {
  DecryptResult({required this.session, required this.plaintext});

  factory DecryptResult.fromJson(Map<String, dynamic> j) => DecryptResult(
    session: j['session'] as Map<String, dynamic>,
    plaintext: decodeB64(j['plaintext'] as String),
  );

  final RatchetSessionJson session;
  final Uint8List plaintext;
}

/// Result of FreizoneCore.parseEnvelope: a message's header/ciphertext,
/// plus X3DH InitialMessage fields if this was a session's first message.
class ParsedEnvelope {
  ParsedEnvelope({
    required this.header,
    required this.ciphertext,
    this.initial,
    this.rekey,
  });

  factory ParsedEnvelope.fromJson(Map<String, dynamic> j) => ParsedEnvelope(
    header: RatchetHeader.fromJson(j['header'] as Map<String, dynamic>),
    ciphertext: decodeB64(j['ciphertext'] as String),
    initial: j['initial'] == null
        ? null
        : InitialMessage.fromJson(j['initial'] as Map<String, dynamic>),
    rekey: j['rekey'] as bool?,
  );

  final RatchetHeader header;
  final Uint8List ciphertext;
  final InitialMessage? initial;

  /// What the sender said about the prekey block on this envelope (SRV-17):
  /// true for a session they deliberately discarded and re-established, false
  /// for an ordinary establishment, and **null for a sender that said nothing**
  /// -- an older build, whose intent has to be inferred from the decrypted
  /// content instead. Always null when there is no prekey block.
  ///
  /// The three states are genuinely three: reading null as false would treat
  /// every older peer's re-key as a race and drop it on the tie-break, which is
  /// the bug this field exists to make impossible for peers that do state it.
  final bool? rekey;
}

/// The four per-request signature headers (Signature-Key-Id,
/// Signature-Timestamp, Signature-Nonce, Signature) to attach to an
/// outgoing authenticated request -- see docs/PROTOCOL.md in
/// freizone-server.
typedef SignedHeaders = Map<String, String>;

/// An attachment's ciphertext plus the key that decrypts it -- the result of
/// [FreizoneCore.encryptBlob]. The ciphertext is uploaded to the recipient's
/// blob store; the key goes into the message, inside its own end-to-end
/// encryption, so the server storing the blob can never read it.
class EncryptedBlob {
  const EncryptedBlob({
    required this.key,
    required this.ciphertext,
    required this.digest,
  });

  final Uint8List key;
  final Uint8List ciphertext;

  /// Hex SHA-256 of [ciphertext], for the upload's Blob-Digest header --
  /// computed in the core, which already holds the bytes.
  final String digest;
}

// --- Groups (APP-16) --------------------------------------------------------

/// This account's own identity, as every group operation that signs
/// something needs all of it: who is acting, the device key that signs, and
/// the root key both to certify that device and -- for a founder -- to
/// re-derive the group root key.
class GroupIdentity {
  const GroupIdentity({
    required this.accountId,
    required this.rootPub,
    required this.rootPriv,
    required this.deviceId,
    required this.devicePub,
    required this.devicePriv,
  });

  final String accountId;
  final Uint8List rootPub;
  final Uint8List rootPriv;
  final String deviceId;
  final Uint8List devicePub;
  final Uint8List devicePriv;

  Map<String, dynamic> toJson() => {
    'account_id': accountId,
    'root_pub': encodeB64(rootPub),
    'root_priv': encodeB64(rootPriv),
    'device_id': deviceId,
    'device_pub': encodeB64(devicePub),
    'device_priv': encodeB64(devicePriv),
  };
}

/// One member's standing in a group.
class GroupMember {
  const GroupMember({
    required this.accountId,
    required this.server,
    required this.role,
    required this.joined,
    required this.addedAt,
  });

  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
    accountId: j['account_id'] as String,
    server: j['server'] as String? ?? '',
    role: j['role'] as String? ?? 'none',
    joined: j['joined'] as bool? ?? false,
    addedAt: decodeTime(j['added_at'] as String),
  );

  final String accountId;

  /// Their home server. Needed by everyone, since a group message is
  /// delivered to each member individually.
  final String server;

  /// "founder" · "admin" · "moderator" · "member". A string rather than a
  /// number, so the wire's rank values stay inside the core.
  final String role;

  /// False for an invitee who has not accepted yet. They are shown, so a
  /// moderator can see the invitation is outstanding, but nothing is sent to
  /// them: being added must not disclose their address to the group before
  /// they agree to it.
  final bool joined;

  final DateTime addedAt;

  bool get isFounder => role == 'founder';
  bool get isAdmin => role == 'admin' || isFounder;
  bool get isModerator => role == 'moderator' || isAdmin;
}

/// The current membership, folded from the fact set by the core.
class GroupResolved {
  const GroupResolved({
    required this.groupId,
    required this.founder,
    required this.name,
    required this.topic,
    required this.members,
    required this.dissolved,
  });

  factory GroupResolved.fromJson(Map<String, dynamic> j) => GroupResolved(
    groupId: j['group_id'] as String? ?? '',
    founder: j['founder'] as String? ?? '',
    name: j['name'] as String? ?? '',
    topic: j['topic'] as String? ?? '',
    members: ((j['members'] as List<dynamic>?) ?? const [])
        .map((m) => GroupMember.fromJson(m as Map<String, dynamic>))
        .toList(),
    dissolved: j['dissolved'] as bool? ?? false,
  );

  final String groupId;
  final String founder;
  final String name;
  final String topic;
  final List<GroupMember> members;
  final bool dissolved;

  GroupMember? memberById(String accountId) {
    for (final m in members) {
      if (m.accountId == accountId) return m;
    }
    return null;
  }

  String roleOf(String accountId) => memberById(accountId)?.role ?? 'none';
}

/// One event a peer sent that could not be admitted, and why.
class GroupRejection {
  const GroupRejection({required this.index, required this.id, required this.reason});

  factory GroupRejection.fromJson(Map<String, dynamic> j) => GroupRejection(
    index: (j['index'] as num?)?.toInt() ?? -1,
    id: j['id'] as String? ?? '',
    reason: j['reason'] as String? ?? 'unknown',
  );

  /// Position in the submitted batch -- the only handle on an event whose id
  /// could not even be computed.
  final int index;
  final String id;
  final String reason;

  /// True while this event is merely not admissible *yet*: it arrived before
  /// the genesis it depends on, which is routine, since delivery is
  /// unordered. Worth holding and retrying, unlike a bad signature.
  bool get isPremature => reason == 'no genesis event yet';
}

/// What every group call returns: the opaque state blob to persist, plus the
/// view derived from it.
///
/// [state] is deliberately not modelled. It is the signed fact set, and only
/// the core interprets it -- exactly as with a ratchet session. Keeping it
/// opaque is what guarantees this client cannot fold a group into a state
/// that disagrees with what another client computes from the same facts.
class GroupStateResult {
  const GroupStateResult({
    required this.groupId,
    required this.state,
    required this.stateHash,
    required this.resolved,
    required this.applied,
    required this.known,
    required this.rejected,
  });

  factory GroupStateResult.fromJson(Map<String, dynamic> j) => GroupStateResult(
    groupId: j['group_id'] as String? ?? '',
    state: j['state'] as Map<String, dynamic>? ?? const {},
    stateHash: j['state_hash'] as String? ?? '',
    resolved: GroupResolved.fromJson(
      j['resolved'] as Map<String, dynamic>? ?? const {},
    ),
    applied: ((j['applied'] as List<dynamic>?) ?? const []).cast<String>(),
    known: ((j['known'] as List<dynamic>?) ?? const []).cast<String>(),
    rejected: ((j['rejected'] as List<dynamic>?) ?? const [])
        .map((r) => GroupRejection.fromJson(r as Map<String, dynamic>))
        .toList(),
  );

  final String groupId;
  final Map<String, dynamic> state;

  /// The fingerprint that rides on every group message, so a peer can tell
  /// without exchanging anything that the two of us are missing each other's
  /// facts.
  final String stateHash;

  final GroupResolved resolved;

  /// Ids of events this call newly admitted, ones it already had, and ones it
  /// refused. Re-delivering a fact is routine rather than an error -- the same
  /// snapshot arrives from several members.
  final List<String> applied;
  final List<String> known;
  final List<GroupRejection> rejected;
}

/// A server attestation that has been checked out (SRV-19 / APP-22):
/// genuinely signed by a trusted issuer, and currently valid for the domain
/// it was checked against. There is deliberately no factory for "invalid" --
/// FreizoneCore.verifyAttestation returns null instead of an AttestationInfo
/// for anything that doesn't hold up, so a caller can never accidentally
/// read a half-failed result as if it were good. See
/// docs/design/22-verified-badge.md on why absence must never be shown as a
/// warning, regardless of which check failed.
class AttestationInfo {
  AttestationInfo({
    required this.tier,
    required this.subject,
    required this.expiresAt,
  });

  factory AttestationInfo.fromJson(Map<String, dynamic> j) => AttestationInfo(
    tier: j['tier'] as String? ?? '',
    subject: j['subject'] as String? ?? '',
    expiresAt: DateTime.fromMillisecondsSinceEpoch(
      ((j['expires_at'] as num?)?.toInt() ?? 0) * 1000,
      isUtc: true,
    ),
  );

  /// "community" or "commercial" today, but open-ended -- see
  /// pkg/attest.Tier in freizone-server. Rendering falls back to a neutral
  /// label for anything this build doesn't recognise rather than showing
  /// nothing, the same forward-compatibility rule SRV-10 tracks elsewhere.
  final String tier;

  /// Display name for the operator, e.g. "Example GmbH". Empty is valid --
  /// not every attestation names one.
  final String subject;

  final DateTime expiresAt;
}
