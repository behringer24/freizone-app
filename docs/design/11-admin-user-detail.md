# Design: Admin-side user detail view

Status: **done** · Roadmap: [APP-11](../ROADMAP.md)

Rows in the Server Admin Users list aren't tappable today — only a per-row
overflow menu (set role, block/unblock, delete, `admin_screen.dart`). Make a
row open a detail screen — but **not** `peer_profile_screen.dart` itself,
since its actions don't fit this context: its block toggle is a personal,
single-user block (meaningless for an admin/moderator acting on an arbitrary
account they have no chat with), and "Reset secure session" assumes an
existing ratchet session with that peer, which an admin/moderator generally
doesn't have. Build a similar-but-distinct screen: account details (role,
created date, and once SRV-09 lands, the pending-message/quota signals),
with only **"Block for all" / "Unblock for all"** (SRV-08 wording) and
**"Delete"** as actions.

**Shipped 2026-08-02** as `lib/screens/admin_account_screen.dart`, with two
additions to the plan above.

**Who invited this account** (needs SRV-14, which exposes it). Shown to admins
only, because the server only tells admins — a moderator would otherwise be
left wondering why the row is always empty. Rendered as "Unknown" rather than
"nobody" when absent: the field is equally missing for an account that needed
no invite and for one whose inviter has since been deleted, so claiming the
former would be wrong on any server that has ever removed an account. Tappable,
since "who vouched for this one" is usually the start of a chain — and the
inviter is guaranteed to still exist whenever the field is set, because the
invite row cascades with its creator.

**A chat button** ("Start a chat" / "Open chat", depending on whether one
exists). Explicitly the operator's own, personal act: it goes out from their
account like any other message and the recipient sees nothing marking it as
coming from an admin. Hidden on the operator's own row, since
`startConversation` refuses a self-chat outright and offering it would only
produce an error. Left *enabled* for a blocked account, with a note — the
message queues server-side and arrives if the block is ever lifted, so
disabling it would remove a genuinely useful action, but saying nothing would
make it look delivered.

Rows in the list are now tappable; the overflow menu stays, so the two
most-used actions remain one tap from the list. The screen looks the account up
in `AppSession.adminAccounts` by id on every build rather than holding the
snapshot it was opened with, so a block or unblock is reflected immediately and
a deletion (here or elsewhere) is noticed rather than leaving stale figures on
screen. `AdminScreen` gained a `settings` parameter purely to hand on to
`ChatScreen`.

