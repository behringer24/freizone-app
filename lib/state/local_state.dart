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
import 'group_conversation.dart';
import 'session_recovery.dart';

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

/// How many processed message ids [AppState.processedMessageIds] keeps.
/// Generous enough to cover a backlog that built up while the device was
/// offline (the server caps a device's queue well below this), small enough
/// to stay negligible in the profile file.
const int maxProcessedMessageIds = 500;

/// How many times a message may fail to decrypt before it is given up on and
/// dropped from the server queue (see [AppState.recordDecryptFailure]). An
/// envelope that fails once may just have raced a session change; one that
/// fails repeatedly never will, and must not block the queue forever.
const int maxDecryptAttempts = 3;

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
    Map<String, RatchetSessionJson>? inboundSessions,
    Map<String, Conversation>? conversations,
    Map<String, GroupConversation>? groups,
    Set<String>? knownPeerIds,
    Map<String, BlockedPeer>? blockedPeers,
    Set<String>? processedMessageIds,
    Map<String, int>? decryptFailures,
    Map<String, PeerSessionHealth>? peerSessionHealth,
    this.recoveryBackupDone = false,
    this.pushRegisteredAt,
    this.pushMechanism,
  }) : oneTimePrekeys = oneTimePrekeys ?? {},
       sessions = sessions ?? {},
       inboundSessions = inboundSessions ?? {},
       conversations = conversations ?? {},
       groups = groups ?? {},
       knownPeerIds = knownPeerIds ?? {},
       blockedPeers = blockedPeers ?? {},
       processedMessageIds = processedMessageIds ?? {},
       decryptFailures = decryptFailures ?? {},
       peerSessionHealth = peerSessionHealth ?? {};

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
    inboundSessions: (j['inbound_sessions'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, v as Map<String, dynamic>),
    ),
    conversations: (j['conversations'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, Conversation.fromJson(v as Map<String, dynamic>)),
    ),
    groups: (j['groups'] as Map<String, dynamic>?)?.map(
      (k, v) =>
          MapEntry(k, GroupConversation.fromJson(v as Map<String, dynamic>)),
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
    processedMessageIds: (j['processed_message_ids'] as List<dynamic>?)
        ?.cast<String>()
        .toSet(),
    decryptFailures: (j['decrypt_failures'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, v as int),
    ),
    peerSessionHealth: (j['peer_session_health'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, PeerSessionHealth.fromJson(v as Map<String, dynamic>)),
    ),
    recoveryBackupDone: j['recovery_backup_done'] as bool? ?? false,
    pushRegisteredAt: j['push_registered_at'] == null
        ? null
        : decodeTime(j['push_registered_at'] as String),
    pushMechanism: j['push_mechanism'] as String?,
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

  /// Sessions kept only for READING, keyed by peer.
  ///
  /// Two parties who establish with each other at the same moment each hold
  /// their own initiator session and neither can read the other's. That is
  /// rare in a one-to-one chat, where somebody speaks first, and routine in a
  /// group, where a joining member reaches for everyone at once and everyone
  /// reaches back. A tie-break on the lower account id decides which session
  /// both sides will *send* on (docs/PROTOCOL.md §5); the losing one is kept
  /// here rather than discarded, so the messages already in flight on it can
  /// still be read instead of looking like a desync.
  Map<String, RatchetSessionJson> inboundSessions;

  /// Keyed by peer account id -- the UI/history layer on top of
  /// [sessions]'s crypto layer.
  Map<String, Conversation> conversations;

  /// Group transcripts, keyed by group id (APP-16).
  ///
  /// Only the transcripts. A group's membership and roles are a signed fact
  /// set living in its own file (group_store.dart), because it has the
  /// opposite write profile: tens of kilobytes that change rarely, against a
  /// profile rewritten in full on every single message.
  Map<String, GroupConversation> groups;

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

  /// Ids of messages already decrypted and stored, newest last.
  ///
  /// Delivery is at-least-once: the server keeps a message queued until the
  /// client explicitly deletes it, and that delete can be lost (offline, a
  /// killed process, a wake that raced the SSE stream). Re-processing a
  /// message is not harmless -- it advances the Double Ratchet a second time
  /// for one message, and a redelivered X3DH initial would rebuild the
  /// responder session and overwrite the advanced one, permanently desyncing
  /// the conversation. Checked in [processIncomingMessage], so both the live
  /// stream and the background push sync are covered.
  ///
  /// Bounded to [maxProcessedMessageIds] (insertion-ordered, oldest evicted
  /// first) -- redelivery happens within a queue's lifetime, so remembering
  /// the recent past is enough and the profile can't grow without limit.
  Set<String> processedMessageIds;

  /// How often each still-undelivered message has failed to decrypt, so a
  /// permanently undecryptable one can be dropped instead of blocking the
  /// queue forever. See [recordDecryptFailure].
  Map<String, int> decryptFailures;

  /// Per-peer evidence that a session has desynced, keyed by peer account id
  /// and present only for peers something has actually gone wrong with (see
  /// [PeerSessionHealth]). Drives the automatic recovery in
  /// AppSession._recoverDesyncedSessions; written by whichever isolate notices
  /// (including a background push wake, which cannot send and so cannot act on
  /// it itself), read by the one that can act.
  Map<String, PeerSessionHealth> peerSessionHealth;

  /// True once the user has backed up (or explicitly dismissed the prompt to
  /// back up) this account's recovery phrase (APP-01). Drives the one-time
  /// post-setup backup nudge on the chat list; set for a *recovered* account
  /// from the start, since the user already holds the phrase.
  bool recoveryBackupDone;

  /// When this account last successfully told **its own server** where to send
  /// push wakes, and which mechanism it used ("fcm", or "unifiedpush:<pkg>").
  ///
  /// Persisted, not in-memory, for two reasons. First, it is the one part of
  /// the push picture that genuinely differs per account -- the *mechanism* is
  /// an app-wide choice (AppSettings.pushPreference) and the FCM token is one
  /// per install, but each account registers separately against its own
  /// server, so one can be fine while another's server was unreachable.
  /// Second, the registration that matters most happens where nothing is
  /// watching: a token refresh handled by the background engine (APP-12), so a
  /// value living only in RAM would be gone before anyone could read it.
  ///
  /// Null means "never successfully registered" -- which is exactly what the
  /// diagnostics screen needs to be able to say out loud.
  DateTime? pushRegisteredAt;
  String? pushMechanism;

  /// Records messageId as handled, evicting the oldest entries past the cap.
  void markMessageProcessed(String messageId) {
    processedMessageIds.add(messageId);
    while (processedMessageIds.length > maxProcessedMessageIds) {
      processedMessageIds.remove(processedMessageIds.first);
    }
    // A message that finally succeeded needs no failure history any more.
    decryptFailures.remove(messageId);
  }

  /// Counts one failed decrypt of messageId and reports whether it should now
  /// be given up on (dropped from the server queue).
  ///
  /// Persisted rather than in-memory because the background push isolate is
  /// torn down between wakes: a counter living only in RAM would restart at
  /// zero every time and never reach the limit, so an envelope that can never
  /// be decrypted would be re-fetched and re-fail on every single wake,
  /// forever.
  bool recordDecryptFailure(String messageId) {
    final attempts = (decryptFailures[messageId] ?? 0) + 1;
    if (attempts >= maxDecryptAttempts) {
      decryptFailures.remove(messageId);
      return true;
    }
    decryptFailures[messageId] = attempts;
    while (decryptFailures.length > maxProcessedMessageIds) {
      decryptFailures.remove(decryptFailures.keys.first);
    }
    return false;
  }

  /// Records that one envelope from peerAccountId has been given up on for a
  /// reason that implies diverged ratchet keys -- i.e. one unit of the evidence
  /// [shouldAutoRekey] weighs. Call only once per envelope, when
  /// [recordDecryptFailure] has just reported it exhausted AND the failure code
  /// meant desync (CoreErrorCode.suggestsDesync): counting every attempt would
  /// reach any threshold three times over, and counting a redelivery or an
  /// undiagnosed error would recover sessions that were never broken.
  ///
  /// Ignored for a peer there is no [conversations] entry for, which bounds this
  /// map to conversations that exist: recovery has nowhere to send to without
  /// one anyway, and without the guard a stranger sending undecryptable
  /// envelopes could grow the profile with an entry per account id they invent.
  void recordDesyncEvidence(String peerAccountId, DateTime at) {
    if (!conversations.containsKey(peerAccountId)) return;
    final health = peerSessionHealth.putIfAbsent(
      peerAccountId,
      PeerSessionHealth.new,
    );
    health.desyncEvidence++;
    health.firstFailureAt ??= at;
  }

  /// Forgets everything recorded about peerAccountId's session going wrong --
  /// called whenever a message from them decrypts, which is the only proof that
  /// the session works. Also clears the re-key spacing, deliberately: a healthy
  /// session needs no protection against re-keying too often.
  void clearDesyncEvidence(String peerAccountId) {
    peerSessionHealth.remove(peerAccountId);
  }

  /// Records that an automatic re-key with peerAccountId has just been sent:
  /// the evidence that triggered it is spent, but the timestamp outlives it to
  /// space out any further attempt ([minAutoRekeyInterval]).
  void recordAutoRekey(String peerAccountId, DateTime at) {
    final health = peerSessionHealth.putIfAbsent(
      peerAccountId,
      PeerSessionHealth.new,
    );
    health.desyncEvidence = 0;
    health.firstFailureAt = null;
    health.lastRekeyAt = at;
  }

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
    if (inboundSessions.isNotEmpty) 'inbound_sessions': inboundSessions,
    if (conversations.isNotEmpty)
      'conversations': conversations.map((k, v) => MapEntry(k, v.toJson())),
    if (groups.isNotEmpty)
      'groups': groups.map((k, v) => MapEntry(k, v.toJson())),
    if (knownPeerIds.isNotEmpty) 'known_peer_ids': knownPeerIds.toList(),
    if (blockedPeers.isNotEmpty)
      'blocked_peers': blockedPeers.values.map((p) => p.toJson()).toList(),
    if (processedMessageIds.isNotEmpty)
      'processed_message_ids': processedMessageIds.toList(),
    if (decryptFailures.isNotEmpty) 'decrypt_failures': decryptFailures,
    if (peerSessionHealth.isNotEmpty)
      'peer_session_health': peerSessionHealth.map(
        (k, v) => MapEntry(k, v.toJson()),
      ),
    if (recoveryBackupDone) 'recovery_backup_done': true,
    if (pushRegisteredAt != null)
      'push_registered_at': encodeTime(pushRegisteredAt!),
    if (pushMechanism != null) 'push_mechanism': pushMechanism,
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
  /// The account id of every locally stored profile, read from the file names
  /// alone. For a caller that will load each profile itself anyway (under
  /// [withProfileLock], so it gets a snapshot that can't already be stale),
  /// this avoids parsing every profile up front only to throw the result away.
  static Future<List<String>> listProfileIds() async {
    final dir = await _dir();
    await _migrateLegacyIfNeeded(dir);

    const prefix = 'freizone_profile_';
    const suffix = '.json';
    final ids = <String>[];
    for (final entity in dir.listSync()) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (entity is! File ||
          !name.startsWith(prefix) ||
          !name.endsWith(suffix)) {
        continue;
      }
      ids.add(name.substring(prefix.length, name.length - suffix.length));
    }
    return ids;
  }

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

  /// Runs [action] holding an exclusive, cross-isolate lock on accountId's
  /// profile, so a load-modify-save sequence can't interleave with another
  /// one and lose the other's changes.
  ///
  /// [saveProfile] is a whole-file overwrite: it makes a write atomic, but
  /// two writers still resolve as last-writer-wins. That is fine for a single
  /// field, and fatal for the Double Ratchet -- the background push isolate
  /// loads a profile, spends seconds on network I/O and decryption, then
  /// saves; if the foreground isolate loads and saves anywhere in that
  /// window, one side's ratchet advance is silently reverted and every
  /// subsequent message from that peer fails to authenticate, permanently.
  /// Serialising the whole sequence is what actually prevents that.
  ///
  /// Implemented by exclusively creating a lock file rather than with
  /// [RandomAccessFile.lock]: both isolates live in the same OS process, and
  /// POSIX advisory locks are held per process, so a file lock would not see
  /// them as distinct holders at all. An exclusive create is atomic in the
  /// filesystem and therefore does distinguish them.
  ///
  /// Waits up to [timeout] for the holder to finish. A lock file older than
  /// [_lockStaleAfter] is treated as abandoned (the holding isolate was
  /// killed mid-sync, which Android does routinely) and taken over, so a
  /// crash can never wedge an account permanently.
  static Future<T> withProfileLock<T>(
    String accountId,
    Future<T> Function() action, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final file = await _profileFile(accountId);
    final lock = File('${file.path}.lock');
    final deadline = DateTime.now().add(timeout);

    while (true) {
      try {
        await lock.create(exclusive: true);
        break;
      } on FileSystemException {
        // Held by someone else -- unless it was abandoned, or we've waited
        // long enough that proceeding is better than dropping the work.
        final abandoned = await _lockIsStale(lock);
        if (abandoned || DateTime.now().isAfter(deadline)) {
          try {
            await lock.delete();
          } catch (_) {
            // Raced another waiter to the takeover; retry either way.
          }
          continue;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    try {
      return await action();
    } finally {
      try {
        await lock.delete();
      } catch (_) {
        // Already taken over by a waiter that judged us stale; nothing to do.
      }
    }
  }

  /// How long a lock file may sit untouched before it's considered abandoned
  /// by a killed isolate. Comfortably longer than a real sync (a fetch plus a
  /// handful of decrypts), short enough not to strand an account.
  static const _lockStaleAfter = Duration(minutes: 2);

  static Future<bool> _lockIsStale(File lock) async {
    try {
      return DateTime.now().difference(await lock.lastModified()) >
          _lockStaleAfter;
    } on FileSystemException {
      return false; // vanished under us -- the create retry will settle it
    }
  }
}
