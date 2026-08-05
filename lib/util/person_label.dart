// How a person is named where a bare short id used to stand (APP-18).
//
// One rule, and every surface in a group reads it: the transcript's author
// lines, a reply's quote, the "replying to …" bar, the member list, the
// delivery sheet, the chat-list preview. That is the point -- a label that
// differs between two of them makes one person read as two, which is the
// confusion this item exists to remove.
//
// The short id **stays**, in parentheses. It is the only half that is
// evidence: a name is this device's own private note, nothing stops two
// contacts from being named alike, and a message is addressed to the id.
// Showing the name alone would make it look like an identity the protocol
// vouches for.
import '../state/contact_store.dart';
import 'address_format.dart';

/// [accountId] labelled with the name this device has given them, or the bare
/// short id where it has not.
///
/// Takes the store rather than a name so that "named" and "not named" are one
/// call and cannot drift apart at a call site.
String personLabel(ContactStore contacts, String accountId) {
  final name = _assignedName(contacts, accountId);
  final short = shortAccountId(accountId);
  return name == null ? short : '$name ($short)';
}

/// The same person, where the line is too tight to carry both halves: the chat
/// list's one-line preview, which is already truncated and would spend a third
/// of its width on parentheses.
///
/// The one deliberate exception to the rule above, and it is safe *because* it
/// is the preview: nothing is decided from a preview, and opening the chat
/// shows the full label one tap later.
String personLabelCompact(ContactStore contacts, String accountId) =>
    _assignedName(contacts, accountId) ?? shortAccountId(accountId);

/// The stored name, with blank treated as absent -- it would otherwise render
/// as ` (qk43r)` or as an empty author.
String? _assignedName(ContactStore contacts, String accountId) {
  final name = contacts.nameFor(accountId)?.trim();
  return name == null || name.isEmpty ? null : name;
}
