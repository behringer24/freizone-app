# Design: Admin user-list search and sort

Status: **done** · Roadmap: [APP-10](../ROADMAP.md)

The Server Admin Users list (`admin_screen.dart`) renders every account from
one unpaginated fetch (`AppSession.adminAccounts` / `listAccounts`) and will
get long. Add an incremental (type-as-you-go) substring search over id/short
id, plus a sort-order control (icon opening a menu) — candidates: id, role,
created date, status, and once SRV-09 lands, pending-message count or
oldest-pending age. Pure client-side filtering/sorting of the
already-fetched list for now; only worth a server-side paginated/search
endpoint if the account count ever makes the full fetch itself slow.

**Shipped 2026-08-02.** The rules live in `lib/util/admin_list_view.dart` with
tests, not in the screen: what counts as a match and which way each ordering
runs are both easy to get subtly wrong and impossible to spot by looking at a
list.

Search matches the *normalized* id on both sides (`normalizeAccountId`), so the
grouping hyphens the list displays never have to be typed and case never
matters — an id read off a screen, a sticky note or over the phone finds its
account either way. Substring, not prefix, so a fragment copied from the middle
still lands.

Each ordering has one fixed direction rather than an asc/desc toggle, because
for every one of them only one direction answers a real question: oldest
account first (the default, matching what the server already returns), admins
first, blocked first, most queued first, longest-waiting first. Every one breaks
ties by id — without that the list visibly reshuffles between rebuilds whenever
several accounts are equal under the chosen ordering. Accounts with nothing
queued sort *last* under "longest waiting", since they have no age at all and
would otherwise bury the rows that ordering exists to surface. The two SRV-09
orderings are left out of the menu entirely against a server that doesn't
report those figures.

