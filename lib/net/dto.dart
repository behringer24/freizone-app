// REST wire-format DTOs for freizone-server's /v1/ API (docs/PROTOCOL.md
// in freizone-server), mirroring cmd/devclient/dto.go field-for-field.
// Deliberately separate from ffi/models.dart: the FFI boundary and the
// REST API are two different wire contracts with their own field-naming
// conventions (e.g. `device_pub_key` vs `device_pubkey`).
import 'dart:typed_data';

import '../ffi/models.dart' show decodeB64, decodeTime, encodeB64, encodeTime;

/// GET /v1/server-status -- lets the setup wizard decide which path
/// applies (bootstrap/open/invite/closed) before any identity exists.
class ServerStatus {
  ServerStatus({required this.claimed, required this.registrationPolicy});

  factory ServerStatus.fromJson(Map<String, dynamic> j) => ServerStatus(
    claimed: j['claimed'] as bool,
    registrationPolicy: j['registration_policy'] as String,
  );

  final bool claimed;
  final String registrationPolicy;
}

class AccountResponse {
  AccountResponse({
    required this.id,
    required this.rootPubKey,
    required this.devices,
  });

  factory AccountResponse.fromJson(Map<String, dynamic> j) => AccountResponse(
    id: j['id'] as String,
    rootPubKey: decodeB64(j['root_pubkey'] as String),
    devices: (j['devices'] as List<dynamic>)
        .map((e) => DeviceResponse.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  final String id;
  final Uint8List rootPubKey;
  final List<DeviceResponse> devices;
}

class DeviceResponse {
  DeviceResponse({
    required this.deviceId,
    required this.devicePubKey,
    required this.issuedAt,
    required this.signature,
    required this.status,
    this.revokedAt,
  });

  factory DeviceResponse.fromJson(Map<String, dynamic> j) => DeviceResponse(
    deviceId: j['device_id'] as String,
    devicePubKey: decodeB64(j['device_pubkey'] as String),
    issuedAt: decodeTime(j['issued_at'] as String),
    signature: decodeB64(j['signature'] as String),
    status: j['status'] as String,
    revokedAt: j['revoked_at'] == null
        ? null
        : decodeTime(j['revoked_at'] as String),
  );

  final String deviceId;
  final Uint8List devicePubKey;
  final DateTime issuedAt;
  final Uint8List signature;
  final String status;
  final DateTime? revokedAt;
}

class DHIdentityCertDTO {
  DHIdentityCertDTO({
    required this.dhPubKey,
    required this.issuedAt,
    required this.signature,
  });

  factory DHIdentityCertDTO.fromJson(Map<String, dynamic> j) =>
      DHIdentityCertDTO(
        dhPubKey: decodeB64(j['dh_pubkey'] as String),
        issuedAt: decodeTime(j['issued_at'] as String),
        signature: decodeB64(j['signature'] as String),
      );

  Map<String, dynamic> toJson() => {
    'dh_pubkey': encodeB64(dhPubKey),
    'issued_at': encodeTime(issuedAt),
    'signature': encodeB64(signature),
  };

  final Uint8List dhPubKey;
  final DateTime issuedAt;
  final Uint8List signature;
}

class SignedPrekeyDTO {
  SignedPrekeyDTO({
    required this.keyId,
    required this.dhIdentityPubKey,
    required this.pubKey,
    required this.issuedAt,
    required this.signature,
  });

  factory SignedPrekeyDTO.fromJson(Map<String, dynamic> j) => SignedPrekeyDTO(
    keyId: j['key_id'] as int,
    dhIdentityPubKey: decodeB64(j['dh_identity_pubkey'] as String),
    pubKey: decodeB64(j['pubkey'] as String),
    issuedAt: decodeTime(j['issued_at'] as String),
    signature: decodeB64(j['signature'] as String),
  );

  Map<String, dynamic> toJson() => {
    'key_id': keyId,
    'dh_identity_pubkey': encodeB64(dhIdentityPubKey),
    'pubkey': encodeB64(pubKey),
    'issued_at': encodeTime(issuedAt),
    'signature': encodeB64(signature),
  };

  final int keyId;
  final Uint8List dhIdentityPubKey;
  final Uint8List pubKey;
  final DateTime issuedAt;
  final Uint8List signature;
}

class OneTimePrekeyDTO {
  OneTimePrekeyDTO({required this.keyId, required this.pubKey});

  factory OneTimePrekeyDTO.fromJson(Map<String, dynamic> j) => OneTimePrekeyDTO(
    keyId: j['key_id'] as int,
    pubKey: decodeB64(j['pubkey'] as String),
  );

  Map<String, dynamic> toJson() => {
    'key_id': keyId,
    'pubkey': encodeB64(pubKey),
  };

  final int keyId;
  final Uint8List pubKey;
}

class PrekeyBundleResponse {
  PrekeyBundleResponse({
    required this.deviceId,
    required this.dhIdentityPubKey,
    required this.dhIdentityCert,
    required this.signedPrekey,
    this.oneTimePrekey,
  });

  factory PrekeyBundleResponse.fromJson(Map<String, dynamic> j) =>
      PrekeyBundleResponse(
        deviceId: j['device_id'] as String,
        dhIdentityPubKey: decodeB64(j['dh_identity_pubkey'] as String),
        dhIdentityCert: DHIdentityCertDTO.fromJson(
          j['dh_identity_cert'] as Map<String, dynamic>,
        ),
        signedPrekey: SignedPrekeyDTO.fromJson(
          j['signed_prekey'] as Map<String, dynamic>,
        ),
        oneTimePrekey: j['one_time_prekey'] == null
            ? null
            : OneTimePrekeyDTO.fromJson(
                j['one_time_prekey'] as Map<String, dynamic>,
              ),
      );

  final String deviceId;
  final Uint8List dhIdentityPubKey;
  final DHIdentityCertDTO dhIdentityCert;
  final SignedPrekeyDTO signedPrekey;
  final OneTimePrekeyDTO? oneTimePrekey;
}

class PrekeyStatusResponse {
  PrekeyStatusResponse({required this.oneTimePrekeysRemaining});

  factory PrekeyStatusResponse.fromJson(Map<String, dynamic> j) =>
      PrekeyStatusResponse(
        oneTimePrekeysRemaining: j['one_time_prekeys_remaining'] as int,
      );

  final int oneTimePrekeysRemaining;
}

/// POST /v1/admin/invites -- a freshly minted single-use invite code.
class CreateInviteResponse {
  CreateInviteResponse({required this.code, this.expiresAt});

  factory CreateInviteResponse.fromJson(Map<String, dynamic> j) =>
      CreateInviteResponse(
        code: j['code'] as String,
        expiresAt: j['expires_at'] == null
            ? null
            : decodeTime(j['expires_at'] as String),
      );

  final String code;
  final DateTime? expiresAt;
}

class AdminAccountSummary {
  AdminAccountSummary({
    required this.id,
    required this.role,
    required this.status,
    required this.createdAt,
  });

  factory AdminAccountSummary.fromJson(Map<String, dynamic> j) =>
      AdminAccountSummary(
        id: j['id'] as String,
        role: j['role'] as String,
        status: j['status'] as String,
        createdAt: decodeTime(j['created_at'] as String),
      );

  final String id;
  final String role;
  final String status;
  final DateTime createdAt;
}

class MessageResponse {
  MessageResponse({
    required this.messageId,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.sentAt,
    required this.payload,
  });

  factory MessageResponse.fromJson(Map<String, dynamic> j) => MessageResponse(
    messageId: j['message_id'] as String,
    senderAccountId: j['sender_account_id'] as String,
    senderDeviceId: j['sender_device_id'] as String,
    sentAt: decodeTime(j['sent_at'] as String),
    payload: j['payload'] as Map<String, dynamic>,
  );

  final String messageId;
  final String senderAccountId;
  final String senderDeviceId;
  final DateTime sentAt;
  final Map<String, dynamic> payload;
}
