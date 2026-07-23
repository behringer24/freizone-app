// REST client for freizone-server's /v1/ API (docs/PROTOCOL.md in
// freizone-server). Unauthenticated endpoints (bootstrap, registration,
// the account directory, prekey-bundle claims) are plain JSON requests;
// authenticated endpoints are signed per-request via
// FreizoneCore.signHTTPRequest -- see that method for the underlying
// Ed25519 scheme.
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../ffi/freizone_core.dart';
import '../ffi/models.dart';
import 'dto.dart';

/// Identifies which device is signing a request.
class DeviceCredentials {
  DeviceCredentials({required this.deviceId, required this.devicePriv});

  final String deviceId;
  final Uint8List devicePriv;
}

/// A non-2xx API response, carrying the server's `{"error":{...}}` body if
/// present.
class ApiException implements Exception {
  ApiException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String? code;
  final String message;

  @override
  String toString() =>
      'ApiException($statusCode${code != null ? ', $code' : ''}): $message';
}

/// The host answered, but not in the JSON every Freizone server speaks --
/// almost always because the address resolved to a domain that isn't
/// running Freizone at all (a parked page, a plain web server's HTML 404,
/// a reverse proxy). Kept distinct from [ApiException], which is a genuine
/// Freizone server refusing a request in its own JSON error format: this
/// one means "wrong server", so the UI can point the user at the address
/// instead of dumping a raw HTML page on them.
class NotFreizoneServerException implements Exception {
  NotFreizoneServerException(this.statusCode, this.host);

  final int statusCode;
  final String? host;

  @override
  String toString() =>
      'NotFreizoneServerException($statusCode${host != null ? ', $host' : ''})';
}

/// Decodes [resp]'s body as a JSON object, or throws
/// [NotFreizoneServerException] when it isn't one. A Freizone server always
/// answers in JSON, so a body that doesn't decode to a JSON object (HTML, an
/// empty page, a bare JSON value) is the reliable tell that the far end
/// isn't a Freizone server -- surfacing that as its own exception keeps raw
/// HTML and low-level FormatExceptions out of the user-facing error. Shared
/// by the client's decode paths; top-level so it can be unit-tested without
/// the FFI core an [ApiClient] instance needs.
Map<String, dynamic> parseJsonObject(http.Response resp) {
  final Object? decoded;
  try {
    decoded = json.decode(resp.body);
  } catch (_) {
    throw NotFreizoneServerException(resp.statusCode, resp.request?.url.host);
  }
  if (decoded is! Map<String, dynamic>) {
    throw NotFreizoneServerException(resp.statusCode, resp.request?.url.host);
  }
  return decoded;
}

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.core,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final FreizoneCore core;
  final http.Client _http;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Never _throwError(http.Response resp) {
    // parseJsonObject throws NotFreizoneServerException for an HTML/non-JSON
    // body -- i.e. this isn't a Freizone server saying no, it's not a
    // Freizone server at all.
    final body = parseJsonObject(resp);
    final err = body['error'];
    final code = err is Map<String, dynamic> ? err['code'] as String? : null;
    final message = err is Map<String, dynamic>
        ? (err['message'] as String? ?? resp.body)
        : resp.body;
    throw ApiException(resp.statusCode, code, message);
  }

  Map<String, dynamic> _decodeObject(http.Response resp, Set<int> okStatuses) {
    if (!okStatuses.contains(resp.statusCode)) _throwError(resp);
    if (resp.body.isEmpty) return const {};
    return parseJsonObject(resp);
  }

  void _checkStatus(http.Response resp, Set<int> okStatuses) {
    if (!okStatuses.contains(resp.statusCode)) _throwError(resp);
  }

  Future<http.Response> _unauthedRequest(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final req = http.Request(method, _uri(path));
    req.headers['Content-Type'] = 'application/json';
    if (body != null) req.body = json.encode(body);
    return http.Response.fromStream(await _http.send(req));
  }

  Future<http.Response> _signedRequest(
    String method,
    String path,
    Map<String, dynamic>? body,
    DeviceCredentials creds,
  ) async {
    final bodyBytes = body == null
        ? Uint8List(0)
        : Uint8List.fromList(utf8.encode(json.encode(body)));
    final headers = core.signHTTPRequest(
      method: method,
      path: path,
      body: bodyBytes,
      deviceId: creds.deviceId,
      devicePriv: creds.devicePriv,
    );
    final req = http.Request(method, _uri(path));
    req.headers['Content-Type'] = 'application/json';
    headers.forEach((key, value) => req.headers[key] = value);
    if (body != null) req.bodyBytes = bodyBytes;
    return http.Response.fromStream(await _http.send(req));
  }

  // --- Bootstrap / registration / directory ---------------------------------

  /// Public discovery call the setup wizard makes with only a server
  /// address, before any identity exists, to decide which setup step
  /// applies next (bootstrap / open / invite / closed).
  Future<ServerStatus> getServerStatus() async {
    final resp = await _unauthedRequest('GET', '/v1/server-status', null);
    return ServerStatus.fromJson(_decodeObject(resp, {200}));
  }

  Future<AccountResponse> bootstrapClaim({
    required String setupToken,
    required Identity identity,
    required DeviceCertificate cert,
  }) async {
    final resp = await _unauthedRequest('POST', '/v1/bootstrap/claim', {
      'setup_token': setupToken,
      'root_pubkey': encodeB64(identity.rootPub),
      'device_id': identity.deviceId,
      'device_pubkey': encodeB64(identity.devicePub),
      'device_cert_issued_at': encodeTime(cert.issuedAt),
      'device_cert_signature': encodeB64(cert.signature),
    });
    return AccountResponse.fromJson(_decodeObject(resp, {201}));
  }

  Future<AccountResponse> registerAccount({
    required Identity identity,
    required DeviceCertificate cert,
    String? inviteCode,
  }) async {
    final resp = await _unauthedRequest('POST', '/v1/accounts', {
      'root_pubkey': encodeB64(identity.rootPub),
      'device_id': identity.deviceId,
      'device_pubkey': encodeB64(identity.devicePub),
      'device_cert_issued_at': encodeTime(cert.issuedAt),
      'device_cert_signature': encodeB64(cert.signature),
      'invite_code': ?inviteCode,
    });
    return AccountResponse.fromJson(_decodeObject(resp, {201}));
  }

  Future<AccountResponse> getAccount(String accountId) async {
    final resp = await _unauthedRequest('GET', '/v1/accounts/$accountId', null);
    return AccountResponse.fromJson(_decodeObject(resp, {200}));
  }

  // --- Push -------------------------------------------------------------------

  /// Returns this server's VAPID public key (not secret) -- pass this to
  /// UnifiedPush.registerApp(vapid: ...) since some distributors require it.
  Future<String> getVAPIDPublicKey() async {
    final resp = await _unauthedRequest('GET', '/v1/vapid-public-key', null);
    return _decodeObject(resp, {200})['key'] as String;
  }

  /// Registers this device's push subscription (endpoint + the ECDH
  /// public key/auth secret the server needs to RFC 8291-encrypt wake
  /// notifications for it).
  Future<void> setPushEndpoint({
    required DeviceCredentials creds,
    required String endpoint,
    required String p256dh,
    required String auth,
  }) async {
    final resp = await _signedRequest(
      'PUT',
      '/v1/devices/${creds.deviceId}/push-endpoint',
      {'endpoint': endpoint, 'p256dh': p256dh, 'auth': auth},
      creds,
    );
    _checkStatus(resp, {200});
  }

  /// Clears this device's push subscription (e.g. the distributor
  /// unregistered it).
  Future<void> clearPushEndpoint(DeviceCredentials creds) async {
    final resp = await _signedRequest(
      'PUT',
      '/v1/devices/${creds.deviceId}/push-endpoint',
      {},
      creds,
    );
    _checkStatus(resp, {200});
  }

  /// Registers this device's FCM/APNs push target -- the counterpart to
  /// [setPushEndpoint] for delivery through a freizone-gateway instead of
  /// UnifiedPush. Registering one clears the other server-side; a device
  /// uses exactly one wake mechanism at a time.
  Future<void> setPushTarget({
    required DeviceCredentials creds,
    required String platform,
    required String token,
  }) async {
    final resp = await _signedRequest(
      'PUT',
      '/v1/devices/${creds.deviceId}/push-target',
      {'platform': platform, 'token': token},
      creds,
    );
    _checkStatus(resp, {200});
  }

  /// Clears this device's push target.
  Future<void> clearPushTarget(DeviceCredentials creds) async {
    final resp = await _signedRequest(
      'PUT',
      '/v1/devices/${creds.deviceId}/push-target',
      {},
      creds,
    );
    _checkStatus(resp, {200});
  }

  // --- Prekeys ----------------------------------------------------------------

  Future<void> uploadPrekeys({
    required DeviceCredentials creds,
    DHIdentityCertDTO? dhIdentityCert,
    required SignedPrekeyDTO signedPrekey,
    List<OneTimePrekeyDTO> oneTimePrekeys = const [],
  }) async {
    final resp = await _signedRequest(
      'POST',
      '/v1/devices/${creds.deviceId}/prekeys',
      {
        if (dhIdentityCert != null) 'dh_identity_cert': dhIdentityCert.toJson(),
        'signed_prekey': signedPrekey.toJson(),
        if (oneTimePrekeys.isNotEmpty)
          'one_time_prekeys': oneTimePrekeys.map((k) => k.toJson()).toList(),
      },
      creds,
    );
    _checkStatus(resp, {200});
  }

  /// Non-destructive counterpart to [claimPrekeyBundle]: how many
  /// one-time prekeys this device's own pool has left, without consuming
  /// one -- used to decide whether to top up (see topUpOneTimePrekeysIfNeeded
  /// in app_session.dart).
  Future<int> getPrekeyStatus(DeviceCredentials creds) async {
    final resp = await _signedRequest(
      'GET',
      '/v1/devices/${creds.deviceId}/prekey-status',
      null,
      creds,
    );
    return PrekeyStatusResponse.fromJson(
      _decodeObject(resp, {200}),
    ).oneTimePrekeysRemaining;
  }

  /// Claims (and atomically consumes, if any remain) a one-time prekey
  /// from deviceId's bundle. Unauthenticated -- see docs/PROTOCOL.md's
  /// note on this endpoint's trust model.
  Future<PrekeyBundleResponse> claimPrekeyBundle(String deviceId) async {
    final resp = await _unauthedRequest(
      'POST',
      '/v1/devices/$deviceId/prekey-bundle',
      null,
    );
    return PrekeyBundleResponse.fromJson(_decodeObject(resp, {200}));
  }

  // --- Messages -----------------------------------------------------------

  Future<void> sendMessage({
    required DeviceCredentials creds,
    required String messageId,
    required String recipientDeviceId,
    required Map<String, dynamic> payload,
  }) async {
    final resp = await _signedRequest('POST', '/v1/messages', {
      'message_id': messageId,
      'recipient_device_id': recipientDeviceId,
      'payload': payload,
    }, creds);
    _checkStatus(resp, {202});
  }

  /// Posts an encrypted message directly to a peer's home server (which
  /// isn't this ApiClient's own [baseUrl] -- callers construct a second
  /// instance pointed at the peer's server for this), rather than the
  /// ordinary same-server [sendMessage] path. See docs/PROTOCOL.md §9:
  /// the peer's server has no local row for this device, so instead of
  /// [creds]/a device id it verifies a self-certifying bundle carried
  /// inline -- [rootPub], [senderAccountId], and a device certificate --
  /// and the request is signed with Signature-Key-Id set to this
  /// device's own base64 public key (from [cert]) rather than a
  /// registered device id, the same self-describing-key convention
  /// [freizone-gateway](https://github.com/behringer24/freizone-gateway)
  /// already uses.
  Future<void> sendFederatedMessage({
    required Uint8List devicePriv,
    required Uint8List rootPub,
    required String senderAccountId,
    required DeviceCertificate cert,
    required String messageId,
    required String recipientDeviceId,
    required Map<String, dynamic> payload,
  }) async {
    final body = {
      'sender_account_id': senderAccountId,
      'sender_root_pub_key': encodeB64(rootPub),
      'sender_device_cert': {
        'device_id': cert.deviceId,
        'device_pub_key': encodeB64(cert.devicePubKey),
        'issued_at': encodeTime(cert.issuedAt),
        'signature': encodeB64(cert.signature),
      },
      'recipient_device_id': recipientDeviceId,
      'message_id': messageId,
      'payload': payload,
    };
    final bodyBytes = Uint8List.fromList(utf8.encode(json.encode(body)));
    final keyId = encodeB64(cert.devicePubKey);
    final headers = core.signHTTPRequest(
      method: 'POST',
      path: '/v1/federation/messages',
      body: bodyBytes,
      deviceId: keyId,
      devicePriv: devicePriv,
    );
    final req = http.Request('POST', _uri('/v1/federation/messages'));
    req.headers['Content-Type'] = 'application/json';
    headers.forEach((key, value) => req.headers[key] = value);
    req.bodyBytes = bodyBytes;
    final resp = await http.Response.fromStream(await _http.send(req));
    _checkStatus(resp, {202});
  }

  Future<List<MessageResponse>> listMessages(DeviceCredentials creds) async {
    final resp = await _signedRequest('GET', '/v1/messages', null, creds);
    _checkStatus(resp, {200});
    final list = json.decode(resp.body) as List<dynamic>;
    return list
        .map((e) => MessageResponse.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteMessage(String messageId, DeviceCredentials creds) async {
    final resp = await _signedRequest(
      'DELETE',
      '/v1/messages/$messageId',
      null,
      creds,
    );
    _checkStatus(resp, {200});
  }

  // --- Server admin ---------------------------------------------------------

  /// Lists every registered account. Admin or moderator only -- a 403
  /// (surfaced as an [ApiException] with statusCode 403) means the caller
  /// has neither role, which is also how the app discovers this.
  Future<List<AdminAccountSummary>> listAccounts(
    DeviceCredentials creds,
  ) async {
    final resp = await _signedRequest('GET', '/v1/admin/accounts', null, creds);
    _checkStatus(resp, {200});
    final list = json.decode(resp.body) as List<dynamic>;
    return list
        .map((e) => AdminAccountSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Grants or revokes admin/moderator status. Admin only.
  Future<void> setAccountRole(
    DeviceCredentials creds,
    String accountId,
    String role,
  ) async {
    final resp = await _signedRequest(
      'POST',
      '/v1/admin/accounts/$accountId/role',
      {'role': role},
      creds,
    );
    _checkStatus(resp, {200});
  }

  /// Temporarily disables an account -- it can no longer authenticate.
  /// Admin only.
  Future<void> blockAccount(DeviceCredentials creds, String accountId) async {
    final resp = await _signedRequest(
      'POST',
      '/v1/admin/accounts/$accountId/block',
      null,
      creds,
    );
    _checkStatus(resp, {200});
  }

  /// Restores a previously blocked account. Admin only.
  Future<void> unblockAccount(DeviceCredentials creds, String accountId) async {
    final resp = await _signedRequest(
      'POST',
      '/v1/admin/accounts/$accountId/unblock',
      null,
      creds,
    );
    _checkStatus(resp, {200});
  }

  /// Permanently deletes an account. Admin only, irreversible.
  Future<void> deleteAccount(DeviceCredentials creds, String accountId) async {
    final resp = await _signedRequest(
      'DELETE',
      '/v1/admin/accounts/$accountId',
      null,
      creds,
    );
    _checkStatus(resp, {200});
  }

  /// Permanently deletes the caller's own account server-side -- there is
  /// no path back to the same identity afterward, on this or any other
  /// device. The server derives the actual target from the request's
  /// signature, never from [accountId] alone (see docs/PROTOCOL.md's
  /// entry for this endpoint), so this can never be pointed at a
  /// different account no matter what's passed here.
  Future<void> deleteOwnAccount(DeviceCredentials creds, String accountId) async {
    final resp = await _signedRequest(
      'DELETE',
      '/v1/accounts/$accountId',
      null,
      creds,
    );
    _checkStatus(resp, {200});
  }

  /// Returns the current registration policy ("open", "invite", or
  /// "closed"). Admin or moderator.
  Future<String> getRegistrationPolicy(DeviceCredentials creds) async {
    final resp = await _signedRequest(
      'GET',
      '/v1/admin/registration-policy',
      null,
      creds,
    );
    return _decodeObject(resp, {200})['policy'] as String;
  }

  /// Changes the registration policy (persisted -- survives a restart).
  /// Admin only.
  Future<void> setRegistrationPolicy(
    DeviceCredentials creds,
    String policy,
  ) async {
    final resp = await _signedRequest('PUT', '/v1/admin/registration-policy', {
      'policy': policy,
    }, creds);
    _checkStatus(resp, {200});
  }

  /// Returns whether inbound federation is currently enabled. Admin or
  /// moderator.
  Future<bool> getFederationEnabled(DeviceCredentials creds) async {
    final resp = await _signedRequest('GET', '/v1/admin/federation', null, creds);
    return _decodeObject(resp, {200})['enabled'] as bool;
  }

  /// Turns inbound federation on/off (persisted -- survives a restart).
  /// Admin only.
  Future<void> setFederationEnabled(
    DeviceCredentials creds,
    bool enabled,
  ) async {
    final resp = await _signedRequest('PUT', '/v1/admin/federation', {
      'enabled': enabled,
    }, creds);
    _checkStatus(resp, {200});
  }

  /// Mints a single-use invite code. Admin or moderator only -- matches
  /// the server-side gate in handleCreateInvite.
  Future<CreateInviteResponse> createInvite(DeviceCredentials creds) async {
    final resp = await _signedRequest('POST', '/v1/admin/invites', {}, creds);
    return CreateInviteResponse.fromJson(_decodeObject(resp, {201}));
  }

  /// Builds (but does not send) a signed GET request for the long-lived
  /// SSE stream endpoint -- used by SseClient, which needs the raw
  /// streamed response rather than a buffered http.Response.
  http.Request buildStreamRequest(DeviceCredentials creds) {
    final headers = core.signHTTPRequest(
      method: 'GET',
      path: '/v1/messages/stream',
      deviceId: creds.deviceId,
      devicePriv: creds.devicePriv,
    );
    final req = http.Request('GET', _uri('/v1/messages/stream'));
    headers.forEach((key, value) => req.headers[key] = value);
    return req;
  }

  void close() => _http.close();
}
