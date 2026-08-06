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
  ServerStatus({
    required this.claimed,
    required this.registrationPolicy,
    this.federationEnabled = true,
    this.blobsEnabled = false,
    this.maxBlobBytes = 0,
    this.maxBlobRecipients = 1,
    this.batchMessages = false,
    this.maxBatchMessages = 0,
    this.attestation,
  });

  factory ServerStatus.fromJson(Map<String, dynamic> j) => ServerStatus(
    claimed: j['claimed'] as bool,
    registrationPolicy: j['registration_policy'] as String,
    // Older servers don't send this; default to on (federation-open-by-design).
    federationEnabled: j['federation_enabled'] as bool? ?? true,
    // Absent means OFF here, the opposite of federation above: attachments
    // arrived with SRV-07, so a server that doesn't advertise the field
    // predates them and has no blob endpoints to talk to.
    blobsEnabled: j['blobs_enabled'] as bool? ?? false,
    maxBlobBytes: (j['max_blob_bytes'] as num?)?.toInt() ?? 0,
    // Absent means ONE, not unlimited (SRV-18). An older server reads only the
    // first recipient_device_id, stores the blob for that one device and still
    // answers 201 -- so assuming otherwise would silently deliver a group
    // picture to a single member. One is also what a server that states 0
    // means: it takes an upload, just not a shared one.
    maxBlobRecipients: () {
      final stated = (j['max_blob_recipients'] as num?)?.toInt() ?? 1;
      return stated < 1 ? 1 : stated;
    }(),
    // Absent means off, same reasoning as blobs: batch delivery arrived with
    // SRV-01, so a server that doesn't advertise it has no batch endpoint and
    // the fan-out posts one request per recipient instead. Discovered per
    // server, never once -- a group legitimately batches to one member's server
    // and not to another's (docs/PROTOCOL.md §4).
    batchMessages: j['batch_messages'] as bool? ?? false,
    maxBatchMessages: (j['max_batch_messages'] as num?)?.toInt() ?? 0,
    // Opaque (SRV-19) -- this DTO only carries it; FreizoneCore.
    // verifyAttestation is what turns it into something safe to render.
    // Omitted (null), not empty, means no attestation is configured, which
    // is the ordinary case for the overwhelming majority of servers.
    attestation: j['attestation'] as String?,
  );

  final bool claimed;
  final String registrationPolicy;
  final bool federationEnabled;

  /// Whether this server accepts encrypted attachment blobs (SRV-07).
  final bool blobsEnabled;

  /// Largest single blob this server accepts, or 0 if it didn't say.
  final int maxBlobBytes;

  /// How many recipient devices one upload may name (SRV-18), which is what
  /// lets a group picture cost one upload per recipient *server* rather than
  /// one per member. Never below 1: see the absence rule in [fromJson].
  final int maxBlobRecipients;

  /// Whether this server accepts several envelopes in one request, which is what
  /// collapses a group fan-out to one request per distinct recipient server
  /// (SRV-01).
  final bool batchMessages;

  /// How many items it accepts in one batch, or 0 if it didn't say -- a sender
  /// must split above this rather than have the whole batch refused.
  final int maxBatchMessages;

  /// Opaque pkg/attest token (SRV-19), or null if this server carries no
  /// attestation -- the ordinary case. Never rendered directly: pass it to
  /// FreizoneCore.verifyAttestation against the domain actually being shown,
  /// and only render its result.
  final String? attestation;
}

/// What one item of a batch send came back as (docs/PROTOCOL.md §7).
///
/// Deliberately not thrown: a failure is *per item*, so one recipient at their
/// queue cap must not cost the other members their copy. The caller maps each
/// result onto that recipient's own delivery state.
class BatchSendResult {
  BatchSendResult({required this.messageId, required this.status});

  factory BatchSendResult.fromJson(Map<String, dynamic> j) => BatchSendResult(
    messageId: j['message_id'] as String? ?? '',
    status: j['status'] as String? ?? 'internal_error',
  );

  final String messageId;
  final String status;

  /// `duplicate` counts as delivered for the same reason a `409` does on the
  /// single-message route: that id is already queued, so a retry has nothing
  /// left to do.
  bool get isDelivered => status == 'queued' || status == 'duplicate';
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
    this.oneTimePrekeyOmitted,
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
        oneTimePrekeyOmitted: j['one_time_prekey_omitted'] as String?,
      );

  final String deviceId;
  final Uint8List dhIdentityPubKey;
  final DHIdentityCertDTO dhIdentityCert;
  final SignedPrekeyDTO signedPrekey;
  final OneTimePrekeyDTO? oneTimePrekey;

  /// Why no one-time prekey came back: `"pool_empty"`, or `"unauthenticated"`
  /// when the server didn't accept our credentials (SRV-04). Null when one was
  /// handed out, and also null from a server predating the field. Diagnostic
  /// only -- a session starts either way, just with reduced forward secrecy on
  /// its first message.
  final String? oneTimePrekeyOmitted;

  /// True when the server told us our claim was unauthenticated. Always a bug
  /// on this side -- the app signs every claim -- so it is worth logging loudly
  /// rather than silently accepting the weaker session.
  bool get wasClaimedUnauthenticated => oneTimePrekeyOmitted == 'unauthenticated';
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
    this.pendingMessages = 0,
    this.oldestPendingAt,
    this.blobCount = 0,
    this.blobBytes = 0,
    this.blobBytesLimit = 0,
    this.deviceCount = 0,
    this.invitedBy,
  });

  /// Every activity field defaults rather than being required: a server that
  /// predates SRV-09 simply doesn't send them, and the admin list must still
  /// work against one (see docs/PROTOCOL.md §4). Zero then reads as "this
  /// server doesn't report it", which [hasActivitySignals] distinguishes from
  /// a genuinely idle account.
  factory AdminAccountSummary.fromJson(Map<String, dynamic> j) =>
      AdminAccountSummary(
        id: j['id'] as String,
        role: j['role'] as String,
        status: j['status'] as String,
        createdAt: decodeTime(j['created_at'] as String),
        pendingMessages: (j['pending_messages'] as num?)?.toInt() ?? 0,
        oldestPendingAt: j['oldest_pending_at'] == null
            ? null
            : decodeTime(j['oldest_pending_at'] as String),
        blobCount: (j['blob_count'] as num?)?.toInt() ?? 0,
        blobBytes: (j['blob_bytes'] as num?)?.toInt() ?? 0,
        blobBytesLimit: (j['blob_bytes_limit'] as num?)?.toInt() ?? 0,
        deviceCount: (j['device_count'] as num?)?.toInt() ?? 0,
        invitedBy: j['invited_by'] as String?,
      );

  final String id;
  final String role;
  final String status;
  final DateTime createdAt;

  /// How many messages are queued undelivered across this account's devices,
  /// and when the earliest of them was sent (null when the queue is empty).
  /// The age is the actual abandonment signal -- a big queue minutes old is a
  /// busy account, the same queue three weeks old is a device that never
  /// came back.
  final int pendingMessages;
  final DateTime? oldestPendingAt;

  /// Stored attachment ciphertext, and the quota it is measured against: the
  /// server's per-device limit times [deviceCount], since that is where the
  /// limit is enforced. [blobBytesLimit] is 0 when there is no meaningful
  /// limit to show (no devices, or a server that doesn't report it).
  final int blobCount;
  final int blobBytes;
  final int blobBytesLimit;
  final int deviceCount;

  /// The account that issued the invite this one joined with (SRV-14). Sent to
  /// admins only, so this is always null for a moderator -- and also null for
  /// an account that needed no invite, or whose inviter has since been deleted
  /// (the invite record goes with them). Read it as "not known", never as
  /// "registered openly".
  final String? invitedBy;

  /// Whether this entry carries SRV-09's signals at all. A server that
  /// predates them reports no devices either -- and an account always has at
  /// least one device, or it could never have registered -- so the device
  /// count is the one field that cannot legitimately be zero on a server that
  /// does report them.
  bool get hasActivitySignals => deviceCount > 0;
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
