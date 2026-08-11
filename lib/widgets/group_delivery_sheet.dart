// The per-member delivery sheet behind a group bubble's k-of-N indicator
// (APP-16). The bubble deliberately shows only counts -- who is who is a
// question asked occasionally and on purpose, not something to carry in every
// bubble forever.
import 'package:flutter/material.dart';

import '../state/app_session.dart';
import '../state/chat_target.dart';
import '../state/contact_store.dart';
import '../state/group_conversation.dart';
import '../util/errors.dart';
import '../util/person_label.dart';
import 'peer_avatar.dart';

/// Opens the delivery sheet for one of this account's own group messages.
///
/// Rebuilds while it is open: a receipt arriving from a member who was
/// outstanding is exactly what someone has this sheet open to see.
Future<void> showGroupDeliverySheet(
  BuildContext context, {
  required AppSession session,
  required String groupId,
  required String messageId,
  required ContactStore contacts,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        // Re-read on every rebuild rather than captured: the message object is
        // mutated in place by the fan-out, and the group can be left or
        // removed from another screen while this is open.
        final chat = session.state.groups[groupId];
        final message = chat?.messageById(messageId);
        if (chat == null || message == null) {
          return const _SheetFrame(
            children: [
              ListTile(title: Text('This message is no longer on this device.')),
            ],
          );
        }
        return _DeliveryList(
          session: session,
          chat: chat,
          message: message,
          contacts: contacts,
        );
      },
    ),
  );
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        // Bounded so a 50-member group scrolls inside the sheet instead of
        // pushing it past the top of the screen.
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: ListView(shrinkWrap: true, children: children),
        ),
      ),
    );
  }
}

class _DeliveryList extends StatelessWidget {
  const _DeliveryList({
    required this.session,
    required this.chat,
    required this.message,
    required this.contacts,
  });

  final AppSession session;
  final GroupConversation chat;
  final StoredMessage message;

  /// Where a recipient's name comes from (APP-18): "not delivered" is only
  /// actionable if you can tell who it is about.
  final ContactStore contacts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Worst first, then by account id -- so the members something can be done
    // about are at the top, and the order cannot reshuffle between rebuilds
    // (the rule APP-10 settled for the admin user list).
    final rows = [...message.deliveries]
      ..sort((a, b) {
        final byStage = chat
            .stageFor(message, a)
            .index
            .compareTo(chat.stageFor(message, b).index);
        return byStage != 0 ? byStage : a.accountId.compareTo(b.accountId);
      });
    final anyFailed = message.deliveries.any(
      (d) => d.state == MessageSendState.failed,
    );

    return _SheetFrame(
      children: [
        ListTile(
          title: Text('Delivery', style: theme.textTheme.titleMedium),
          subtitle: Text(_summary()),
        ),
        if (rows.isEmpty)
          // A group whose only other members are pending invitees: nobody was
          // owed a copy, which is not the same as nobody having received one.
          const ListTile(
            title: Text('Nobody was owed a copy of this message yet.'),
            subtitle: Text(
              'A copy goes only to members who have accepted their invitation.',
            ),
          ),
        for (final delivery in rows)
          _DeliveryRow(
            stage: chat.stageFor(message, delivery),
            delivery: delivery,
            contacts: contacts,
          ),
        if (anyFailed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: FilledButton.icon(
              onPressed: () => _retry(context),
              icon: const Icon(Icons.refresh),
              // Says what it will not do as much as what it will: the copies
              // that arrived are never re-sent, so nobody gets it twice.
              label: const Text('Resend to those it failed for'),
            ),
          ),
      ],
    );
  }

  String _summary() {
    final owed = message.deliveries.length;
    if (owed == 0) return 'No recipients';
    final read = chat.readCountFor(message);
    final received = chat.deliveredCountFor(message);
    if (read >= owed) return 'Read by all $owed';
    if (read > 0) return 'Read by $read of $owed · received by $received';
    return 'Received by $received of $owed';
  }

  Future<void> _retry(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    try {
      await session.retryGroupSend(chat.groupId, message.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }
}

class _DeliveryRow extends StatelessWidget {
  const _DeliveryRow({
    required this.stage,
    required this.delivery,
    required this.contacts,
  });

  final GroupDeliveryStage stage;
  final GroupDelivery delivery;
  final ContactStore contacts;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, label) = switch (stage) {
      GroupDeliveryStage.failed => (Icons.error_outline, 'Not delivered'),
      GroupDeliveryStage.sending => (Icons.schedule, 'Sending'),
      GroupDeliveryStage.sent => (Icons.done, 'Sent, not confirmed yet'),
      GroupDeliveryStage.received => (Icons.done_all, 'Received'),
      GroupDeliveryStage.read => (Icons.done_all, 'Read'),
    };
    final tint = switch (stage) {
      GroupDeliveryStage.failed => colorScheme.error,
      GroupDeliveryStage.read => colorScheme.primary,
      _ => colorScheme.onSurfaceVariant,
    };

    // The picture note is not a delivery state: the message itself arrived.
    // Shown alongside the state rather than instead of it, or a member who got
    // the caption would read as not having got the message.
    final detail = [
      label,
      if (delivery.attachmentSkipped) 'picture not received',
      // Recorded with the failure and replayed with the transcript, so a
      // fan-out that failed overnight can still be read in the morning. Cleared
      // the moment the copy arrives, so it can never describe a state that has
      // since moved on.
      if (stage == GroupDeliveryStage.failed && delivery.error != null)
        delivery.error!,
    ].join(' · ');

    return ListTile(
      leading: PeerAvatar(accountId: delivery.accountId, radius: 20),
      title: Text(
        personLabel(contacts, delivery.accountId),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(detail, style: TextStyle(color: tint)),
      trailing: Icon(icon, size: 18, color: tint),
    );
  }
}
