// Idiomatic Dart wrapper around the Go crypto/protocol core
// (native/core.go + logic.go in this repo). Every method here corresponds
// 1:1 to one cgo-exported function; see that file for the underlying
// Go-side request/response shapes this class serializes to/from JSON.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'core_models.dart';
import 'freizone_core_bindings.dart';
import 'freizone_core_exception.dart';
import 'models.dart';

class FreizoneCore {
  FreizoneCore._(this._bindings, this.libraryPath);

  /// [libraryPath] is only for host tests -- see
  /// [FreizoneCoreBindings.open]. Production callers use `FreizoneCore()`.
  factory FreizoneCore({String? libraryPath}) =>
      FreizoneCore._(FreizoneCoreBindings.open(path: libraryPath), libraryPath);

  final FreizoneCoreBindings _bindings;

  /// The path this instance was opened from, or null when the platform decided.
  ///
  /// Kept because an isolate cannot be handed a [FreizoneCore] -- it holds
  /// native pointers -- so anything opening the core again inside one has to be
  /// told the same way this instance was. Forgetting that is invisible on
  /// Android, where the library is found by name either way, and fails only on
  /// a development host.
  final String? libraryPath;

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
  Identity restoreIdentityFromSeed(List<String> words) => Identity.fromJson(
    _call(_bindings.restoreIdentityFromSeed, {'words': words}),
  );

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
  Uint8List decryptBlob({
    required Uint8List key,
    required Uint8List ciphertext,
  }) {
    final data = _call(_bindings.decryptBlob, {
      'key': encodeB64(key),
      'ciphertext': encodeB64(ciphertext),
    });
    return decodeB64(data['plaintext'] as String);
  }

  // --- Server attestation (SRV-19 / APP-22) --------------------------------

  /// Verifies an opaque attestation token (ServerStatus.attestation) against
  /// [domain] -- the server it is actually being shown for, not necessarily
  /// the one it names. Returns null for anything that does not hold up:
  /// malformed, signed by an untrusted issuer, for a different domain, or
  /// expired. A null result must be rendered as "nothing configured", never
  /// as a warning -- see docs/design/22-verified-badge.md.
  AttestationInfo? verifyAttestation(String token, String domain) {
    final data = _call(_bindings.verifyAttestation, {
      'token': token,
      'domain': domain,
    });
    if (data['valid'] != true) return null;
    return AttestationInfo.fromJson(data);
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

  // --- shared client core (SRV-23) -----------------------------------------
  //
  // Stateful, unlike everything above: [coreOpen] returns a handle standing in
  // for an open account database, and the rest operate on it until
  // [coreClose]. The state, the persistence and the protocol decisions live in
  // freizone-server's pkg/client; this is only the typed way across.

  /// Opens (creating and migrating if needed) the account database at [path]
  /// and returns its handle.
  int coreOpen(String path) =>
      _call(_bindings.coreOpen, {'path': path})['handle'] as int;

  /// Closes a handle and stops anything running against it. Closing one that is
  /// already gone is a no-op, so a teardown racing a hot restart need not be
  /// careful.
  void coreClose(int handle) => _call(_bindings.coreClose, {'handle': handle});

  /// Hands this account's key material to the core, which is what lets it sign
  /// its own requests and hold its own stream before the app's state layer has
  /// migrated into it.
  /// Hands the core everything it needs to decrypt, not only to sign requests
  /// with: [dhIdentityPriv] and [signedPrekeyPriv] are what [sessionDecrypt]'s
  /// Go-side counterpart (HandleIncoming) opens a first-contact envelope with,
  /// so leaving them out is not "less identity handed over", it is a core that
  /// fails every decrypt with "reading own identity key" the moment a real
  /// envelope arrives -- which is silent right up until it is not, since a
  /// stream-only handle never touched them before this call carried them.
  void coreSetIdentity({
    required int handle,
    required String accountId,
    required String server,
    required Uint8List rootPub,
    required Uint8List rootPriv,
    required String deviceId,
    required Uint8List devicePub,
    required Uint8List devicePriv,
    Uint8List? dhIdentityPub,
    Uint8List? dhIdentityPriv,
    int signedPrekeyId = 0,
    Uint8List? signedPrekeyPub,
    Uint8List? signedPrekeyPriv,
    int nextSignedPrekeyId = 0,
    int nextOtpkKeyId = 0,
    bool recoveryBackupDone = false,
    String? pushMechanism,
  }) => _call(_bindings.coreSetIdentity, {
    'handle': handle,
    'account_id': accountId,
    'server': server,
    'root_pub': encodeB64(rootPub),
    'root_priv': encodeB64(rootPriv),
    'device_id': deviceId,
    'device_pub': encodeB64(devicePub),
    'device_priv': encodeB64(devicePriv),
    'dh_identity_pub': ?(dhIdentityPub == null ? null : encodeB64(dhIdentityPub)),
    'dh_identity_priv': ?(dhIdentityPriv == null
        ? null
        : encodeB64(dhIdentityPriv)),
    if (signedPrekeyId != 0) 'signed_prekey_id': signedPrekeyId,
    'signed_prekey_pub': ?(signedPrekeyPub == null
        ? null
        : encodeB64(signedPrekeyPub)),
    'signed_prekey_priv': ?(signedPrekeyPriv == null
        ? null
        : encodeB64(signedPrekeyPriv)),
    if (nextSignedPrekeyId != 0) 'next_signed_prekey_id': nextSignedPrekeyId,
    if (nextOtpkKeyId != 0) 'next_otpk_key_id': nextOtpkKeyId,
    if (recoveryBackupDone) 'recovery_backup_done': true,
    'push_mechanism': ?pushMechanism,
  });

  /// Opens the message stream. Starting one already running is a no-op: a
  /// second subscriber slot on the server would stop a backgrounded app getting
  /// push wakes.
  void coreStreamStart(int handle) =>
      _call(_bindings.coreStreamStart, {'handle': handle});

  /// Closes the stream and releases this device's subscriber slot, so a message
  /// arriving afterwards triggers a push wake instead of being delivered into a
  /// stream nobody is reading.
  void coreStreamStop(int handle) =>
      _call(_bindings.coreStreamStop, {'handle': handle});

  /// Waits up to [timeoutMs] for stream activity and returns everything
  /// buffered behind it in one go.
  ///
  /// **Blocks.** Call it from an isolate only -- `CoreStream` in
  /// lib/net/core_stream.dart owns that loop. A batch rather than one event per
  /// call because an FFI crossing per message is pure overhead exactly when a
  /// reconnect has just delivered a backlog.
  ///
  /// Returns the raw envelope rather than a typed result on purpose: the typed
  /// form needs [MessageResponse] from lib/net/, and models.dart is deliberately
  /// the leaf of the dependency order that lib/net/ builds on. The stream layer
  /// owns the stream's types.
  Map<String, dynamic> corePoll({
    required int handle,
    required int timeoutMs,
  }) => _call(_bindings.corePoll, {'handle': handle, 'timeout_ms': timeoutMs});

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

  // --- the account API (SRV-23 stage 6) -------------------------------------
  //
  // Local reads first, then the raw pass-throughs for everything that blocks.
  // The raw ones take and return maps on purpose: they are what an isolate
  // entry point calls, and an isolate cannot be handed anything richer than
  // plain values (see state/core_account.dart).

  /// The chat list, peers and groups in one list ordered by one clock.
  List<ChatSummary> coreChats(int handle) =>
      _callList(_bindings.coreChats, {'handle': handle})
          .map((e) => ChatSummary.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);

  /// One chat's whole transcript, in arrival order.
  List<CoreMessage> coreMessages(int handle, String chatId) =>
      _callList(_bindings.coreMessages, {'handle': handle, 'chat_id': chatId})
          .map((e) => CoreMessage.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);

  GroupInfo coreGroupInfo(int handle, String groupId) => GroupInfo.fromJson(
    _call(_bindings.coreGroupInfo, {'handle': handle, 'group_id': groupId}),
  );

  void coreSetOpenChat(int handle, String chatId) =>
      _call(_bindings.coreSetOpenChat, {'handle': handle, 'chat_id': chatId});

  void coreBlockPeer(int handle, String accountId, String server) => _call(
    _bindings.coreBlockPeer,
    {'handle': handle, 'account_id': accountId, 'server': server},
  );

  void coreUnblockPeer(int handle, String accountId) => _call(
    _bindings.coreUnblockPeer,
    {'handle': handle, 'account_id': accountId},
  );

  void coreAcceptRequest(int handle, String accountId) => _call(
    _bindings.coreAcceptRequest,
    {'handle': handle, 'account_id': accountId},
  );

  void coreDeleteChat(int handle, String chatId) =>
      _call(_bindings.coreDeleteChat, {'handle': handle, 'chat_id': chatId});

  /// Blocking. Isolate only -- see state/core_account.dart.
  Map<String, dynamic> coreSendRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreSend, req);
  Map<String, dynamic> coreRetryRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreRetryMessage, req);
  Map<String, dynamic> coreMarkReadRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreMarkRead, req);
  Map<String, dynamic> coreStartConversationRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreStartConversation, req);
  Map<String, dynamic> coreAttachmentPathRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreAttachmentPath, req);
  Map<String, dynamic> coreMaintainRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreMaintain, req);
  Map<String, dynamic> coreResetSessionRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreResetSession, req);
  /// Blocking. Isolate only -- see state/core_account.dart.
  Map<String, dynamic> coreSyncRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreSync, req);
  Map<String, dynamic> coreGroupCreateRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreGroupCreate, req);
  Map<String, dynamic> coreGroupInviteRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreGroupInvite, req);
  Map<String, dynamic> coreGroupAcceptRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreGroupAccept, req);
  Map<String, dynamic> coreGroupSetRoleRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreGroupSetRole, req);
  Map<String, dynamic> coreGroupRemoveRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreGroupRemove, req);
  Map<String, dynamic> coreGroupLeaveRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreGroupLeave, req);
  Map<String, dynamic> coreGroupSetMetaRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreGroupSetMeta, req);
  Map<String, dynamic> coreGroupSyncRequestRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreGroupSyncRequest, req);
  Map<String, dynamic> coreForgetPeerRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreForgetPeer, req);
  Map<String, dynamic> coreSetReceiptsEnabledRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreSetReceiptsEnabled, req);
  Map<String, dynamic> coreGroupDissolveRaw(Map<String, dynamic> req) =>
      _call(_bindings.coreGroupDissolve, req);

  /// Like [_call] for the calls that answer with a JSON array rather than an
  /// object -- a list of chats, a transcript.
  ///
  /// Its own decode rather than a looser [_decodeEnvelope], so the failure mode
  /// stays sharp: a call answering the wrong shape says so here instead of
  /// silently producing an empty list.
  List<dynamic> _callList(
    Pointer<Utf8> Function(Pointer<Utf8>) fn,
    Map<String, dynamic> request,
  ) {
    final reqPtr = json.encode(request).toNativeUtf8();
    try {
      final resultPtr = fn(reqPtr);
      try {
        final env =
            json.decode(resultPtr.toDartString()) as Map<String, dynamic>;
        if (env['ok'] != true) {
          throw FreizoneCoreException(
            env['error'] as String? ?? 'unknown native core error',
            code: env['code'] as String?,
          );
        }
        final data = env['data'];
        if (data == null) return const [];
        if (data is! List) {
          throw FreizoneCoreException(
            'expected a list from the core, got ${data.runtimeType}',
          );
        }
        return data;
      } finally {
        _bindings.free(resultPtr);
      }
    } finally {
      malloc.free(reqPtr);
    }
  }
}
