// Orchestrates every account connected on this device. Each is a fully
// independent identity (own root/device key + server -- an account id is
// hash(root_pubkey), so there's no portable identity across servers) with
// its own AppSession, and -- deliberately -- all of them stay live at
// once (their own SSE connection, their own UnifiedPush registration)
// rather than only the currently-viewed one, so push notifications work
// regardless of which account's server most recently changed.
import 'package:flutter/foundation.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../push/push_manager.dart';
import 'app_session.dart';
import 'local_state.dart';

class AccountManager extends ChangeNotifier {
  AccountManager._(this._sessions, this._activeAccountId);

  final Map<String, AppSession> _sessions;
  String? _activeAccountId;

  List<AppSession> get sessions => _sessions.values.toList();
  AppSession? get active => _sessions[_activeAccountId];
  String? get activeAccountId => _activeAccountId;

  /// Loads every locally stored profile and starts a live session for
  /// each. Call once, at app startup.
  static Future<AccountManager> load() async {
    await requestNotificationPermission();

    final profiles = await LocalStateStore.listProfiles();
    final sessions = <String, AppSession>{};
    for (final profile in profiles) {
      final session = AppSession(profile);
      await session.init();
      sessions[profile.accountId] = session;
    }
    return AccountManager._(sessions, profiles.isEmpty ? null : profiles.first.accountId);
  }

  /// Adds a freshly registered/bootstrapped account (see SetupScreen) and
  /// makes it the active one. Registration always generates a fresh
  /// random root key (so a fresh account id), so this can't collide with
  /// an already-connected profile today -- but disposing of any existing
  /// session at this key first is cheap and keeps this correct once a
  /// "restore an existing account" flow (recovery seed) exists, which
  /// would genuinely hit this path.
  Future<void> addProfile(AppState state) async {
    _sessions[state.accountId]?.dispose();

    final session = AppSession(state);
    await session.init();
    _sessions[state.accountId] = session;
    _activeAccountId = state.accountId;
    notifyListeners();
  }

  /// Removes an account: unregisters its push subscription (server-side,
  /// via the existing UnifiedPush unregister callback), closes its
  /// session, and deletes its local data. This only forgets the account
  /// on this device -- it does not revoke the device server-side, same
  /// as if the app were simply uninstalled. Irreversible without a
  /// recovery seed.
  Future<void> removeProfile(String accountId) async {
    final session = _sessions[accountId];
    if (session == null) return;

    // Order matters: unregister while the profile file still exists, so
    // the onUnregistered callback (keyed by this same instance name) can
    // load its credentials and clear the push endpoint server-side.
    await UnifiedPush.unregister(accountId);

    session.dispose();
    _sessions.remove(accountId);
    await LocalStateStore.deleteProfile(accountId);

    if (_activeAccountId == accountId) {
      _activeAccountId = _sessions.keys.isEmpty ? null : _sessions.keys.first;
    }
    notifyListeners();
  }

  void setActive(String accountId) {
    if (!_sessions.containsKey(accountId) || _activeAccountId == accountId) return;
    _activeAccountId = accountId;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final session in _sessions.values) {
      session.dispose();
    }
    super.dispose();
  }
}
