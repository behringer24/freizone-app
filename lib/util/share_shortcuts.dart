// Sharing shortcuts: the individual chats Freizone offers in the system share
// sheet's direct-share row (APP-15 level 2).
//
// The identity of a shortcut is the pair (account, peer), because Freizone is
// multi-account and the same peer can be reachable from more than one of them.
// Encoding both into the shortcut id is what lets a share arrive already
// addressed, so the target picker can be skipped entirely.
//
// Note what publishing these costs, since it is not obvious: a shortcut's label
// and icon are handed to the system shortcut store, where the launcher and the
// share sheet can read them. That means contact names and avatars leave the app
// sandbox -- on a system built to withhold metadata. It is therefore a setting
// (AppSettings.directShareEnabled), and turning it off *removes* what was
// published rather than merely stopping new ones.
import 'package:flutter/services.dart';

import '../state/account_manager.dart';
import '../state/app_settings.dart';
import '../state/contact_store.dart';
import 'avatar_bitmap.dart';

const _channel = MethodChannel('freizone/share_shortcuts');

/// How many chats to offer. Android caps dynamic shortcuts per activity
/// (commonly 15) and silently rejects the rest, so publish the most recent few
/// deliberately rather than discovering the ceiling by accident.
const maxShareShortcuts = 8;

/// The pair a shortcut id encodes. `|` cannot occur in either half: an account
/// id is bech32m (see pkg/address) and a peer id is one too.
class ShortcutTarget {
  const ShortcutTarget({required this.accountId, required this.peerAccountId});

  final String accountId;
  final String peerAccountId;
}

String shortcutIdFor({
  required String accountId,
  required String peerAccountId,
}) => '$accountId|$peerAccountId';

/// Parses a shortcut id back into its pair, or null if [id] is absent or not
/// one of ours -- a share from the plain share sheet has no shortcut id at all.
ShortcutTarget? shortcutTarget(String? id) {
  if (id == null) return null;
  final parts = id.split('|');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  return ShortcutTarget(accountId: parts[0], peerAccountId: parts[1]);
}

/// One chat as the platform needs it to build a shortcut.
class ShareShortcut {
  const ShareShortcut({
    required this.id,
    required this.label,
    required this.iconPng,
  });

  final String id;

  /// What the share sheet shows. Whatever this is, it becomes readable outside
  /// the app -- see the header comment.
  final String label;

  /// The avatar, rendered by us so the share sheet shows the same face the
  /// chat list does.
  final Uint8List iconPng;

  Map<String, Object?> toMap() => {
    'id': id,
    'label': label,
    'iconPng': iconPng,
  };
}

/// Replaces the published set with [shortcuts], in order (most recent first).
/// Failures are swallowed: a share shortcut is a convenience, and no part of
/// messaging depends on it.
Future<void> publishShareShortcuts(List<ShareShortcut> shortcuts) async {
  try {
    await _channel.invokeMethod('publish', {
      'shortcuts': shortcuts.map((s) => s.toMap()).toList(),
    });
  } on MissingPluginException {
    // not Android
  } on PlatformException {
    // nothing to do about it, and nothing depends on it
  }
}

/// Removes every shortcut we published. Called when the setting is turned off,
/// and when the last account goes away -- a shortcut outliving its account
/// would keep showing a name that should be gone.
Future<void> clearShareShortcuts() async {
  try {
    await _channel.invokeMethod('clear');
  } on MissingPluginException {
    // not Android
  } on PlatformException {
    // ignore
  }
}

/// Brings the published set in line with the current conversations, or clears
/// it when the setting is off.
///
/// Called on startup and whenever the app is resumed, rather than on every
/// change to a conversation: a share shortcut is a convenience, so it is worth
/// neither the churn of republishing per message nor listeners on every
/// session. The visible consequence is a lag -- a chat deleted while the app is
/// in the foreground stays offered until the next resume. Turning the setting
/// off is the one case that must be immediate, and it is, because
/// [clearShareShortcuts] runs right there.
Future<void> syncShareShortcuts(
  AccountManager manager,
  AppSettings settings,
  ContactStore contacts,
) async {
  if (!settings.directShareEnabled) {
    await clearShareShortcuts();
    return;
  }

  // Most recently active first, across all accounts, so the row shows who the
  // user actually talks to rather than whichever account happens to be first.
  final candidates =
      <({String accountId, String peerAccountId, String label, DateTime at})>[];
  for (final session in manager.sessions) {
    for (final convo in session.conversations) {
      // Never offer a chat the user hasn't accepted or has blocked: it would
      // put a stranger's or a blocked contact's name into the share sheet.
      if (convo.pendingApproval || convo.blocked) continue;
      candidates.add((
        accountId: session.state.accountId,
        peerAccountId: convo.peerAccountId,
        label: convo.titleFor(session.state.server, contacts),
        at: convo.lastActivityAt,
      ));
    }
  }
  candidates.sort((a, b) => b.at.compareTo(a.at));

  final shortcuts = <ShareShortcut>[];
  for (final c in candidates.take(maxShareShortcuts)) {
    shortcuts.add(
      ShareShortcut(
        id: shortcutIdFor(
          accountId: c.accountId,
          peerAccountId: c.peerAccountId,
        ),
        label: c.label,
        iconPng: await renderAvatarPng(c.peerAccountId) ?? Uint8List(0),
      ),
    );
  }

  if (shortcuts.isEmpty) {
    // No eligible chats: clear rather than publish nothing, so a set from an
    // earlier run doesn't linger.
    await clearShareShortcuts();
    return;
  }
  await publishShareShortcuts(shortcuts);
}
