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
  Map<String, dynamic> buildEnvelope({
    InitialMessage? initial,
    required RatchetHeader header,
    required Uint8List ciphertext,
  }) {
    final data = _call(_bindings.buildEnvelope, {
      if (initial != null) 'initial': initial.toJson(),
      'header': header.toJson(),
      'ciphertext': encodeB64(ciphertext),
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
        );
      }
      return (env['data'] as Map<String, dynamic>?) ?? const {};
    } finally {
      _bindings.free(resultPtr);
    }
  }
}
