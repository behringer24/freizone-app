// App-wide preferences -- unlike AppState (one JSON file per connected
// account), these apply regardless of which account is active, so they
// live in their own single JSON file under the app's documents
// directory, following the same plain-JSON persistence style as
// local_state.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// A small, curated set of seed colors for the app's Material theme,
/// rather than an arbitrary color picker -- keeps every combination
/// looking deliberate rather than needing to validate contrast for any
/// color at all.
enum AccentPreset {
  teal(Colors.teal, 'Teal'),
  indigo(Colors.indigo, 'Indigo'),
  purple(Colors.purple, 'Purple'),
  deepOrange(Colors.deepOrange, 'Orange'),
  pink(Colors.pink, 'Pink'),
  green(Colors.green, 'Green');

  const AccentPreset(this.color, this.label);

  final Color color;
  final String label;
}

/// Which push-wake mechanism to register, see lib/push/push_manager.dart's
/// registerForPush. UnifiedPush and FCM are independent, non-interfering
/// mechanisms -- this only controls which one *this app* asks the server
/// to use, not which one(s) happen to be installed/available.
enum PushPreference {
  /// Prefer UnifiedPush when a distributor is installed (no Google
  /// dependency); fall back to FCM only if none is found. The default --
  /// FCM exists specifically to cover people without a distributor, not
  /// to replace UnifiedPush for people who already have one.
  automatic('Automatic (prefer UnifiedPush)'),

  /// Always register via Firebase Cloud Messaging, even if a UnifiedPush
  /// distributor is installed. Mainly useful for testing the FCM path
  /// without uninstalling anything.
  forceFcm('Always use Firebase (FCM)'),

  /// Always register via UnifiedPush; if no distributor is installed,
  /// this surfaces the existing "no distributor" hint rather than
  /// silently falling back to FCM.
  forceUnifiedPush('Always use UnifiedPush');

  const PushPreference(this.label);

  final String label;
}

class AppSettings extends ChangeNotifier {
  AppSettings._({
    required ThemeMode themeMode,
    required AccentPreset accentPreset,
    required bool copyIdShort,
    required bool notificationSound,
    required bool notificationVibration,
    required PushPreference pushPreference,
    required bool readReceiptsEnabled,
    required bool enterSendsMessage,
    required bool directShareEnabled,
    required bool autoSavePicturesToGallery,
    String? lastActiveAccountId,
  }) : _themeMode = themeMode,
       _accentPreset = accentPreset,
       _copyIdShort = copyIdShort,
       _notificationSound = notificationSound,
       _notificationVibration = notificationVibration,
       _pushPreference = pushPreference,
       _readReceiptsEnabled = readReceiptsEnabled,
       _enterSendsMessage = enterSendsMessage,
       _directShareEnabled = directShareEnabled,
       _autoSavePicturesToGallery = autoSavePicturesToGallery,
       _lastActiveAccountId = lastActiveAccountId;

  ThemeMode _themeMode;
  AccentPreset _accentPreset;
  bool _copyIdShort;
  bool _notificationSound;
  bool _notificationVibration;
  PushPreference _pushPreference;
  bool _readReceiptsEnabled;
  bool _enterSendsMessage;
  bool _directShareEnabled;
  bool _autoSavePicturesToGallery;
  String? _lastActiveAccountId;

  ThemeMode get themeMode => _themeMode;
  AccentPreset get accentPreset => _accentPreset;

  /// Whether "Copy my address" should use the short id-prefix form
  /// (see lib/util/freizone_address.dart) instead of the full id.
  bool get copyIdShort => _copyIdShort;
  bool get notificationSound => _notificationSound;
  bool get notificationVibration => _notificationVibration;
  PushPreference get pushPreference => _pushPreference;

  /// Whether this device sends delivery/read receipts (receipt_signal
  /// .dart) for messages it sends/receives, AND whether it stores/shows
  /// receipts a peer sends back -- a single switch controls both
  /// directions, so turning it off is reciprocal: you neither tell others
  /// you've read their messages, nor see whether they've read yours.
  bool get readReceiptsEnabled => _readReceiptsEnabled;

  /// Whether pressing Enter in the chat composer sends the message
  /// immediately. When false (the default), Enter inserts a line break
  /// and the send button sends. With a hardware keyboard, Shift+Enter
  /// always inserts a line break regardless of this setting.
  bool get enterSendsMessage => _enterSendsMessage;

  /// Whether individual chats are offered in the system share sheet's
  /// direct-share row (APP-15).
  ///
  /// **Off by default, deliberately.** Making a chat a share target means
  /// handing its label and avatar to the system shortcut store, where the
  /// launcher and the share sheet can read them — the one place Freizone lets
  /// contact details out of its own sandbox. On an app whose whole point is
  /// withholding metadata, that is a trade the user should opt into rather
  /// than discover. Turning it back off removes what was already published, it
  /// doesn't merely stop adding more.
  ///
  /// Note the default also applies to installs that predate the setting: their
  /// stored preferences have no such key, so they read as off and
  /// syncShareShortcuts clears anything an earlier build had published.
  bool get directShareEnabled => _directShareEnabled;

  /// Whether every picture this account receives is copied into the device's
  /// gallery as soon as its download finishes (APP-20).
  ///
  /// **Off by default, deliberately.** Everything the app stores sits in its
  /// own private directory, readable by nothing else on the device. A copy in
  /// the gallery is readable by every app holding media permission and, on
  /// most phones, uploaded to the user's cloud photo library within minutes.
  /// That is the entire point of the feature, and also the one property an
  /// end-to-end-encrypted messenger must not hand over by accident — so this
  /// is a decision the user makes once, knowingly, rather than a convenience
  /// that happens to be on. Saving a single picture by hand is an act each
  /// time and needs no such framing.
  ///
  /// Applies to *received* pictures only, like the manual save (see
  /// maySavePicture): one this account sent came out of the gallery to begin
  /// with. Installs predating the setting have no such key stored, so they
  /// read as off — nothing starts leaving the sandbox because of an update.
  bool get autoSavePicturesToGallery => _autoSavePicturesToGallery;

  /// The account id AccountManager should activate on the next app
  /// start, so a multi-account setup doesn't fall back to an
  /// arbitrary "first in the list" order every time. Not a
  /// user-facing setting (no toggle for it) -- just remembered
  /// automatically whenever the active account changes.
  String? get lastActiveAccountId => _lastActiveAccountId;

  static const _fileName = 'freizone_settings.json';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<AppSettings> load() async {
    final file = await _file();
    if (!file.existsSync()) {
      return AppSettings._(
        themeMode: ThemeMode.system,
        accentPreset: AccentPreset.teal,
        copyIdShort: false,
        notificationSound: true,
        notificationVibration: true,
        pushPreference: PushPreference.automatic,
        readReceiptsEnabled: true,
        enterSendsMessage: false,
        directShareEnabled: false,
        autoSavePicturesToGallery: false,
      );
    }
    final j = json.decode(await file.readAsString()) as Map<String, dynamic>;
    return AppSettings._(
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == j['theme_mode'],
        orElse: () => ThemeMode.system,
      ),
      accentPreset: AccentPreset.values.firstWhere(
        (p) => p.name == j['accent_preset'],
        orElse: () => AccentPreset.teal,
      ),
      copyIdShort: j['copy_id_short'] as bool? ?? false,
      notificationSound: j['notification_sound'] as bool? ?? true,
      notificationVibration: j['notification_vibration'] as bool? ?? true,
      pushPreference: PushPreference.values.firstWhere(
        (p) => p.name == j['push_preference'],
        orElse: () => PushPreference.automatic,
      ),
      readReceiptsEnabled: j['read_receipts_enabled'] as bool? ?? true,
      enterSendsMessage: j['enter_sends_message'] as bool? ?? false,
      directShareEnabled: j['direct_share_enabled'] as bool? ?? false,
      autoSavePicturesToGallery:
          j['auto_save_pictures_to_gallery'] as bool? ?? false,
      lastActiveAccountId: j['last_active_account_id'] as String?,
    );
  }

  Future<void> _save() async {
    final file = await _file();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'theme_mode': _themeMode.name,
        'accent_preset': _accentPreset.name,
        'copy_id_short': _copyIdShort,
        'notification_sound': _notificationSound,
        'notification_vibration': _notificationVibration,
        'push_preference': _pushPreference.name,
        'read_receipts_enabled': _readReceiptsEnabled,
        'enter_sends_message': _enterSendsMessage,
        'direct_share_enabled': _directShareEnabled,
        'auto_save_pictures_to_gallery': _autoSavePicturesToGallery,
        if (_lastActiveAccountId != null)
          'last_active_account_id': _lastActiveAccountId,
      }),
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    await _save();
    notifyListeners();
  }

  Future<void> setAccentPreset(AccentPreset preset) async {
    if (_accentPreset == preset) return;
    _accentPreset = preset;
    await _save();
    notifyListeners();
  }

  Future<void> setCopyIdShort(bool value) async {
    if (_copyIdShort == value) return;
    _copyIdShort = value;
    await _save();
    notifyListeners();
  }

  Future<void> setNotificationSound(bool value) async {
    if (_notificationSound == value) return;
    _notificationSound = value;
    await _save();
    notifyListeners();
  }

  Future<void> setNotificationVibration(bool value) async {
    if (_notificationVibration == value) return;
    _notificationVibration = value;
    await _save();
    notifyListeners();
  }

  Future<void> setPushPreference(PushPreference value) async {
    if (_pushPreference == value) return;
    _pushPreference = value;
    await _save();
    notifyListeners();
  }

  Future<void> setReadReceiptsEnabled(bool value) async {
    if (_readReceiptsEnabled == value) return;
    _readReceiptsEnabled = value;
    await _save();
    notifyListeners();
  }

  Future<void> setEnterSendsMessage(bool value) async {
    if (_enterSendsMessage == value) return;
    _enterSendsMessage = value;
    await _save();
    notifyListeners();
  }

  /// Persists the flag only. Actually publishing or removing the shortcuts is
  /// the caller's job (see syncShareShortcuts) -- this class deliberately owns
  /// no platform channels.
  Future<void> setDirectShareEnabled(bool value) async {
    if (_directShareEnabled == value) return;
    _directShareEnabled = value;
    await _save();
    notifyListeners();
  }

  /// Persists the flag only. Obtaining the storage permission that older
  /// Android versions need for it is the caller's job (see
  /// ensureGalleryPermission) -- this class deliberately owns no platform
  /// channels.
  Future<void> setAutoSavePicturesToGallery(bool value) async {
    if (_autoSavePicturesToGallery == value) return;
    _autoSavePicturesToGallery = value;
    await _save();
    notifyListeners();
  }

  Future<void> setLastActiveAccountId(String? accountId) async {
    if (_lastActiveAccountId == accountId) return;
    _lastActiveAccountId = accountId;
    await _save();
  }
}
