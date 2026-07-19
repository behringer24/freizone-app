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
  });

  factory ParsedEnvelope.fromJson(Map<String, dynamic> j) => ParsedEnvelope(
    header: RatchetHeader.fromJson(j['header'] as Map<String, dynamic>),
    ciphertext: decodeB64(j['ciphertext'] as String),
    initial: j['initial'] == null
        ? null
        : InitialMessage.fromJson(j['initial'] as Map<String, dynamic>),
  );

  final RatchetHeader header;
  final Uint8List ciphertext;
  final InitialMessage? initial;
}

/// The four per-request signature headers (Signature-Key-Id,
/// Signature-Timestamp, Signature-Nonce, Signature) to attach to an
/// outgoing authenticated request -- see docs/PROTOCOL.md in
/// freizone-server.
typedef SignedHeaders = Map<String, String>;
