// Idiomatic Dart wrapper around the Go crypto/protocol core
// (native/core.go + logic.go in this repo). Every method here corresponds
// 1:1 to one cgo-exported function; see that file for the underlying
// Go-side request/response shapes this class serializes to/from JSON.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'freizone_core_bindings.dart';
import 'freizone_core_exception.dart';
import 'models.dart';

class FreizoneCore {
  FreizoneCore._(this._bindings);

  factory FreizoneCore() => FreizoneCore._(FreizoneCoreBindings.open());

  final FreizoneCoreBindings _bindings;

  /// Static build/version string from the native core -- useful as a
  /// basic "is the library loaded" sanity check.
  String version() {
    final ptr = _bindings.version();
    try {
      return ptr.toDartString();
    } finally {
      _bindings.free(ptr);
    }
  }

  // --- Identity -------------------------------------------------------

  Identity generateIdentity() =>
      Identity.fromJson(_callNoArg(_bindings.generateIdentity));

  bool verifyAddressId(String id, Uint8List rootPub) {
    final data = _call(_bindings.verifyAddressId, {
      'id': id,
      'root_pub': encodeB64(rootPub),
    });
    return data['valid'] as bool;
  }

  // --- Device certificate -----------------------------------------------

  DeviceCertificate signDeviceCertificate({
    required String accountId,
    required String deviceId,
    required Uint8List devicePub,
    required DateTime issuedAt,
    required Uint8List rootPriv,
  }) {
    final data = _call(_bindings.signDeviceCertificate, {
      'account_id': accountId,
      'device_id': deviceId,
      'device_pub': encodeB64(devicePub),
      'issued_at': encodeTime(issuedAt),
      'root_priv': encodeB64(rootPriv),
    });
    return DeviceCertificate.fromJson(data);
  }

  bool verifyDeviceCertificate(DeviceCertificate cert, Uint8List rootPub) {
    final data = _call(_bindings.verifyDeviceCertificate, {
      'cert': cert.toJson(),
      'root_pub': encodeB64(rootPub),
    });
    return data['valid'] as bool;
  }

  // --- X3DH key material --------------------------------------------------

  X25519KeyPair generateX25519KeyPair() =>
      X25519KeyPair.fromJson(_callNoArg(_bindings.generateX25519KeyPair));

  DHIdentityCertificate signDHIdentityCertificate({
    required String accountId,
    required String deviceId,
    required Uint8List dhPub,
    required DateTime issuedAt,
    required Uint8List devicePriv,
  }) {
    final data = _call(_bindings.signDHIdentityCertificate, {
      'account_id': accountId,
      'device_id': deviceId,
      'dh_pub': encodeB64(dhPub),
      'issued_at': encodeTime(issuedAt),
      'device_priv': encodeB64(devicePriv),
    });
    return DHIdentityCertificate.fromJson(data);
  }

  bool verifyDHIdentityCertificate(
    DHIdentityCertificate cert,
    Uint8List devicePub,
  ) {
    final data = _call(_bindings.verifyDHIdentityCertificate, {
      'cert': cert.toJson(),
      'device_pub': encodeB64(devicePub),
    });
    return data['valid'] as bool;
  }

  SignedPrekeyCertificate signSignedPrekeyCertificate({
    required String accountId,
    required String deviceId,
    required int keyId,
    required Uint8List dhIdentityPub,
    required Uint8List prekeyPub,
    required DateTime issuedAt,
    required Uint8List devicePriv,
  }) {
    final data = _call(_bindings.signSignedPrekeyCertificate, {
      'account_id': accountId,
      'device_id': deviceId,
      'key_id': keyId,
      'dh_identity_pub': encodeB64(dhIdentityPub),
      'prekey_pub': encodeB64(prekeyPub),
      'issued_at': encodeTime(issuedAt),
      'device_priv': encodeB64(devicePriv),
    });
    return SignedPrekeyCertificate.fromJson(data);
  }

  bool verifySignedPrekeyCertificate(
    SignedPrekeyCertificate cert,
    Uint8List devicePub,
  ) {
    final data = _call(_bindings.verifySignedPrekeyCertificate, {
      'cert': cert.toJson(),
      'device_pub': encodeB64(devicePub),
    });
    return data['valid'] as bool;
  }

  // --- X3DH session establishment -----------------------------------------

  InitiateSessionResult initiateSession({
    required Uint8List localDhIdentityPriv,
    required RemoteBundle remote,
  }) {
    final data = _call(_bindings.initiateSession, {
      'local_dh_identity_priv': encodeB64(localDhIdentityPriv),
      'remote': remote.toJson(),
    });
    return InitiateSessionResult.fromJson(data);
  }

  RatchetSessionJson respondToSession({
    required Uint8List localDhIdentityPriv,
    required Uint8List signedPrekeyPriv,
    Uint8List? oneTimePrekeyPriv,
    required InitialMessage initial,
  }) {
    final data = _call(_bindings.respondToSession, {
      'local_dh_identity_priv': encodeB64(localDhIdentityPriv),
      'signed_prekey_priv': encodeB64(signedPrekeyPriv),
      if (oneTimePrekeyPriv != null)
        'one_time_prekey_priv': encodeB64(oneTimePrekeyPriv),
      'initial': initial.toJson(),
    });
    return data['session'] as Map<String, dynamic>;
  }

  // --- Double Ratchet message encryption -----------------------------------

  EncryptResult sessionEncrypt({
    required RatchetSessionJson session,
    required Uint8List plaintext,
  }) {
    final data = _call(_bindings.sessionEncrypt, {
      'session': session,
      'plaintext': encodeB64(plaintext),
    });
    return EncryptResult.fromJson(data);
  }

  /// Decrypts one envelope, returning the advanced session to persist.
  ///
  /// Pure with respect to [session]: a failure leaves the passed-in session
  /// untouched (the core clones and commits only on success), which is what
  /// lets a caller try a speculative re-key and fall back. Throws
  /// [FreizoneCoreException] on failure, carrying a [CoreErrorCode] whenever
  /// the core could classify it -- check
  /// [FreizoneCoreException.suggestsDesync] rather than the message text.
  DecryptResult sessionDecrypt({
    required RatchetSessionJson session,
    required RatchetHeader header,
    required Uint8List ciphertext,
  }) {
    final data = _call(_bindings.sessionDecrypt, {
      'session': session,
      'header': header.toJson(),
      'ciphertext': encodeB64(ciphertext),
    });
    return DecryptResult.fromJson(data);
  }

  // --- Wire envelope ----------------------------------------------------

  /// Builds a message's opaque wire payload (the value to send as
  /// `payload` in `POST /v1/messages`). Pass [initial] only for a
  /// session's first message.
  /// [rekey] qualifies the prekey block when [initial] is given (SRV-17): true
  /// if this session was deliberately discarded and re-established, false for an
  /// ordinary establishment. Always pass one of the two -- leaving it null puts
  /// the receiver back to guessing from the decrypted content, which is only
  /// meant for senders that predate the field. Ignored without an [initial],
  /// since there is no prekey block to qualify.
  Map<String, dynamic> buildEnvelope({
    InitialMessage? initial,
    required RatchetHeader header,
    required Uint8List ciphertext,
    bool? rekey,
  }) {
    final data = _call(_bindings.buildEnvelope, {
      if (initial != null) 'initial': initial.toJson(),
      'header': header.toJson(),
      'ciphertext': encodeB64(ciphertext),
      if (initial != null && rekey != null) 'rekey': rekey,
    });
    return data['payload'] as Map<String, dynamic>;
  }

  /// Parses a message's opaque wire payload (as received from
  /// `GET /v1/messages` or the SSE stream).
  ParsedEnvelope parseEnvelope(Map<String, dynamic> payload) {
    final data = _call(_bindings.parseEnvelope, {'payload': payload});
    return ParsedEnvelope.fromJson(data);
  }

  // --- HTTP request signing -------------------------------------------------

  /// Signs an API request per docs/PROTOCOL.md's per-request signature
  /// scheme, returning the four headers to attach to it. [path] must be
  /// the request's path only (no query string); pass the raw query
  /// string separately via [rawQuery].
  SignedHeaders signHTTPRequest({
    required String method,
    required String path,
    String rawQuery = '',
    Uint8List? body,
    required String deviceId,
    required Uint8List devicePriv,
  }) {
    final data = _call(_bindings.signHTTPRequest, {
      'method': method,
      'path': path,
      if (rawQuery.isNotEmpty) 'raw_query': rawQuery,
      if (body != null && body.isNotEmpty) 'body': encodeB64(body),
      'device_id': deviceId,
      'device_priv': encodeB64(devicePriv),
    });
    return (data['headers'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, v as String),
    );
  }

  // --- Recovery seed phrase (APP-01) ---------------------------------------

  /// Reveals the 24-word BIP-39 backup phrase for an account's root key.
  /// Anyone with this phrase can restore (and thus control) the account.
  List<String> revealRecoveryPhrase(Uint8List rootPriv) {
    final data = _call(_bindings.revealRecoveryPhrase, {
      'root_priv': encodeB64(rootPriv),
    });
    return (data['words'] as List).cast<String>();
  }

  /// Rebuilds an identity from a 24-word recovery phrase: the same root key
  /// (hence the same account id and short id) plus a *fresh* device keypair.
  /// Throws [FreizoneCoreException] if the phrase has an unknown word or a
  /// bad checksum.
  Identity restoreIdentityFromSeed(List<String> words) =>
      Identity.fromJson(_call(_bindings.restoreIdentityFromSeed, {'words': words}));

  /// The full BIP-39 English wordlist (2048 words), for driving recovery-phrase
  /// autocomplete and per-word validation entirely offline.
  List<String> recoveryWordlist() =>
      (_callNoArg(_bindings.recoveryWordlist)['words'] as List).cast<String>();

  /// Encrypts an attachment with a freshly generated key (AES-256-GCM),
  /// returning both. The key is deliberately NOT derived from the ratchet:
  /// the blob outlives the message on the server, so resetting a secure
  /// session must not make already-received pictures undownloadable. It
  /// travels to the recipient inside the message's own encryption, so the
  /// server holding the blob never sees it.
  EncryptedBlob encryptBlob(Uint8List plaintext) {
    final data = _call(_bindings.encryptBlob, {
      'plaintext': encodeB64(plaintext),
    });
    return EncryptedBlob(
      key: decodeB64(data['key'] as String),
      ciphertext: decodeB64(data['ciphertext'] as String),
      digest: data['digest'] as String,
    );
  }

  /// Decrypts an attachment fetched from the blob store. Throws
  /// [FreizoneCoreException] for a wrong key or any tampering -- the
  /// ciphertext is authenticated, so corrupt bytes are never returned as if
  /// they were a picture.
  Uint8List decryptBlob({required Uint8List key, required Uint8List ciphertext}) {
    final data = _call(_bindings.decryptBlob, {
      'key': encodeB64(key),
      'ciphertext': encodeB64(ciphertext),
    });
    return decodeB64(data['plaintext'] as String);
  }

  // --- Groups (APP-16) -----------------------------------------------------
  //
  // The state blob these pass back and forth is opaque here on purpose: it is
  // the signed fact set, and only the core interprets it. That is what keeps
  // the convergence rules in one place, so a bug on this side cannot produce
  // a group state that disagrees with what another client computes from the
  // same facts.

  /// Founds a group. The group root key is derived from this account's root
  /// key and a nonce stored in the genesis event, so it survives total device
  /// loss: restore the seed phrase, get the state from any member, re-derive.
  GroupStateResult groupCreate({
    required GroupIdentity identity,
    required String server,
    String name = '',
    String topic = '',
    DateTime? issuedAt,
  }) {
    final data = _call(_bindings.groupCreate, {
      'identity': identity.toJson(),
      'server': server,
      'name': name,
      'topic': topic,
      'issued_at': encodeTime(issuedAt ?? DateTime.now()),
    });
    return GroupStateResult.fromJson(data);
  }

  /// Builds and signs one group event, ready to be applied locally and sent
  /// to every member.
  ///
  /// Which key signs it is decided in the core, not here: raising someone to
  /// admin is the founder's alone and needs the group root key, everything
  /// below is an ordinary device signature. The returned event is opaque and
  /// only travels -- to [groupApplyEvents] and into a `v: 5` envelope.
  Map<String, dynamic> groupSignEvent({
    required GroupIdentity identity,
    required Map<String, dynamic> state,
    required String type,
    String subject = '',
    String server = '',
    String role = '',
    String name = '',
    String topic = '',
    DateTime? issuedAt,
  }) {
    final data = _call(_bindings.groupSignEvent, {
      'identity': identity.toJson(),
      'state': state,
      'type': type,
      'subject': subject,
      'server': server,
      'role': role,
      'name': name,
      'topic': topic,
      'issued_at': encodeTime(issuedAt ?? DateTime.now()),
    });
    return data['event'] as Map<String, dynamic>;
  }

  /// Merges events into a state blob, whether our own or a peer's. Pass an
  /// empty [state] for a group being heard of for the first time.
  ///
  /// A bad event costs only itself: the call reports it in
  /// [GroupStateResult.rejected] rather than failing, since a snapshot from a
  /// hostile peer must not be able to discard the good facts alongside it.
  GroupStateResult groupApplyEvents({
    required Map<String, dynamic> state,
    required List<Map<String, dynamic>> events,
  }) {
    final data = _call(_bindings.groupApplyEvents, {
      'state': state,
      'events': events,
    });
    return GroupStateResult.fromJson(data);
  }

  /// Folds a state blob into the view the UI renders: members with roles, who
  /// has accepted, the name and topic, and the state hash.
  GroupStateResult groupResolveState(Map<String, dynamic> state) =>
      GroupStateResult.fromJson(
        _call(_bindings.groupResolveState, {'state': state}),
      );

  // --- boilerplate ---------------------------------------------------------

  Map<String, dynamic> _callNoArg(Pointer<Utf8> Function() fn) =>
      _decodeEnvelope(fn());

  Map<String, dynamic> _call(
    Pointer<Utf8> Function(Pointer<Utf8>) fn,
    Map<String, dynamic> request,
  ) {
    final reqPtr = json.encode(request).toNativeUtf8();
    try {
      return _decodeEnvelope(fn(reqPtr));
    } finally {
      malloc.free(reqPtr);
    }
  }

  Map<String, dynamic> _decodeEnvelope(Pointer<Utf8> resultPtr) {
    try {
      final env = json.decode(resultPtr.toDartString()) as Map<String, dynamic>;
      if (env['ok'] != true) {
        throw FreizoneCoreException(
          env['error'] as String? ?? 'unknown native core error',
          code: env['code'] as String?,
        );
      }
      return (env['data'] as Map<String, dynamic>?) ?? const {};
    } finally {
      _bindings.free(resultPtr);
    }
  }
}
