// Owns everything that used to live inside a single ChatScreen: the Go
// core, the API client, one long-lived SSE stream, prekey upload, X3DH
// session establishment, and encrypt/decrypt -- for the lifetime of the
// app, independent of which screen is on screen. This is what lets the
// chat list update (new conversation, last-message preview, ordering)
// while a different conversation -- or no conversation -- is open,
// which a per-screen SSE connection cannot do.
//
// Deliberately a plain ChangeNotifier, not a state-management package:
// screens rebuild via ListenableBuilder, the same primitive already
// used everywhere else in this codebase.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../ffi/freizone_core.dart';
import '../ffi/models.dart';
import '../net/api_client.dart';
import '../net/dto.dart';
import '../net/sse_client.dart';
import '../push/push_manager.dart';
import '../util/address_format.dart';
import 'conversation.dart';
import 'local_state.dart';

/// How many one-time prekeys to generate and upload at once, mirroring
/// cmd/devclient's defaultOneTimePrekeyBatch.
const _oneTimePrekeyBatch = 10;

class AppSession extends ChangeNotifier {
  AppSession(this.state) {
    api = ApiClient(baseUrl: state.server, core: core);
  }

  final AppState state;
  final FreizoneCore core = FreizoneCore();
  late final ApiClient api;
  SseClient? _sse;

  bool prekeysReady = false;
  String? lastError;

  /// True once a push-registration attempt has found no UnifiedPush
  /// distributor installed. Consumed (reset to false) by whichever
  /// screen shows the one-time hint about it -- chat keeps working via
  /// SSE regardless.
  bool pushDistributorMissing = false;

  /// This device's own server role ("admin"/"moderator"), or null if it
  /// has neither -- in which case the admin area should be hidden
  /// entirely. Deliberately in-memory only (not persisted): re-derived
  /// from the server on every refresh so a promotion/demotion made
  /// elsewhere is picked up rather than trusting a stale local copy.
  String? myRole;

  /// The most recently fetched account list (admin/moderator only),
  /// cached so the admin screen has something to show immediately while
  /// a fresh fetch is in flight.
  List<AdminAccountSummary> adminAccounts = [];

  /// The server's current registration policy ("open"/"invite"/"closed"),
  /// fetched via the public GET /v1/server-status -- unlike [myRole]'s
  /// admin-only source, this works for every role, which is what lets a
  /// plain "user" account still see the Invite action on an open server.
  String? registrationPolicy;

  /// Refreshes [registrationPolicy] from the server. Call once after
  /// [init] and again whenever the chat list is shown, so a policy
  /// change made elsewhere is picked up.
  Future<void> refreshRegistrationPolicy() async {
    try {
      final status = await api.getServerStatus();
      registrationPolicy = status.registrationPolicy;
    } catch (e) {
      lastError = 'checking registration policy failed: $e';
    }
    notifyListeners();
  }

  /// Refreshes [myRole] and [adminAccounts] from the server. A 403 means
  /// this device is neither admin nor moderator -- not an error, just
  /// the answer. Call once after [init] and again whenever the admin
  /// area is opened, so a role change elsewhere in the meantime is seen.
  Future<void> refreshMyRole() async {
    try {
      final accounts = await api.listAccounts(state.credentials);
      adminAccounts = accounts;
      AdminAccountSummary? mine;
      for (final acc in accounts) {
        if (acc.id == state.accountId) {
          mine = acc;
          break;
        }
      }
      myRole = mine?.role;
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        myRole = null;
        adminAccounts = [];
      } else {
        lastError = 'checking admin role failed: $e';
      }
    } catch (e) {
      lastError = 'checking admin role failed: $e';
    }
    notifyListeners();
  }

  /// Grants or revokes admin/moderator status. Admin only (enforced
  /// server-side regardless of what this device believes its own role
  /// is). Refreshes the account list afterwards.
  Future<void> setAccountRole(String accountId, String role) async {
    await api.setAccountRole(state.credentials, accountId, role);
    await refreshMyRole();
  }

  /// Temporarily disables an account. Admin only.
  Future<void> blockAccount(String accountId) async {
    await api.blockAccount(state.credentials, accountId);
    await refreshMyRole();
  }

  /// Restores a previously blocked account. Admin only.
  Future<void> unblockAccount(String accountId) async {
    await api.unblockAccount(state.credentials, accountId);
    await refreshMyRole();
  }

  /// Permanently deletes an account. Admin only, irreversible.
  Future<void> deleteAccount(String accountId) async {
    await api.deleteAccount(state.credentials, accountId);
    await refreshMyRole();
  }

  /// Returns the current registration policy ("open"/"invite"/"closed").
  Future<String> getRegistrationPolicy() => api.getRegistrationPolicy(state.credentials);

  /// Changes the registration policy (persisted server-side). Admin only.
  Future<void> setRegistrationPolicy(String policy) => api.setRegistrationPolicy(state.credentials, policy);

  /// Mints a single-use invite code. Admin or moderator only.
  Future<CreateInviteResponse> createInvite() => api.createInvite(state.credentials);

  /// Conversations sorted newest-activity-first, for the chat list.
  List<Conversation> get conversations {
    final list = state.conversations.values.toList();
    list.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return list;
  }

  Conversation? conversation(String peerAccountId) => state.conversations[peerAccountId];

  /// True if any conversation in this account has an unread message --
  /// drives the account switcher's notification dot.
  bool get hasAnyUnread => state.conversations.values.any((c) => c.hasUnread);

  /// The peer whose ChatScreen is currently on screen, if any -- an
  /// incoming message from them is never marked unread, since the user
  /// is already looking at it (see _handleIncoming).
  String? _openConversationPeerId;

  /// Call when a ChatScreen for peerAccountId opens: clears its unread
  /// flag and remembers it as "currently open" for _handleIncoming.
  Future<void> enterConversation(String peerAccountId) async {
    _openConversationPeerId = peerAccountId;
    final convo = state.conversations[peerAccountId];
    if (convo == null || !convo.hasUnread) return;
    convo.hasUnread = false;
    await LocalStateStore.saveProfile(state);
    // If that was the last unread conversation, clear this account's
    // "new message(s)" notification too, so its launcher-icon badge
    // (which Android derives from active notifications) goes away
    // rather than lingering after everything's been read.
    if (!hasAnyUnread) unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Call when that ChatScreen closes.
  void leaveConversation(String peerAccountId) {
    if (_openConversationPeerId == peerAccountId) _openConversationPeerId = null;
  }

  /// Uploads prekeys if this is the first run, then opens the live
  /// message stream. Call once, right after construction.
  Future<void> init() async {
    try {
      if (state.signedPrekeyPub == null) {
        await _uploadPrekeys();
      }
      prekeysReady = true;
      notifyListeners();
      _startStream();
      unawaited(refreshMyRole());
      unawaited(refreshRegistrationPolicy());
      unawaited(_registerPush());
    } catch (e) {
      lastError = 'prekey upload failed: $e';
      notifyListeners();
    }
  }

  Future<void> _registerPush() async {
    try {
      final hasDistributor = await registerForPush(api, state.accountId);
      if (!hasDistributor) {
        pushDistributorMissing = true;
        notifyListeners();
      }
    } catch (e) {
      lastError = 'push registration failed: $e';
      notifyListeners();
    }
  }

  Future<void> _uploadPrekeys() async {
    final now = DateTime.now().toUtc();

    DHIdentityCertDTO? dhCertDto;
    if (state.dhIdentityPub == null) {
      final dh = core.generateX25519KeyPair();
      final cert = core.signDHIdentityCertificate(
        accountId: state.accountId,
        deviceId: state.deviceId,
        dhPub: dh.pub,
        issuedAt: now,
        devicePriv: state.devicePriv,
      );
      state.dhIdentityPub = dh.pub;
      state.dhIdentityPriv = dh.priv;
      dhCertDto = DHIdentityCertDTO(dhPubKey: cert.dhPubKey, issuedAt: cert.issuedAt, signature: cert.signature);
    }

    final spk = core.generateX25519KeyPair();
    final spkId = state.nextSignedPrekeyId;
    state.nextSignedPrekeyId++;
    final spkCert = core.signSignedPrekeyCertificate(
      accountId: state.accountId,
      deviceId: state.deviceId,
      keyId: spkId,
      dhIdentityPub: state.dhIdentityPub!,
      prekeyPub: spk.pub,
      issuedAt: now,
      devicePriv: state.devicePriv,
    );
    state.signedPrekeyId = spkId;
    state.signedPrekeyPub = spk.pub;
    state.signedPrekeyPriv = spk.priv;

    final otpkDtos = <OneTimePrekeyDTO>[];
    for (var i = 0; i < _oneTimePrekeyBatch; i++) {
      final kp = core.generateX25519KeyPair();
      final keyId = state.nextOtpkKeyId;
      state.nextOtpkKeyId++;
      state.oneTimePrekeys[keyId] = OneTimePrekeyState(pub: kp.pub, priv: kp.priv);
      otpkDtos.add(OneTimePrekeyDTO(keyId: keyId, pubKey: kp.pub));
    }

    await api.uploadPrekeys(
      creds: state.credentials,
      dhIdentityCert: dhCertDto,
      signedPrekey: SignedPrekeyDTO(
        keyId: spkCert.keyId,
        dhIdentityPubKey: spkCert.dhIdentityPubKey,
        pubKey: spkCert.prekeyPubKey,
        issuedAt: spkCert.issuedAt,
        signature: spkCert.signature,
      ),
      oneTimePrekeys: otpkDtos,
    );
    await LocalStateStore.saveProfile(state);
  }

  void _startStream() {
    _sse = SseClient(apiClient: api, creds: state.credentials);
    unawaited(_sse!.connect(
      onMessage: _handleIncoming,
      onError: (e) {
        lastError = 'stream error: $e';
        notifyListeners();
      },
    ));
  }

  Future<void> _handleIncoming(MessageResponse msg) async {
    try {
      final parsed = core.parseEnvelope(msg.payload);

      var session = state.sessions[msg.senderAccountId];
      if (session == null) {
        final initial = parsed.initial;
        if (initial == null) return; // no session and no X3DH material to start one -- drop.

        Uint8List? otpkPriv;
        final otpkId = initial.oneTimePrekeyId;
        if (otpkId != null && state.oneTimePrekeys.containsKey(otpkId)) {
          otpkPriv = state.oneTimePrekeys[otpkId]!.priv;
          state.oneTimePrekeys.remove(otpkId);
        }
        session = core.respondToSession(
          localDhIdentityPriv: state.dhIdentityPriv!,
          signedPrekeyPriv: state.signedPrekeyPriv!,
          oneTimePrekeyPriv: otpkPriv,
          initial: initial,
        );
      }

      final dec = core.sessionDecrypt(session: session, header: parsed.header, ciphertext: parsed.ciphertext);
      state.sessions[msg.senderAccountId] = dec.session;
      final text = utf8.decode(dec.plaintext);
      final now = DateTime.now().toUtc();

      final convo = state.conversations.putIfAbsent(
        msg.senderAccountId,
        () => Conversation(peerAccountId: msg.senderAccountId),
      );
      convo.messages.add(StoredMessage(text: text, mine: false, timestamp: now));
      convo.lastActivityAt = now;
      if (msg.senderAccountId != _openConversationPeerId) {
        convo.hasUnread = true;
        // This is the live (app-open) delivery path -- a push wake's
        // _onMessage already shows this same notification for the
        // background case. Without this, the launcher icon's badge
        // (which Android derives from active notifications, not
        // anything drawn in-app) would never appear for a message that
        // happened to arrive while the app was in the foreground.
        unawaited(showMessageNotification(state.accountId));
      }

      await LocalStateStore.saveProfile(state);
      unawaited(api.deleteMessage(msg.messageId, state.credentials));

      lastError = null;
      notifyListeners();
    } catch (e) {
      lastError = 'decrypt error: $e';
      notifyListeners();
    }
  }

  /// Resolves peerIdOrPrefix's true account id and verified active device
  /// -- independently verifying the full self-certifying chain, per
  /// docs/PROTOCOL.md, no trust in the server required. peerIdOrPrefix may
  /// be either the full canonical id or just its first
  /// [accountIdPrefixLength] characters (docs/PROTOCOL.md's id-prefix
  /// uniqueness note) -- either way, the returned id is always the true
  /// full one, verified against the returned device's key chain, never
  /// just echoed back from whatever shorthand was looked up with.
  Future<(String accountId, DeviceResponse device)> _resolvePeerDevice(String peerIdOrPrefix) async {
    final acc = await api.getAccount(peerIdOrPrefix);
    if (!core.verifyAddressId(acc.id, acc.rootPubKey)) {
      throw StateError('peer account id does not match its root key');
    }

    for (final d in acc.devices) {
      if (d.status != 'active') continue;
      final cert = DeviceCertificate(
        accountId: acc.id,
        deviceId: d.deviceId,
        devicePubKey: d.devicePubKey,
        issuedAt: d.issuedAt,
        signature: d.signature,
      );
      if (core.verifyDeviceCertificate(cert, acc.rootPubKey)) {
        return (acc.id, d);
      }
    }
    throw StateError('no verifiable active device found for $peerIdOrPrefix');
  }

  /// Resolves and creates, or returns the already-resolved, Conversation
  /// with peerAccountId. peerAccountId is normalized first, so a
  /// dash-grouped or phone-dictated id ("k5x9 p2qa n7f3...") resolves the
  /// same as the canonical form -- and may be just the first
  /// [accountIdPrefixLength] characters (unique per server, see
  /// docs/PROTOCOL.md), in which case an already-known conversation
  /// resolves purely locally, with no network round trip. If displayName
  /// is given and this is a new conversation, it's set as the initial
  /// local alias.
  Future<Conversation> startConversation(String peerAccountId, {String? displayName}) async {
    final normalized = normalizeAccountId(peerAccountId);

    final existing = state.conversations[normalized];
    if (existing != null && existing.peerDeviceId != null) return existing;

    if (normalized.length == accountIdPrefixLength) {
      for (final convo in state.conversations.values) {
        if (convo.peerDeviceId != null && convo.peerAccountId.startsWith(normalized)) return convo;
      }
    }

    final (resolvedId, verified) = await _resolvePeerDevice(normalized);

    final convo = state.conversations.putIfAbsent(resolvedId, () => Conversation(peerAccountId: resolvedId));
    convo.peerDeviceId = verified.deviceId;
    convo.peerDevicePubKey = verified.devicePubKey;
    if (convo.displayName == null && displayName != null && displayName.trim().isNotEmpty) {
      convo.displayName = displayName.trim();
    }
    await LocalStateStore.saveProfile(state);
    notifyListeners();
    return convo;
  }

  /// Sets, changes, or (name == null / blank) removes a conversation's
  /// local alias. Purely local -- never sent to the peer or the server.
  Future<void> setDisplayName(String peerAccountId, String? name) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    convo.displayName = (name == null || name.trim().isEmpty) ? null : name.trim();
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  /// Empties peerAccountId's message history, keeping the conversation
  /// itself (resolved peer device, alias) -- purely local, since the
  /// server never stored the history in the first place.
  Future<void> clearConversation(String peerAccountId) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    convo.messages.clear();
    final hadUnread = convo.hasUnread;
    convo.hasUnread = false;
    await LocalStateStore.saveProfile(state);
    if (hadUnread && !hasAnyUnread) unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Removes peerAccountId's conversation entirely -- history, the
  /// resolved peer device, and its ratchet session, so a later chat with
  /// them starts genuinely fresh (a new X3DH handshake) rather than
  /// silently continuing a session behind now-invisible history. Purely
  /// local: the account itself is untouched on the server.
  Future<void> deleteConversation(String peerAccountId) async {
    final removed = state.conversations.remove(peerAccountId);
    if (removed == null) return;
    state.sessions.remove(peerAccountId);
    if (_openConversationPeerId == peerAccountId) _openConversationPeerId = null;
    await LocalStateStore.saveProfile(state);
    if (removed.hasUnread && !hasAnyUnread) unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Returns the existing session with a conversation's peer, or
  /// establishes a new one as X3DH initiator by claiming their prekey
  /// bundle.
  Future<(RatchetSessionJson, InitialMessage?)> _getOrCreateCryptoSession(Conversation convo) async {
    final existing = state.sessions[convo.peerAccountId];
    if (existing != null) return (existing, null);

    final bundle = await api.claimPrekeyBundle(convo.peerDeviceId!);

    final dhCert = DHIdentityCertificate(
      accountId: convo.peerAccountId,
      deviceId: convo.peerDeviceId!,
      dhPubKey: bundle.dhIdentityPubKey,
      issuedAt: bundle.dhIdentityCert.issuedAt,
      signature: bundle.dhIdentityCert.signature,
    );
    if (!core.verifyDHIdentityCertificate(dhCert, convo.peerDevicePubKey!)) {
      throw StateError('invalid dh identity certificate');
    }

    final spkCert = SignedPrekeyCertificate(
      accountId: convo.peerAccountId,
      deviceId: convo.peerDeviceId!,
      keyId: bundle.signedPrekey.keyId,
      dhIdentityPubKey: bundle.signedPrekey.dhIdentityPubKey,
      prekeyPubKey: bundle.signedPrekey.pubKey,
      issuedAt: bundle.signedPrekey.issuedAt,
      signature: bundle.signedPrekey.signature,
    );
    if (!core.verifySignedPrekeyCertificate(spkCert, convo.peerDevicePubKey!)) {
      throw StateError('invalid signed prekey certificate');
    }
    if (!listEquals(bundle.signedPrekey.dhIdentityPubKey, bundle.dhIdentityPubKey)) {
      throw StateError('signed prekey is not bound to the claimed dh identity key');
    }

    final remote = RemoteBundle(
      dhIdentityPub: bundle.dhIdentityPubKey,
      signedPrekeyId: bundle.signedPrekey.keyId,
      signedPrekeyPub: bundle.signedPrekey.pubKey,
      oneTimePrekeyId: bundle.oneTimePrekey?.keyId,
      oneTimePrekeyPub: bundle.oneTimePrekey?.pubKey,
    );
    final result = core.initiateSession(localDhIdentityPriv: state.dhIdentityPriv!, remote: remote);
    state.sessions[convo.peerAccountId] = result.session;
    return (result.session, result.initial);
  }

  /// Encrypts and sends text to peerAccountId's conversation, appending
  /// it to the persisted history. Throws on failure -- the calling
  /// screen decides how to surface that (e.g. a SnackBar).
  Future<void> sendMessage(String peerAccountId, String text) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) {
      throw StateError('no conversation for $peerAccountId');
    }
    if (convo.peerDeviceId == null) {
      // A conversation that only ever received messages (never started
      // via startConversation) has no resolved peer device yet -- resolve
      // it now, lazily, so replying to whoever messaged first works.
      final (_, verified) = await _resolvePeerDevice(peerAccountId);
      convo.peerDeviceId = verified.deviceId;
      convo.peerDevicePubKey = verified.devicePubKey;
      await LocalStateStore.saveProfile(state);
    }

    final (session, initial) = await _getOrCreateCryptoSession(convo);
    final enc = core.sessionEncrypt(session: session, plaintext: Uint8List.fromList(utf8.encode(text)));
    state.sessions[peerAccountId] = enc.session;

    final payload = core.buildEnvelope(initial: initial, header: enc.header, ciphertext: enc.ciphertext);
    await api.sendMessage(
      creds: state.credentials,
      messageId: _randomHex(16),
      recipientDeviceId: convo.peerDeviceId!,
      payload: payload,
    );

    final now = DateTime.now().toUtc();
    convo.messages.add(StoredMessage(text: text, mine: true, timestamp: now));
    convo.lastActivityAt = now;
    await LocalStateStore.saveProfile(state);

    lastError = null;
    notifyListeners();
  }

  String _randomHex(int byteLen) {
    final rnd = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < byteLen; i++) {
      buf.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  @override
  void dispose() {
    _sse?.close();
    api.close();
    super.dispose();
  }
}
