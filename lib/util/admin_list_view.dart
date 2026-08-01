// Search and ordering for the Server Admin user list (APP-10). Purely
// client-side over the already-fetched list: the list arrives in one
// unpaginated response, so there is nothing to gain from asking the server to
// filter it -- and a server-side search endpoint is only worth building if the
// account count ever makes that fetch itself slow.
//
// Kept out of the screen so the rules are testable: what counts as a match,
// and which direction each ordering runs in, are both easy to get subtly wrong
// and impossible to notice by looking at a list.
import '../net/dto.dart';
import 'address_format.dart';

/// How the user list is ordered. Each has exactly one direction, chosen for
/// what the operator is looking for when they pick it -- there is no
/// ascending/descending toggle, because for every one of these only one
/// direction answers a real question.
enum AdminSortOrder {
  /// By account id, ascending. The stable, boring default ordering to fall
  /// back to; also what every other order breaks ties with.
  id,

  /// Oldest account first. Matches what the server already returns, so it is
  /// the default here too -- and for the "who has been sitting here unused
  /// since forever" question, oldest-first is the useful direction anyway.
  created,

  /// Most privileged first: admins, then moderators, then members. Scanning
  /// for "who can do what here" means looking at the top of that list.
  role,

  /// Blocked accounts first. The whole point of ordering by status is
  /// surfacing the exceptional ones.
  status,

  /// Largest queue first (SRV-09).
  pending,

  /// Longest-waiting queue first (SRV-09) -- the sharpest single signal that
  /// a device stopped collecting its messages. Accounts with nothing queued
  /// sort last: they have no age at all, and putting them first would bury
  /// the answer.
  oldestPending,
}

/// Whether [order] can say anything about [accounts] -- false for the SRV-09
/// orderings against a server that doesn't report those figures, so the UI can
/// leave options out rather than offer ones that would silently do nothing.
bool adminSortOrderApplies(AdminSortOrder order, List<AdminAccountSummary> accounts) {
  switch (order) {
    case AdminSortOrder.pending:
    case AdminSortOrder.oldestPending:
      return accounts.any((a) => a.hasActivitySignals);
    case AdminSortOrder.id:
    case AdminSortOrder.created:
    case AdminSortOrder.role:
    case AdminSortOrder.status:
      return true;
  }
}

/// Whether [account] matches [query], typed incrementally into the search box.
///
/// Matched against the *normalized* id on both sides ([normalizeAccountId]), so
/// the grouping hyphens the list displays don't have to be typed and case never
/// matters -- someone reading an id off a screen, a note or over the phone
/// finds it either way. Substring rather than prefix so a partial id copied
/// from the middle still lands.
bool adminAccountMatches(AdminAccountSummary account, String query) {
  final needle = normalizeAccountId(query);
  if (needle.isEmpty) return true;
  return normalizeAccountId(account.id).contains(needle);
}

/// Filters [accounts] by [query] and sorts by [order], returning a new list.
///
/// Every ordering breaks ties by id, so the list never reshuffles between
/// rebuilds -- with a handful of accounts created in the same second, or all
/// sharing one role, an unstable sort would visibly jitter under the user's
/// finger.
List<AdminAccountSummary> adminListView(
  List<AdminAccountSummary> accounts, {
  String query = '',
  AdminSortOrder order = AdminSortOrder.created,
}) {
  final result = accounts.where((a) => adminAccountMatches(a, query)).toList();
  result.sort((a, b) {
    final byOrder = _compare(order, a, b);
    return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
  });
  return result;
}

int _compare(AdminSortOrder order, AdminAccountSummary a, AdminAccountSummary b) {
  switch (order) {
    case AdminSortOrder.id:
      return a.id.compareTo(b.id);
    case AdminSortOrder.created:
      return a.createdAt.compareTo(b.createdAt);
    case AdminSortOrder.role:
      return _roleRank(a.role).compareTo(_roleRank(b.role));
    case AdminSortOrder.status:
      // Anything that isn't 'active' is the interesting case, so this asks
      // "is it active?" rather than comparing the strings -- a future third
      // status stays grouped with blocked instead of sorting alphabetically
      // into the middle.
      return _statusRank(a.status).compareTo(_statusRank(b.status));
    case AdminSortOrder.pending:
      return b.pendingMessages.compareTo(a.pendingMessages);
    case AdminSortOrder.oldestPending:
      final oldestA = a.oldestPendingAt;
      final oldestB = b.oldestPendingAt;
      if (oldestA == null && oldestB == null) return 0;
      if (oldestA == null) return 1; // no queue: after everything that has one
      if (oldestB == null) return -1;
      return oldestA.compareTo(oldestB);
  }
}

/// Unknown roles rank last: a role this build doesn't know is more likely a
/// newer server's addition than a privileged one, and guessing it outranks
/// admin would be the worse mistake.
int _roleRank(String role) => switch (role) {
  'admin' => 0,
  'moderator' => 1,
  'user' => 2,
  _ => 3,
};

int _statusRank(String status) => status == 'active' ? 1 : 0;
