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
  String toString() => 'ApiException($statusCode${code != null ? ', $code' : ''}): $message';
}

class ApiClient {
  ApiClient({required this.baseUrl, required this.core, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final String baseUrl;
  final FreizoneCore core;
  final http.Client _http;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Never _throwError(http.Response resp) {
    try {
      final body = json.decode(resp.body) as Map<String, dynamic>;
      final err = body['error'] as Map<String, dynamic>?;
      throw ApiException(resp.statusCode, err?['code'] as String?, err?['message'] as String? ?? resp.body);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(resp.statusCode, null, resp.body);
    }
  }

  Map<String, dynamic> _decodeObject(http.Response resp, Set<int> okStatuses) {
    if (!okStatuses.contains(resp.statusCode)) _throwError(resp);
    if (resp.body.isEmpty) return const {};
    return json.decode(resp.body) as Map<String, dynamic>;
  }

  void _checkStatus(http.Response resp, Set<int> okStatuses) {
    if (!okStatuses.contains(resp.statusCode)) _throwError(resp);
  }

  Future<http.Response> _unauthedRequest(String method, String path, Map<String, dynamic>? body) async {
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
    final bodyBytes = body == null ? Uint8List(0) : Uint8List.fromList(utf8.encode(json.encode(body)));
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
        if (oneTimePrekeys.isNotEmpty) 'one_time_prekeys': oneTimePrekeys.map((k) => k.toJson()).toList(),
      },
      creds,
    );
    _checkStatus(resp, {200});
  }

  /// Claims (and atomically consumes, if any remain) a one-time prekey
  /// from deviceId's bundle. Unauthenticated -- see docs/PROTOCOL.md's
  /// note on this endpoint's trust model.
  Future<PrekeyBundleResponse> claimPrekeyBundle(String deviceId) async {
    final resp = await _unauthedRequest('POST', '/v1/devices/$deviceId/prekey-bundle', null);
    return PrekeyBundleResponse.fromJson(_decodeObject(resp, {200}));
  }

  // --- Messages -----------------------------------------------------------

  Future<void> sendMessage({
    required DeviceCredentials creds,
    required String messageId,
    required String recipientDeviceId,
    required Map<String, dynamic> payload,
  }) async {
    final resp = await _signedRequest(
      'POST',
      '/v1/messages',
      {'message_id': messageId, 'recipient_device_id': recipientDeviceId, 'payload': payload},
      creds,
    );
    _checkStatus(resp, {202});
  }

  Future<List<MessageResponse>> listMessages(DeviceCredentials creds) async {
    final resp = await _signedRequest('GET', '/v1/messages', null, creds);
    _checkStatus(resp, {200});
    final list = json.decode(resp.body) as List<dynamic>;
    return list.map((e) => MessageResponse.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> deleteMessage(String messageId, DeviceCredentials creds) async {
    final resp = await _signedRequest('DELETE', '/v1/messages/$messageId', null, creds);
    _checkStatus(resp, {200});
  }

  // --- Server admin ---------------------------------------------------------

  /// Lists every registered account. Admin or moderator only -- a 403
  /// (surfaced as an [ApiException] with statusCode 403) means the caller
  /// has neither role, which is also how the app discovers this.
  Future<List<AdminAccountSummary>> listAccounts(DeviceCredentials creds) async {
    final resp = await _signedRequest('GET', '/v1/admin/accounts', null, creds);
    _checkStatus(resp, {200});
    final list = json.decode(resp.body) as List<dynamic>;
    return list.map((e) => AdminAccountSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Grants or revokes admin/moderator status. Admin only.
  Future<void> setAccountRole(DeviceCredentials creds, String accountId, String role) async {
    final resp = await _signedRequest('POST', '/v1/admin/accounts/$accountId/role', {'role': role}, creds);
    _checkStatus(resp, {200});
  }

  /// Temporarily disables an account -- it can no longer authenticate.
  /// Admin only.
  Future<void> blockAccount(DeviceCredentials creds, String accountId) async {
    final resp = await _signedRequest('POST', '/v1/admin/accounts/$accountId/block', null, creds);
    _checkStatus(resp, {200});
  }

  /// Restores a previously blocked account. Admin only.
  Future<void> unblockAccount(DeviceCredentials creds, String accountId) async {
    final resp = await _signedRequest('POST', '/v1/admin/accounts/$accountId/unblock', null, creds);
    _checkStatus(resp, {200});
  }

  /// Permanently deletes an account. Admin only, irreversible.
  Future<void> deleteAccount(DeviceCredentials creds, String accountId) async {
    final resp = await _signedRequest('DELETE', '/v1/admin/accounts/$accountId', null, creds);
    _checkStatus(resp, {200});
  }

  /// Returns the current registration policy ("open", "invite", or
  /// "closed"). Admin or moderator.
  Future<String> getRegistrationPolicy(DeviceCredentials creds) async {
    final resp = await _signedRequest('GET', '/v1/admin/registration-policy', null, creds);
    return _decodeObject(resp, {200})['policy'] as String;
  }

  /// Changes the registration policy (persisted -- survives a restart).
  /// Admin only.
  Future<void> setRegistrationPolicy(DeviceCredentials creds, String policy) async {
    final resp = await _signedRequest('PUT', '/v1/admin/registration-policy', {'policy': policy}, creds);
    _checkStatus(resp, {200});
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
