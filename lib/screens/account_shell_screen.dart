// Wraps ChatListScreen with an account switcher strip -- one avatar per
// connected account (all of which stay live in the background regardless
// of which is shown, see AccountManager), plus "+" to add another.
// Rendered via ChatListScreen's appBarBottom slot (AppBar.bottom) rather
// than stacked above the whole screen as a separate widget -- that keeps
// it seamlessly attached to the "Freizone" title bar (no gap) and lets
// Flutter's usual AppBar-driven status bar icon styling keep working,
// since there's still exactly one AppBar at the top of the widget tree.
import 'package:flutter/material.dart';

import '../state/account_manager.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../util/avatar_color.dart';
import '../util/role_icon.dart';
import '../util/server_label.dart';
import '../util/server_url.dart';
import '../util/unread_dot.dart';
import 'chat_list_screen.dart';
import 'profile_screen.dart';
import 'setup_screen.dart';

class AccountShellScreen extends StatefulWidget {
  const AccountShellScreen({
    super.key,
    required this.manager,
    required this.settings,
  });

  final AccountManager manager;
  final AppSettings settings;

  @override
  State<AccountShellScreen> createState() => _AccountShellScreenState();
}

class _AccountShellScreenState extends State<AccountShellScreen> {
  /// Gap between a group divider and its label -- kept equal to the
  /// gap between the label and the group's first icon (the latter is
  /// just that first avatar's own leading padding, not a second
  /// spacer), so the two don't visually read as different amounts.
  static const _labelGap = 4.0;

  /// One stable [GlobalKey] per account, so the active one's on-screen
  /// position can be found (see [_ensureActiveVisible]) regardless of
  /// how the switcher's own ListView has scrolled -- created lazily and
  /// kept for the account's lifetime rather than recreated every build,
  /// since a GlobalKey only usefully identifies the same element across
  /// rebuilds if the key instance itself is reused.
  final Map<String, GlobalKey> _avatarKeys = {};

  /// The account last scrolled into view -- lets [_ensureActiveVisible]
  /// tell "the active account just changed" (switch via tap, via a
  /// ChatListScreen swipe, or on first load) apart from "the switcher is
  /// merely rebuilding for an unrelated reason" (a badge update, ...),
  /// so it doesn't fight a manual scroll of the strip by re-centering on
  /// every rebuild.
  String? _lastVisibleAccountId;

  GlobalKey _avatarKeyFor(String accountId) =>
      _avatarKeys.putIfAbsent(accountId, () => GlobalKey());

  void _ensureActiveVisible(AppSession active) {
    final accountId = active.state.accountId;
    if (accountId == _lastVisibleAccountId) return;
    _lastVisibleAccountId = accountId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _avatarKeys[accountId]?.currentContext;
      if (context == null || !context.mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 250),
        curve: Curves.ease,
      );
    });
  }

  Future<void> _addAccount(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SetupScreen(
          onRegistered: (state) => widget.manager.addProfile(state),
          existingServers: widget.manager.sessions
              .map((s) => s.state.server)
              .toList(),
          isAddingAccount: true,
        ),
      ),
    );
  }

  void _openProfile(BuildContext context, AppSession session) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ProfileScreen(session: session, manager: widget.manager),
      ),
    );
  }

  /// Buckets sessions by server (via [sameServer], not raw string
  /// equality -- two accounts on "chat.example.org" and
  /// "https://chat.example.org" belong in the same group), preserving
  /// each session's original relative order and each group's
  /// first-appearance order.
  List<List<AppSession>> _groupSessionsByServer(List<AppSession> sessions) {
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

  Widget _buildSwitcher(BuildContext context, AppSession? active) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      // Same reasoning as ChatListScreen's AppBar: a solid white strip
      // would glare at night, so dark mode swaps it for a themed dark
      // grey. The role-badge overlay below keeps its own white circle
      // behind the glyph, so it stays legible against either background.
      color: isDark ? Theme.of(context).colorScheme.surfaceContainerHigh : Colors.white,
      height: 72,
      // Listens to every session directly (not just `manager`) so a
      // badge -- an incoming message, a role change picked up by
      // AccountManager.setActive's refresh -- updates live without
      // needing an account switch to force a rebuild.
      child: ListenableBuilder(
        listenable: Listenable.merge(widget.manager.sessions),
        builder: (context, _) {
          final groups = _groupSessionsByServer(widget.manager.sessions);
          final allServers = widget.manager.sessions
              .map((s) => s.state.server)
              .toList();
          return ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            children: [
              for (var gi = 0; gi < groups.length; gi++) ...[
                // No divider before the very first group -- nothing to
                // its left to separate it from. The divider's own
                // margin provides both of its gaps -- the last avatar
                // of the previous group drops its own trailing padding
                // (below) so it isn't doubled up on top of this. The
                // left gap is deliberately wider than the right: an
                // equal box-level gap on both sides still read as
                // tighter against a solid 48dp circle (which fills its
                // box edge-to-edge) than against the label's rotated
                // text (whose own glyph ink sits inset from its box by
                // a few dp of font-metric padding/side-bearing) --
                // matching perceived spacing needs a larger literal
                // value on the icon side, not an equal one.
                if (gi > 0)
                  Container(
                    width: 1,
                    margin: const EdgeInsets.only(
                      top: 12,
                      bottom: 12,
                      left: _labelGap * 2,
                      right: _labelGap,
                    ),
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                // The SizedBox constrains the *pre-rotation* width of
                // the text -- which becomes the vertical run-length
                // available to it once RotatedBox turns it 90 degrees
                // CCW -- rather than wrapping the already-rotated box,
                // which would instead force a wide, mostly-empty slot
                // in the row itself.
                RotatedBox(
                  quarterTurns: 3,
                  child: SizedBox(
                    width: 60,
                    child: Text(
                      shortServerLabel(
                        groups[gi].first.state.server,
                        allServers,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                for (final session in groups[gi])
                  Padding(
                    key: _avatarKeyFor(session.state.accountId),
                    // The last avatar in a group that's followed by
                    // another group skips its own trailing gap --
                    // the next divider's margin provides that gap
                    // instead (see above), so it isn't doubled up.
                    padding: (session == groups[gi].last && gi < groups.length - 1)
                        ? const EdgeInsets.only(left: 4)
                        : const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onTap: () =>
                          widget.manager.setActive(session.state.accountId),
                      onLongPress: () => _openProfile(context, session),
                      child: CircleAvatar(
                        radius: 24,
                        backgroundColor: avatarColorFor(
                          session.state.accountId,
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Center(
                              child: Text(
                                session.state.accountId
                                    .substring(0, 2)
                                    .toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (session == active)
                              Positioned(
                                bottom: -4,
                                left: 16,
                                right: 16,
                                child: Container(
                                  height: 3,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            if (roleBadgeIcon(session.myRole) case final icon?)
                              Positioned(
                                bottom: -3,
                                right: -3,
                                child: CircleAvatar(
                                  radius: 12,
                                  backgroundColor: Colors.white,
                                  child: Icon(
                                    icon,
                                    size: 16,
                                    color: Colors.black87,
                                  ),
                                ),
                              ),
                            if (session.hasAnyUnread)
                              // Closer to the avatar than the role/active
                              // indicators -- keeps the group tighter
                              // now that each group also carries a
                              // label, rather than protruding further
                              // out past the circle's edge.
                              const Positioned(
                                top: 0,
                                right: 0,
                                child: UnreadDot(),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Tooltip(
                  message: 'Add account',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => _addAccount(context),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                      child: Icon(
                        Icons.add,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.manager,
      builder: (context, _) {
        final active = widget.manager.active;
        if (active == null) {
          return const Scaffold(
            body: Center(child: Text('No account selected')),
          );
        }
        _ensureActiveVisible(active);
        return ChatListScreen(
          session: active,
          settings: widget.settings,
          manager: widget.manager,
          appBarBottom: PreferredSize(
            preferredSize: const Size.fromHeight(72),
            child: _buildSwitcher(context, active),
          ),
        );
      },
    );
  }
}
