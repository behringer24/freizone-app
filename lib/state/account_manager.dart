// Orchestrates every account connected on this device. Each is a fully
// independent identity (own root/device key + server -- an account id is
// hash(root_pubkey), so there's no portable identity across servers) with
// its own AppSession, and -- deliberately -- all of them stay live at
// once (their own SSE connection, their own UnifiedPush registration)
// rather than only the currently-viewed one, so push notifications work
// regardless of which account's server most recently changed.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../push/push_manager.dart';
import '../util/server_url.dart';
import 'app_session.dart';
import 'app_settings.dart';
import 'local_state.dart';

class AccountManager extends ChangeNotifier {
  AccountManager._(this._sessions, this._activeAccountId, this._settings);

  final Map<String, AppSession> _sessions;
  String? _activeAccountId;
  final AppSettings _settings;

  List<AppSession> get sessions => _sessions.values.toList();
  AppSession? get active => _sessions[_activeAccountId];
  String? get activeAccountId => _activeAccountId;

  /// Sessions bucketed by server (via [sameServer], not raw string
  /// equality -- two accounts on "chat.example.org" and
  /// "https://chat.example.org" belong in the same group), preserving
  /// each session's original relative order and each group's
  /// first-appearance order. The single source of truth for how accounts
  /// are grouped/ordered wherever they're shown side by side --
  /// AccountShellScreen's switcher strip renders these groups (with a
  /// divider/label between them), and [orderedSessions] below is just
  /// this, flattened.
  List<List<AppSession>> get groupedSessions {
    final groups = <List<AppSession>>[];
    for (final session in sessions) {
      var placed = false;
      for (final group in groups) {
        if (sameServer(group.first.state.server, session.state.server)) {
          group.add(session);
          placed = true;
          break;
        }
      }
      if (!placed) groups.add([session]);
    }
    return groups;
  }

  /// The single canonical left-to-right account order, used everywhere
  /// accounts are shown side by side but NOT grouped visually -- the
  /// swipeable chat list (ChatListScreen) reads this so swiping through
  /// chats traverses accounts in exactly the order the switcher strip
  /// shows them in (see [groupedSessions]).
  List<AppSession> get orderedSessions =>
      groupedSessions.expand((g) => g).toList();

  /// The session for a specific account id, e.g. resolving a tapped
  /// notification's target account (see notification_navigation.dart) --
  /// null if that account no longer exists on this device.
  AppSession? sessionFor(String accountId) => _sessions[accountId];

  /// Loads every locally stored profile and starts a live session for
  /// each. Call once, at app startup. Reactivates whichever account was
  /// last active (settings.lastActiveAccountId) rather than always
  /// falling back to an arbitrary "first in the list" order -- falls
  /// back to that only if the remembered id no longer exists (e.g. that
  /// account was removed on another device in the meantime).
  static Future<AccountManager> load(AppSettings settings) async {
    await requestNotificationPermission();

    final profiles = await LocalStateStore.listProfiles();
    final sessions = <String, AppSession>{};
    for (final profile in profiles) {
      final session = AppSession(profile);
      await session.init();
      sessions[profile.accountId] = session;
    }
    final remembered = settings.lastActiveAccountId;
    final initialActiveId =
        (remembered != null && sessions.containsKey(remembered))
        ? remembered
        : (profiles.isEmpty ? null : profiles.first.accountId);
    return AccountManager._(sessions, initialActiveId, settings);
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
    unawaited(_settings.setLastActiveAccountId(state.accountId));
    notifyListeners();
  }

  /// Permanently deletes an account: server-side first (via the session's
  /// [AppSession.deleteOwnAccount] -- throws on failure, e.g. a network
  /// error or the last-admin conflict, in which case nothing local is
  /// touched either, so a failed attempt never leaves the account
  /// orphaned -- gone locally but still alive and unreachable on the
  /// server), then the same local cleanup [removeOrphanedAccount] does on
  /// its own. There is no path back to this identity afterward, on this
  /// or any other device -- unlike removing a device from an account you
  /// keep, deleting the account itself is final.
  Future<void> deleteAccount(String accountId) async {
    if (!_sessions.containsKey(accountId)) return;
    await _sessions[accountId]!.deleteOwnAccount();
    await _removeLocalProfile(accountId);
  }

  /// Removes an account from this device WITHOUT trying to delete it
  /// server-side first -- the deliberate escape hatch for an already
  /// -orphaned account: [deleteAccount] above rejected it with a 401 (the
  /// server no longer recognizes this device/account at all, e.g. its
  /// data was reset independently), so there is no valid request this
  /// device could ever sign that the server would accept, and the normal
  /// delete flow can never succeed. This is the one case where "just
  /// forget it locally" is the only remaining option, not a routine
  /// alternative to [deleteAccount] -- see profile_screen.dart's
  /// fallback dialog, the only caller.
  Future<void> removeOrphanedAccount(String accountId) =>
      _removeLocalProfile(accountId);

  Future<void> _removeLocalProfile(String accountId) async {
    final session = _sessions[accountId];
    if (session == null) return;

    // Order matters: unregister while the profile file still exists, so
    // the onUnregistered callback (keyed by this same instance name) can
    // load its credentials and clear the push endpoint server-side --
    // itself best-effort (see push_manager.dart's _onUnregistered), so a
    // server that no longer recognizes this device either doesn't block
    // the local cleanup here.
    await UnifiedPush.unregister(accountId);

    session.dispose();
    _sessions.remove(accountId);
    await LocalStateStore.deleteProfile(accountId);

    if (_activeAccountId == accountId) {
      _activeAccountId = _sessions.keys.isEmpty ? null : _sessions.keys.first;
      unawaited(_settings.setLastActiveAccountId(_activeAccountId));
    }
    notifyListeners();
  }

  void setActive(String accountId) {
    if (!_sessions.containsKey(accountId) || _activeAccountId == accountId)
      return;
    _activeAccountId = accountId;
    unawaited(_settings.setLastActiveAccountId(accountId));
    // registrationPolicy (and myRole) are only fetched once at session
    // creation -- refresh them on every switch so a policy/role change
    // made on this or another device is reflected without an app
    // restart, e.g. the Invite/Server Admin menu entries.
    unawaited(_sessions[accountId]!.refreshRegistrationPolicy());
    unawaited(_sessions[accountId]!.refreshMyRole());
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
