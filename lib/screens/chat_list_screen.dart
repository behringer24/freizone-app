// The post-setup home screen: a WhatsApp/Telegram/Signal-style chat
// list. Rebuilds live off AppSession (ListenableBuilder) -- so a
// message arriving for a conversation that isn't open still updates
// its preview/ordering here, since AppSession owns the SSE stream for
// the whole app lifetime, not just while a chat screen happens to be
// open.
import 'package:flutter/material.dart';

import '../state/account_manager.dart';
import '../push/push_manager.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../state/conversation.dart';
import '../state/group_conversation.dart';
import '../util/block_actions.dart';
import '../util/errors.dart';
import '../util/group_actions.dart';
import '../util/unread_dot.dart';
import '../widgets/new_chat_sheet.dart';
import '../widgets/peer_avatar.dart';
import 'admin_screen.dart';
import 'backup_screen.dart';
import 'blocked_contacts_screen.dart';
import 'chat_screen.dart';
import 'group_chat_screen.dart';
import 'invite_screen.dart';
import 'my_address_screen.dart';
import 'settings_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({
    super.key,
    required this.session,
    required this.settings,
    required this.manager,
    this.appBarBottom,
  });

  final AppSession session;
  final AppSettings settings;

  /// Needed only to forward into SettingsScreen, so changing the push
  /// delivery preference there can re-register push on every live
  /// session immediately (see SettingsScreen._setPushPreference).
  final AccountManager manager;

  /// Rendered directly below the "Freizone" title bar, as part of the
  /// same AppBar -- e.g. the account switcher strip (AccountShellScreen).
  /// Using AppBar.bottom rather than stacking a separate widget above
  /// this whole screen keeps the status bar icon styling (which Flutter
  /// derives from the topmost AppBar) correct and avoids a seam/gap
  /// between the two.
  final PreferredSizeWidget? appBarBottom;

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  late final PageController _pageController;

  int _indexOf(AppSession session) => widget.manager.orderedSessions.indexWhere(
    (s) => s.state.accountId == session.state.accountId,
  );

  @override
  void initState() {
    super.initState();
    final initial = _indexOf(widget.session);
    _pageController = PageController(initialPage: initial < 0 ? 0 : initial);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Keeps the swipeable body in sync with account switches that
  /// originate elsewhere (tapping an avatar in the switcher strip) --
  /// [_onPageChanged] handles the reverse direction (a swipe here
  /// driving [AccountManager.setActive]). Guarded so the two don't fight
  /// each other: a swipe-driven switch already lands on the right page,
  /// so this only actually animates for an externally-driven one.
  @override
  void didUpdateWidget(ChatListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.session.state.accountId == oldWidget.session.state.accountId)
      return;
    final target = _indexOf(widget.session);
    if (target < 0 || !_pageController.hasClients) return;
    if (_pageController.page?.round() == target) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.ease,
    );
  }

  void _onPageChanged(int index) {
    final sessions = widget.manager.orderedSessions;
    if (index < 0 || index >= sessions.length) return;
    final target = sessions[index];
    if (target.state.accountId != widget.session.state.accountId) {
      widget.manager.setActive(target.state.accountId);
    }
  }

  /// One chat-list row, for either kind of chat.
  ///
  /// Groups sit in the same list as one-to-one chats rather than behind a tab,
  /// so there is exactly one place that answers "what is new" -- and the
  /// horizontal swipe is already taken by switching accounts.
  Widget _buildChatTile(
    BuildContext context,
    AppSession session,
    ChatTarget chat,
  ) => chat is GroupConversation
      ? _buildGroupTile(context, session, chat)
      : _buildConversationTile(context, session, chat as Conversation);

  Widget _buildGroupTile(
    BuildContext context,
    AppSession session,
    GroupConversation group,
  ) {
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          // A group id is the same 21-character bech32m string an account id
          // is, so the deterministic avatar colour works unchanged.
          PeerAvatar(accountId: group.groupId, radius: 20),
          if (group.hasUnread)
            const Positioned(top: -2, right: -2, child: UnreadDot()),
        ],
      ),
      title: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(
              Icons.group,
              size: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Text(
              group.titleFor(session.state.server),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Text(
        group.invitePending
            ? 'You have been invited to this group'
            : group.lastMessagePreview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: group.invitePending
            ? TextStyle(color: Theme.of(context).colorScheme.primary)
            : null,
      ),
      trailing: Text(
        _formatTimestamp(group.lastActivityAt),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => GroupChatScreen(
            session: session,
            groupId: group.groupId,
            settings: widget.settings,
          ),
        ),
      ),
      // The same gesture a one-to-one row answers. It is the only route to
      // removing a group whose fact set failed to load, since the group screen
      // and its info screen both need that fact set to render anything.
      onLongPress: () => showRemoveGroupDialog(context, session, group),
    );
  }

  /// Shared between the "Message requests" section and the regular list --
  /// both need the exact same tile, since the preview text (a request's
  /// greeting, if any) is what actually answers "who is this."
  Widget _buildConversationTile(
    BuildContext context,
    AppSession session,
    Conversation convo,
  ) {
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          PeerAvatar(accountId: convo.peerAccountId, radius: 20),
          if (convo.hasUnread)
            const Positioned(top: -2, right: -2, child: UnreadDot()),
        ],
      ),
      title: Row(
        children: [
          if (session.federationLocked(convo))
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                Icons.lock,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          Expanded(
            child: Text(
              convo.titleFor(session.state.server),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Text(
        convo.lastMessagePreview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        _formatTimestamp(convo.lastActivityAt),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            session: session,
            peerAccountId: convo.peerAccountId,
            settings: widget.settings,
          ),
        ),
      ),
      onLongPress: () => _showChatOptions(context, session, convo),
    );
  }

  String _formatTimestamp(DateTime utc) {
    final dt = utc.toLocal();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');

    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${two(dt.hour)}:${two(dt.minute)}';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day) {
      return 'Yesterday';
    }
    return '${two(dt.day)}.${two(dt.month)}.${dt.year}';
  }

  /// Whether this device can currently show an "Invite" action: nobody
  /// can on a closed server; on an invite server only admin/moderator
  /// (matches the server-side gate on POST /v1/admin/invites); on an
  /// open server, everyone (no code needed, so there's nothing to gate).
  bool _canInvite(AppSession session) {
    switch (session.registrationPolicy) {
      case 'open':
        return true;
      case 'invite':
        return session.myRole == 'admin' || session.myRole == 'moderator';
      default:
        return false;
    }
  }

  /// Long-press menu for a chat row: clear its history or delete it
  /// entirely, both purely local (the server never stored the history
  /// in the first place). Either action asks for confirmation first,
  /// since there's no undo.
  ///
  /// A still-open, unactioned message request (see [Conversation.
  /// pendingApproval]) gets Accept/Block here instead -- Clear/Delete
  /// don't answer the actual open question ("do I want to talk to this
  /// person"), and deleting would just let them silently ask again the
  /// next time they write (see AppSession.deleteConversation).
  Future<void> _showChatOptions(
    BuildContext context,
    AppSession session,
    Conversation convo,
  ) async {
    if (convo.pendingApproval) {
      final action = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(convo.titleFor(session.state.server)),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('accept'),
              child: const Text('Accept'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('block'),
              child: const Text('Block'),
            ),
          ],
        ),
      );
      if (action == null || !context.mounted) return;
      if (action == 'accept') {
        await session.acceptConversation(convo.peerAccountId);
      } else if (action == 'block') {
        await confirmAndBlock(context, session, convo);
      }
      return;
    }

    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(convo.titleFor(session.state.server)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('clear'),
            child: const Text('Clear chat'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('delete'),
            child: const Text('Delete chat'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('reset'),
            child: const Text('Reset secure session'),
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;

    if (action == 'clear') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Clear chat?'),
          content: Text(
            'This permanently deletes the message history with ${convo.titleFor(session.state.server)} on this device. '
            'The conversation itself stays -- this cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear'),
            ),
          ],
        ),
      );
      if (confirmed == true)
        await session.clearConversation(convo.peerAccountId);
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete chat?'),
          content: Text(
            'This permanently removes the conversation with ${convo.titleFor(session.state.server)} and its message history from '
            'this device -- this cannot be undone. ${convo.titleFor(session.state.server)} still exists; you can start a new chat with '
            'them again any time.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true)
        await session.deleteConversation(convo.peerAccountId);
    } else if (action == 'reset') {
      await confirmAndResetSession(context, session, convo);
    }
  }

  /// Founds a group. Local only until somebody is invited -- there is no
  /// server to register it with.
  Future<void> _createGroup(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Group name'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !context.mounted) return;

    try {
      final group = await widget.session.createGroup(name: name);
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => GroupChatScreen(
            session: widget.session,
            groupId: group.groupId,
            settings: widget.settings,
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  Future<void> _openNewChatSheet(BuildContext context) async {
    final peerAccountId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => NewChatSheet(session: widget.session),
    );
    if (peerAccountId == null || !context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          session: widget.session,
          peerAccountId: peerAccountId,
          settings: widget.settings,
        ),
      ),
    );
  }

  /// The scrollable conversation list for one account -- pulled out of
  /// [build] so it can be reused per-page in the swipeable [PageView]
  /// below, each page bound to a different account's own [AppSession]
  /// rather than always the active one.
  Widget _buildBody(BuildContext context, AppSession session) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        // One-time push hint -- but never while this account's server is
        // unreachable: that state is already shown by the offline marking,
        // and the registration "failure" is just the dead server, not a push
        // setup problem. Left pending (not consumed) until reachable, so the
        // reconnect's re-registration can settle the real status first.
        if (session.pushHintPending &&
            session.reachability != ServerReachability.unreachable) {
          session.pushHintPending = false; // consume it
          final message = switch (session.pushRegistration) {
            PushRegistration.needsDistributorChoice =>
              'Choose a push target in Settings > Push delivery. '
                  'Chat still works while Freizone is open.',
            PushRegistration.unavailable =>
              'No push notifications available -- install a UnifiedPush app '
                  '(e.g. ntfy) or switch to Firebase (FCM) in Settings > Push '
                  'delivery. Chat still works while Freizone is open.',
            PushRegistration.registered => null,
          };
          if (message != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(message),
                  duration: const Duration(seconds: 6),
                ),
              );
            });
          }
        }

        // One-time nudge to back up the recovery phrase, shown above the list
        // (and the empty state) until the user backs up or dismisses it. Never
        // shown for a recovered account (recoveryBackupDone is set from the
        // start there). See APP-01.
        final nudge = session.state.recoveryBackupDone
            ? null
            : _buildBackupNudge(context, session);
        // Above the backup nudge: a delivery that failed is about right now,
        // while backing up the phrase can wait for the next screen.
        final error = _buildErrorBanner(context, session);

        final all = session.chats;
        if (all.isEmpty) {
          return _withBanners(
            [error, nudge],
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No conversations yet',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text('Tap the button below to start one'),
                ],
              ),
            ),
          );
        }

        // The filter sits above the list *body*, not in the AppBar: a third
        // permanent bar under the title and the account strip would cost too
        // much vertical space, and this is a filter rather than a navigation
        // level -- so it also introduces no conflict with the horizontal swipe
        // between accounts.
        final chips = _buildFilterChips(context, all);
        final conversations = all.where(_filter.matches).toList();
        if (conversations.isEmpty) {
          return _withBanners(
            [error, nudge, chips],
            Center(
              child: Text(
                _filter.emptyLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          );
        }

        // Unactioned message requests (first contact from someone with
        // no prior conversation, see Conversation.pendingApproval) are
        // surfaced above everything else, so they're never buried among
        // regular chats -- but rendered with the exact same tile, since
        // the preview text (their greeting, if any) is what actually
        // answers "who is this."
        final pending = conversations
            .whereType<Conversation>()
            .where((c) => c.pendingApproval)
            .toList();
        final regular = conversations
            .where((c) => c is! Conversation || !c.pendingApproval)
            .toList();

        // A tonal surface a step above the plain background -- Material
        // 3's surfaceContainer* tokens are built exactly for this ("a
        // panel that reads as a distinct area, without a hard border or
        // shadow") and, being derived from the seed color per brightness,
        // land a little darker in light mode and a little lighter in
        // dark mode automatically, rather than needing a manual
        // Brightness check here.
        final requestsSurface = Theme.of(
          context,
        ).colorScheme.surfaceContainerHigh;

        return _withBanners(
          [error, nudge, chips],
          CustomScrollView(
          slivers: [
            if (pending.isNotEmpty)
              SliverToBoxAdapter(
                child: Container(
                  color: requestsSurface,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          'Message requests',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ),
                      for (final convo in pending) ...[
                        _buildChatTile(context, session, convo),
                        if (convo != pending.last)
                          const Divider(height: 1, indent: 72),
                      ],
                      // A visibly heavier rule than the hairline dividers
                      // used between individual rows -- marks this as a
                      // section boundary, not just another list item.
                      Divider(
                        height: 1,
                        thickness: 2,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ],
                  ),
                ),
              ),
            SliverList.separated(
              itemCount: regular.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (context, i) =>
                  _buildChatTile(context, session, regular[i]),
            ),
          ],
          ),
        );
      },
    );
  }

  /// Which chats the list is showing. In memory rather than persisted: a filter
  /// is where you are looking right now, and coming back to a list that silently
  /// hides most of it is the kind of state nobody remembers setting.
  _ChatFilter _filter = _ChatFilter.all;

  Widget _buildFilterChips(BuildContext context, List<ChatTarget> all) {
    // Counted over everything, not over the filtered view, so the numbers do not
    // change as you switch between them.
    final unread = all.where((c) => c.hasUnread).length;
    final groups = all.whereType<GroupConversation>().length;
    // Nothing to filter: one chat kind and nothing unread means three chips that
    // all show the same list.
    if (unread == 0 && (groups == 0 || groups == all.length)) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          for (final filter in _ChatFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(switch (filter) {
                  _ChatFilter.all => 'All',
                  _ChatFilter.unread => 'Unread ($unread)',
                  _ChatFilter.groups => 'Groups ($groups)',
                }),
                selected: _filter == filter,
                onSelected: (_) => setState(() => _filter = filter),
              ),
            ),
        ],
      ),
    );
  }

  /// Stacks whichever of [banners] are present above [body], so a prompt or a
  /// warning appears over both the conversation list and the empty state.
  Widget _withBanners(List<Widget?> banners, Widget body) {
    final present = banners.whereType<Widget>().toList();
    if (present.isEmpty) return body;
    return Column(children: [...present, Expanded(child: body)]);
  }

  /// The last thing that went wrong in an account, kept until the user
  /// acknowledges it -- keyed by account id, since the [PageView] builds one
  /// body per account.
  ///
  /// AppSession.lastError is transient: the next envelope that decrypts cleanly
  /// sets it back to null. Reading it straight into the banner would therefore
  /// flash a failure for a moment and then lose it, which is the opposite of
  /// what a failure needs -- a group fact that never went out is worth knowing
  /// about ten minutes later.
  final Map<String, String> _stickyErrors = {};

  Widget? _buildErrorBanner(BuildContext context, AppSession session) {
    // Captured during build on purpose: this builder runs *because* the session
    // notified, so the value is picked up and rendered in the same frame.
    final live = session.lastError;
    if (live != null) _stickyErrors[session.state.accountId] = live;
    final message = _stickyErrors[session.state.accountId];
    if (message == null) return null;

    final theme = Theme.of(context);
    return MaterialBanner(
      backgroundColor: theme.colorScheme.errorContainer,
      leading: Icon(
        Icons.warning_amber,
        color: theme.colorScheme.onErrorContainer,
      ),
      content: Text(
        message,
        style: TextStyle(color: theme.colorScheme.onErrorContainer),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            _stickyErrors.remove(session.state.accountId);
            // Cleared on the session too, or the next rebuild would simply
            // re-capture the same line.
            session.lastError = null;
          }),
          child: const Text('Dismiss'),
        ),
      ],
    );
  }

  Widget _buildBackupNudge(BuildContext context, AppSession session) {
    final theme = Theme.of(context);
    return MaterialBanner(
      backgroundColor: theme.colorScheme.secondaryContainer,
      leading: Icon(Icons.key, color: theme.colorScheme.onSecondaryContainer),
      content: Text(
        'Back up your recovery phrase so you can restore this account if you '
        'lose this device.',
        style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
      ),
      actions: [
        TextButton(
          onPressed: () => session.markRecoveryBackupDone(),
          child: const Text('Dismiss'),
        ),
        FilledButton(
          onPressed: () {
            // Engaging with the prompt settles it either way; the phrase
            // stays reachable from the profile screen afterward.
            session.markRecoveryBackupDone();
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    BackupScreen(rootPriv: session.state.rootPriv),
              ),
            );
          },
          child: const Text('Back up now'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final session = widget.session;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Freizone',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: isDark
                ? Colors.white
                : Theme.of(context).colorScheme.primary,
          ),
        ),
        // A pure-light background (as used in light mode) would glare at
        // night, so dark mode swaps it for a themed dark grey -- the
        // admin/moderator role badges keep their own white circle behind
        // the glyph (see role_icon.dart usage below), so they stay legible
        // either way.
        backgroundColor: isDark
            ? Theme.of(context).colorScheme.surfaceContainerHigh
            : Colors.grey.shade100,
        bottom: widget.appBarBottom,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'my_address') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MyAddressScreen(session: session),
                  ),
                );
              }
              if (value == 'admin') {
                Navigator.of(context)
                    .push(
                      MaterialPageRoute(
                        builder: (_) => AdminScreen(
                          session: session,
                          settings: widget.settings,
                        ),
                      ),
                    )
                    .then((_) => session.refreshRegistrationPolicy());
              }
              if (value == 'invite') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => InviteScreen(session: session),
                  ),
                );
              }
              if (value == 'blocked') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BlockedContactsScreen(session: session),
                  ),
                );
              }
              if (value == 'new_group') {
                _createGroup(context);
              }
              if (value == 'settings') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(
                      settings: widget.settings,
                      manager: widget.manager,
                    ),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'my_address',
                child: Text('Invite to chat'),
              ),
              if (_canInvite(session))
                const PopupMenuItem(
                  value: 'invite',
                  child: Text('Invite to server'),
                ),
              if (session.myRole == 'admin' || session.myRole == 'moderator')
                const PopupMenuItem(
                  value: 'admin',
                  child: Text('Server Admin'),
                ),
              const PopupMenuItem(
                value: 'blocked',
                child: Text('Blocked contacts'),
              ),
              const PopupMenuItem(value: 'new_group', child: Text('New group')),
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      // Swipeable so a horizontal drag switches accounts just like tapping
      // an avatar in the switcher strip above -- see _onPageChanged/
      // didUpdateWidget for how the two stay in sync with each other.
      // Uses AccountManager.orderedSessions (not the raw .sessions list),
      // the same canonical left-to-right order the switcher strip groups
      // by server -- otherwise swiping would traverse a different order
      // than what's shown above whenever accounts span more than one
      // server. AccountShellScreen's own ListenableBuilder(listenable:
      // manager) already rebuilds this whole screen (with a fresh read
      // below) on every account add/remove/switch, so this doesn't need
      // its own separate listener on widget.manager.
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.manager.orderedSessions.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) =>
            _buildBody(context, widget.manager.orderedSessions[index]),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openNewChatSheet(context),
        // Explicit rather than the Material 3 default (colorScheme.
        // primaryContainer, a much lighter tone) -- matches the darker
        // teal used for the user's own message bubbles in chat_screen.dart.
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        child: const Icon(Icons.chat),
      ),
    );
  }
}

/// The chat list's filter: All / Unread / Groups, per the design document.
///
/// Deliberately not a tab bar. Tabs would say "these are separate places", and
/// the whole point of one list is that there is exactly one place that answers
/// "what is new" -- these only narrow it.
enum _ChatFilter {
  all,
  unread,
  groups;

  bool matches(ChatTarget chat) => switch (this) {
    _ChatFilter.all => true,
    _ChatFilter.unread => chat.hasUnread,
    _ChatFilter.groups => chat is GroupConversation,
  };

  /// What to say when the filter itself is why the list is empty -- distinct
  /// from the "no conversations yet" empty state, which is about the account.
  String get emptyLabel => switch (this) {
    _ChatFilter.all => 'No conversations yet',
    _ChatFilter.unread => 'Nothing unread',
    _ChatFilter.groups => 'No groups yet',
  };
}
