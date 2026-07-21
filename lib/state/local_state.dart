// Persisted local identity and conversation state -- the Dart-side
// mirror of cmd/devclient's State (state.go) in freizone-server. Stored
// as one indented JSON file under the app's documents directory via
// path_provider.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../ffi/models.dart';
import '../net/api_client.dart';
import 'conversation.dart';

/// One uploaded one-time prekey's key pair, kept locally until it's
/// consumed by a peer (the server never says which one gets claimed).
class OneTimePrekeyState {
  OneTimePrekeyState({required this.pub, required this.priv});

  factory OneTimePrekeyState.fromJson(Map<String, dynamic> j) =>
      OneTimePrekeyState(
        pub: decodeB64(j['pub'] as String),
        priv: decodeB64(j['priv'] as String),
      );

  Map<String, dynamic> toJson() => {
    'pub': encodeB64(pub),
    'priv': encodeB64(priv),
  };

  final Uint8List pub;
  final Uint8List priv;
}

/// A peer blocked purely locally (see AppSession.setBlocked), snapshotted
/// at block time -- kept independent of Conversation so the block survives
/// AppSession.deleteConversation (which removes the Conversation but keeps
/// the ratchet session intact). Without this, deleting a blocked peer's
/// chat would silently un-block them the moment they wrote again, and
/// there'd be no conversation left to unblock them *from* either.
class BlockedPeer {
  BlockedPeer({required this.peerAccountId, this.peerServer, this.displayName});

  factory BlockedPeer.fromJson(Map<String, dynamic> j) => BlockedPeer(
    peerAccountId: j['peer_account_id'] as String,
    peerServer: j['peer_server'] as String?,
    displayName: j['display_name'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'peer_account_id': peerAccountId,
    if (peerServer != null) 'peer_server': peerServer,
    if (displayName != null) 'display_name': displayName,
  };

  final String peerAccountId;

  /// Snapshotted from the conversation at block time -- purely for
  /// display in the "Blocked contacts" list if the conversation itself
  /// is later deleted, never re-resolved.
  final String? peerServer;
  final String? displayName;
}

/// The app's entire local identity and conversation state for one
/// account.
class AppState {
  AppState({
    required this.server,
    required this.accountId,
    required this.rootPub,
    required this.rootPriv,
    required this.deviceId,
    required this.devicePub,
    required this.devicePriv,
    this.dhIdentityPub,
    this.dhIdentityPriv,
    this.signedPrekeyId = 0,
    this.signedPrekeyPub,
    this.signedPrekeyPriv,
    this.nextSignedPrekeyId = 0,
    this.nextOtpkKeyId = 0,
    Map<int, OneTimePrekeyState>? oneTimePrekeys,
    Map<String, RatchetSessionJson>? sessions,
    Map<String, Conversation>? conversations,
    Set<String>? knownPeerIds,
    Map<String, BlockedPeer>? blockedPeers,
  }) : oneTimePrekeys = oneTimePrekeys ?? {},
       sessions = sessions ?? {},
       conversations = conversations ?? {},
       knownPeerIds = knownPeerIds ?? {},
       blockedPeers = blockedPeers ?? {};

  factory AppState.fromJson(Map<String, dynamic> j) => AppState(
    server: j['server'] as String,
    accountId: j['account_id'] as String,
    rootPub: decodeB64(j['root_pub'] as String),
    rootPriv: decodeB64(j['root_priv'] as String),
    deviceId: j['device_id'] as String,
    devicePub: decodeB64(j['device_pub'] as String),
    devicePriv: decodeB64(j['device_priv'] as String),
    dhIdentityPub: j['dh_identity_pub'] == null
        ? null
        : decodeB64(j['dh_identity_pub'] as String),
    dhIdentityPriv: j['dh_identity_priv'] == null
        ? null
        : decodeB64(j['dh_identity_priv'] as String),
    signedPrekeyId: j['signed_prekey_id'] as int? ?? 0,
    signedPrekeyPub: j['signed_prekey_pub'] == null
        ? null
        : decodeB64(j['signed_prekey_pub'] as String),
    signedPrekeyPriv: j['signed_prekey_priv'] == null
        ? null
        : decodeB64(j['signed_prekey_priv'] as String),
    nextSignedPrekeyId: j['next_signed_prekey_id'] as int? ?? 0,
    nextOtpkKeyId: j['next_otpk_key_id'] as int? ?? 0,
    oneTimePrekeys: (j['one_time_prekeys'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(
        int.parse(k),
        OneTimePrekeyState.fromJson(v as Map<String, dynamic>),
      ),
    ),
    sessions: (j['sessions'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, v as Map<String, dynamic>),
    ),
    conversations: (j['conversations'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, Conversation.fromJson(v as Map<String, dynamic>)),
    ),
    knownPeerIds: (j['known_peer_ids'] as List<dynamic>?)
        ?.cast<String>()
        .toSet(),
    blockedPeers: (j['blocked_peers'] as List<dynamic>?)
        ?.map((v) => BlockedPeer.fromJson(v as Map<String, dynamic>))
        .fold<Map<String, BlockedPeer>>({}, (m, p) {
          m[p.peerAccountId] = p;
          return m;
        }),
  );

  String server;
  String accountId;

  Uint8List rootPub;
  Uint8List rootPriv;

  String deviceId;
  Uint8List devicePub;
  Uint8List devicePriv;

  Uint8List? dhIdentityPub;
  Uint8List? dhIdentityPriv;

  int signedPrekeyId;
  Uint8List? signedPrekeyPub;
  Uint8List? signedPrekeyPriv;

  int nextSignedPrekeyId;
  int nextOtpkKeyId;
  Map<int, OneTimePrekeyState> oneTimePrekeys;

  /// Keyed by peer account id -- mirrors cmd/devclient's own simplifying
  /// assumption of a single active session per peer.
  Map<String, RatchetSessionJson> sessions;

  /// Keyed by peer account id -- the UI/history layer on top of
  /// [sessions]'s crypto layer.
  Map<String, Conversation> conversations;

  /// Every peer account id ever accepted (message request Accept) or
  /// reached out to ourselves (AppSession.startConversation) -- i.e. "not
  /// a stranger," independent of whether a Conversation for them still
  /// exists. Deliberately outlives AppSession.deleteConversation, so
  /// clearing a chat's history never regresses an already-known contact
  /// back to an unactioned "message request" the next time they write.
  Set<String> knownPeerIds;

  /// Every peer blocked locally, keyed by account id -- see [BlockedPeer].
  /// Deliberately outlives AppSession.deleteConversation, for the same
  /// reason: without this, deleting a blocked peer's chat would silently
  /// un-block them.
  Map<String, BlockedPeer> blockedPeers;

  DeviceCredentials get credentials =>
      DeviceCredentials(deviceId: deviceId, devicePriv: devicePriv);

  Map<String, dynamic> toJson() => {
    'server': server,
    'account_id': accountId,
    'root_pub': encodeB64(rootPub),
    'root_priv': encodeB64(rootPriv),
    'device_id': deviceId,
    'device_pub': encodeB64(devicePub),
    'device_priv': encodeB64(devicePriv),
    if (dhIdentityPub != null) 'dh_identity_pub': encodeB64(dhIdentityPub!),
    if (dhIdentityPriv != null) 'dh_identity_priv': encodeB64(dhIdentityPriv!),
    'signed_prekey_id': signedPrekeyId,
    if (signedPrekeyPub != null)
      'signed_prekey_pub': encodeB64(signedPrekeyPub!),
    if (signedPrekeyPriv != null)
      'signed_prekey_priv': encodeB64(signedPrekeyPriv!),
    'next_signed_prekey_id': nextSignedPrekeyId,
    'next_otpk_key_id': nextOtpkKeyId,
    if (oneTimePrekeys.isNotEmpty)
      'one_time_prekeys': oneTimePrekeys.map(
        (k, v) => MapEntry(k.toString(), v.toJson()),
      ),
    if (sessions.isNotEmpty) 'sessions': sessions,
    if (conversations.isNotEmpty)
      'conversations': conversations.map((k, v) => MapEntry(k, v.toJson())),
    if (knownPeerIds.isNotEmpty) 'known_peer_ids': knownPeerIds.toList(),
    if (blockedPeers.isNotEmpty)
      'blocked_peers': blockedPeers.values.map((p) => p.toJson()).toList(),
  };
}

/// Reads/writes one profile file per connected account under the app's
/// documents directory -- a device can hold several independent accounts
/// (each its own root/device key + server, by construction, since an
/// account id is `hash(root_pubkey)`), so there is one `AppState` per
/// profile rather than a single global one.
class LocalStateStore {
  // Legacy single-profile file from before multi-account support --
  // migrated once, automatically, the first time listProfiles() runs.
  static const _legacyFileName = 'freizone_state.json';

  static String _profileFileName(String accountId) =>
      'freizone_profile_$accountId.json';

  static Future<Directory> _dir() async => getApplicationDocumentsDirectory();

  static Future<File> _profileFile(String accountId) async {
    final dir = await _dir();
    return File(
      '${dir.path}${Platform.pathSeparator}${_profileFileName(accountId)}',
    );
  }

  /// Lists every locally stored profile, migrating the old single-profile
  /// file format on first run if one is found.
  static Future<List<AppState>> listProfiles() async {
    final dir = await _dir();
    await _migrateLegacyIfNeeded(dir);

    final profiles = <AppState>[];
    for (final entity in dir.listSync()) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (entity is! File ||
          !name.startsWith('freizone_profile_') ||
          !name.endsWith('.json'))
        continue;
      final data = await entity.readAsString();
      profiles.add(
        AppState.fromJson(json.decode(data) as Map<String, dynamic>),
      );
    }
    return profiles;
  }

  static Future<void> _migrateLegacyIfNeeded(Directory dir) async {
    final legacy = File('${dir.path}${Platform.pathSeparator}$_legacyFileName');
    if (!legacy.existsSync()) return;
    final data = await legacy.readAsString();
    final state = AppState.fromJson(json.decode(data) as Map<String, dynamic>);
    await saveProfile(state);
    await legacy.delete();
  }

  /// Loads one profile by account id, or null if it doesn't exist.
  static Future<AppState?> loadProfile(String accountId) async {
    final file = await _profileFile(accountId);
    if (!file.existsSync()) return null;
    final data = await file.readAsString();
    return AppState.fromJson(json.decode(data) as Map<String, dynamic>);
  }

  /// Writes to a fresh, uniquely-named temp file next to the real one,
  /// then atomically renames it into place -- a background sync isolate
  /// (see push_manager.dart) and a live foreground AppSession can both be
  /// writing this same account's profile around the same time; a plain
  /// write-in-place let a reader observe a half-written file mid-write
  /// (a real FormatException this has already hit once, see
  /// push_manager.dart's showMessageNotification doc comment). The random
  /// suffix means two concurrent writers never share a temp file either,
  /// so neither write can corrupt the other's -- the rename just decides
  /// whichever finishes last wins, cleanly.
  static Future<void> saveProfile(AppState state) async {
    final file = await _profileFile(state.accountId);
    final tmp = File('${file.path}.${Random().nextInt(1 << 32)}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
    );
    await tmp.rename(file.path);
  }

  static Future<void> deleteProfile(String accountId) async {
    final file = await _profileFile(accountId);
    if (file.existsSync()) await file.delete();
  }
}
