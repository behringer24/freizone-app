// Who a group reply's quote block should name (APP-17).
//
// Pure, and separate from the screen, because it is a four-branch fallback
// chain rather than a lookup: what the sender said, what this device happens
// to still hold, what `mine` implies, and -- last -- nothing. The one outcome
// that must never happen is a confident wrong name, so the chain is worth
// testing on its own.
import '../state/chat_target.dart';
import '../state/contact_store.dart';
import 'person_label.dart';

/// The resolved author of a quoted message, ready to render.
class QuotedAuthor {
  const QuotedAuthor({this.label, this.accountId});

  /// What to show above the quote. **Null means draw no author line**: this
  /// device cannot say who wrote the quoted message, and a quote that stays
  /// silent about it is better than one that guesses.
  final String? label;

  /// The author's account id, when known -- for colouring the label the way
  /// the transcript and member list colour the same person. Null when the
  /// author is this account (nothing to distinguish) or unknown.
  final String? accountId;

  /// Nothing can be said about this author.
  static const unknown = QuotedAuthor();
}

/// Resolves the author of the message [reply] quotes.
///
/// The label is the same `personLabel` the transcript's author lines and the
/// member list use, so the same person reads identically in all three (APP-18).
///
/// In order: the author id the sender stated (APP-17's wire field), then the
/// quoted message in local history, then -- with no id available at all --
/// the perspective bit `mine`, which answers the single case that needs no
/// id. A reply from a build predating the wire field, quoting a message this
/// device never received or has since deleted, resolves to
/// [QuotedAuthor.unknown].
QuotedAuthor resolveQuotedAuthor({
  required StoredMessage reply,
  required ChatTarget chat,
  required String myAccountId,
  required ContactStore contacts,
}) {
  final id = _authorIdFor(reply, chat, myAccountId);
  if (id == null) {
    // No id anywhere. `mine` still distinguishes "you wrote it" from "somebody
    // did", and only the first of those is a name.
    return reply.replyPreviewMine == true
        ? const QuotedAuthor(label: 'You')
        : QuotedAuthor.unknown;
  }
  if (id == myAccountId) return const QuotedAuthor(label: 'You');
  return QuotedAuthor(label: personLabel(contacts, id), accountId: id);
}

String? _authorIdFor(StoredMessage reply, ChatTarget chat, String myAccountId) {
  final stated = reply.replyPreviewAuthorId;
  if (stated != null) return stated;
  final replyToId = reply.replyToId;
  if (replyToId == null) return null;
  final quoted = chat.messageById(replyToId);
  if (quoted == null) return null;
  // senderAccountId is null on our own messages -- not a missing author, but
  // the one author a transcript never has to store.
  return quoted.mine ? myAccountId : quoted.senderAccountId;
}
