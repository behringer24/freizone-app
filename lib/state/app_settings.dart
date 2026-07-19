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
    String? lastActiveAccountId,
  }) : _themeMode = themeMode,
       _accentPreset = accentPreset,
       _copyIdShort = copyIdShort,
       _notificationSound = notificationSound,
       _notificationVibration = notificationVibration,
       _pushPreference = pushPreference,
       _lastActiveAccountId = lastActiveAccountId;

  ThemeMode _themeMode;
  AccentPreset _accentPreset;
  bool _copyIdShort;
  bool _notificationSound;
  bool _notificationVibration;
  PushPreference _pushPreference;
  String? _lastActiveAccountId;

  ThemeMode get themeMode => _themeMode;
  AccentPreset get accentPreset => _accentPreset;

  /// Whether "Copy my address" should use the short id-prefix form
  /// (see lib/util/freizone_address.dart) instead of the full id.
  bool get copyIdShort => _copyIdShort;
  bool get notificationSound => _notificationSound;
  bool get notificationVibration => _notificationVibration;
  PushPreference get pushPreference => _pushPreference;

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

  Future<void> setLastActiveAccountId(String? accountId) async {
    if (_lastActiveAccountId == accountId) return;
    _lastActiveAccountId = accountId;
    await _save();
  }
}
