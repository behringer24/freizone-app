// Persisted local identity and conversation state -- the Dart-side
// mirror of cmd/devclient's State (state.go) in freizone-server. Stored
// as one indented JSON file under the app's documents directory via
// path_provider.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../ffi/models.dart';
import '../net/api_client.dart';
import 'conversation.dart';

/// One uploaded one-time prekey's key pair, kept locally until it's
/// consumed by a peer (the server never says which one gets claimed).
class OneTimePrekeyState {
  OneTimePrekeyState({required this.pub, required this.priv});

  factory OneTimePrekeyState.fromJson(Map<String, dynamic> j) => OneTimePrekeyState(
        pub: decodeB64(j['pub'] as String),
        priv: decodeB64(j['priv'] as String),
      );

  Map<String, dynamic> toJson() => {'pub': encodeB64(pub), 'priv': encodeB64(priv)};

  final Uint8List pub;
  final Uint8List priv;
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
  })  : oneTimePrekeys = oneTimePrekeys ?? {},
        sessions = sessions ?? {},
        conversations = conversations ?? {};

  factory AppState.fromJson(Map<String, dynamic> j) => AppState(
        server: j['server'] as String,
        accountId: j['account_id'] as String,
        rootPub: decodeB64(j['root_pub'] as String),
        rootPriv: decodeB64(j['root_priv'] as String),
        deviceId: j['device_id'] as String,
        devicePub: decodeB64(j['device_pub'] as String),
        devicePriv: decodeB64(j['device_priv'] as String),
        dhIdentityPub: j['dh_identity_pub'] == null ? null : decodeB64(j['dh_identity_pub'] as String),
        dhIdentityPriv: j['dh_identity_priv'] == null ? null : decodeB64(j['dh_identity_priv'] as String),
        signedPrekeyId: j['signed_prekey_id'] as int? ?? 0,
        signedPrekeyPub: j['signed_prekey_pub'] == null ? null : decodeB64(j['signed_prekey_pub'] as String),
        signedPrekeyPriv: j['signed_prekey_priv'] == null ? null : decodeB64(j['signed_prekey_priv'] as String),
        nextSignedPrekeyId: j['next_signed_prekey_id'] as int? ?? 0,
        nextOtpkKeyId: j['next_otpk_key_id'] as int? ?? 0,
        oneTimePrekeys: (j['one_time_prekeys'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(int.parse(k), OneTimePrekeyState.fromJson(v as Map<String, dynamic>)),
        ),
        sessions: (j['sessions'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, v as Map<String, dynamic>),
        ),
        conversations: (j['conversations'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, Conversation.fromJson(v as Map<String, dynamic>)),
        ),
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

  DeviceCredentials get credentials => DeviceCredentials(deviceId: deviceId, devicePriv: devicePriv);

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
        if (signedPrekeyPub != null) 'signed_prekey_pub': encodeB64(signedPrekeyPub!),
        if (signedPrekeyPriv != null) 'signed_prekey_priv': encodeB64(signedPrekeyPriv!),
        'next_signed_prekey_id': nextSignedPrekeyId,
        'next_otpk_key_id': nextOtpkKeyId,
        if (oneTimePrekeys.isNotEmpty)
          'one_time_prekeys': oneTimePrekeys.map((k, v) => MapEntry(k.toString(), v.toJson())),
        if (sessions.isNotEmpty) 'sessions': sessions,
        if (conversations.isNotEmpty)
          'conversations': conversations.map((k, v) => MapEntry(k, v.toJson())),
      };
}

/// Reads/writes the single local AppState file under the app's documents
/// directory.
class LocalStateStore {
  static const _fileName = 'freizone_state.json';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// Loads the persisted state, or null if none has been saved yet (no
  /// account bootstrapped/registered on this device).
  static Future<AppState?> load() async {
    final file = await _file();
    if (!file.existsSync()) return null;
    final data = await file.readAsString();
    return AppState.fromJson(json.decode(data) as Map<String, dynamic>);
  }

  static Future<void> save(AppState state) async {
    final file = await _file();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(state.toJson()));
  }
}
