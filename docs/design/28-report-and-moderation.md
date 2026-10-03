# Design: Reporting someone, and working through reports

Status: **planned** · Roadmap: [APP-28](../ROADMAP.md) · Depends on: APP-27, APP-10, APP-11
· Server half: freizone-server
[SRV-33](https://github.com/behringer24/freizone-server/blob/master/docs/design/33-abuse-reports.md)

Two surfaces from one feature: the one sentence a user needs before reporting
somebody, and the screen a moderator actually works in afterwards.

The principle underneath both is SRV-33's: a report is named, so the reporter
takes responsibility and the operator can ask what happened. Most of what
follows is that principle applied twice.

## Reporting

**It lives inside blocking, not beside it.** `peer_profile_screen.dart`'s
"Protection" section already has the personal block; reporting becomes a
checkbox in that flow — *also report this account to the operator* — rather
than a second button. A standalone report button does nothing the user can
see, which is how a feature trains people to distrust it; blocking is
immediately effective and the report rides along with it. Reporting without
blocking stays possible from the same section for the case where somebody
wants the operator informed but the conversation kept.

Before it sends, plainly and in one sentence: **the operator of that server
sees this report with your address, and can contact you about it.** Not in a
help text, not afterwards. Responsibility nobody was told about is a trap, and
this is the sentence that makes SRV-33's whole design honest.

Then one screen with:

- **the category** — spam, harassment, fraud, other. Four taps, no free text.
  There is no text field to write into, and the screen says why in half a
  line: the operator cannot read the conversation, so the report is a reason
  to look, not evidence.
- **what will be sent**, shown rather than described: the name that account
  asserted about itself (APP-27), if any, with its dates. Never the local name
  from the `ContactStore` — the two are stored apart precisely so this cannot
  happen, and an account that asserted nothing sends nothing rather than a
  substitute.
- **for a federated account, a second choice**: file with my own server (always,
  not optional) and additionally with theirs (default off). The sentence that
  belongs there is that the second one hands your address to an operator you
  do not know. Suppressed entirely when the target's `GET /v1/server-status`
  does not report `reports_enabled`.

The button is absent, not disabled and not failing, when the user's own server
does not report `reports_enabled` — the compatibility rule this repo works
under: discover, never assume.

**Withdrawal** sits in the same section, and is offered **unconditionally**
rather than only where a report is known to exist. Nothing tells this device
what it has reported — the server has no "my reports" endpoint and the app
keeps no record — and withdrawing something that is not there is the outcome
being asked for rather than a failure, so the core swallows that one 404.

The honest cost: the entry cannot read "reported — withdraw", so it does not
say whether there is anything to take back. Worth revisiting if it confuses
anybody; a per-peer record in the core would fix it, and this deliberately
did not open that.

**The reported account is told nothing**, ever — no badge, no line, nothing in
any screen it can reach. The report runs towards the operator, not towards the
accused.

**One warning that has to appear at the right moment**: when the reported
account is the server's only admin, say so before sending — the report goes to
the person it is about. SRV-33 cannot design that away; the app's job is to
make sure nobody discovers it afterwards.

## The moderation side

**A separate entry, not a sort order.** On a healthy server nothing is
reported, so a column that is zero for 200 rows is a poor primary route and
would crowd out SRV-09's activity signals, which actually vary. The Server
Admin area gets its own **Reports** entry showing the open count, opening a
list of the open cases. A "most reported" ordering in APP-10's sort menu was
considered and **not** built: a column that is zero for every row is exactly
the poor way in this paragraph rejects, and the marker below already covers
noticing something while here for another reason.

A badge on the Server Admin entry itself is not optional. An admin who never
opens the area never learns a report exists, and then the report button was a
placebo. Push for it is out of scope here.

**In the user list**, a discreet marker on affected rows, so somebody who
arrived for another reason still sees it.

**The account detail screen** (APP-11) grows a reports section above the
danger zone, following that screen's existing shape — a coloured section
heading with a sentence, not a `ListTile` that invites a tap before the text
is read. It lists the cases, because the counter is not the working unit: each
one shows reporter, time, category, the asserted name with its signature
verdict, and the state. The two counters stay separate, from this server and
from elsewhere, never summed — SRV-33 explains why a mixed figure would be
worthless.

The line most decisions get made from is the name: *asserts "Bank Support",
signature verified* against *asserted no name*. It should read as that
sentence, not as a hex field.

**Three outcomes per case**, and none of them is delete:

- **Actioned** — dealt with. The case stays visible, resolved.
- **Dismissed** — checked, unfounded.
- **Abusive** — counts against the reporter, on their own row. This is the
  counterweight to named reporting; without it responsibility costs nothing.

There is **no counter reset**, deliberately: the value of an old report is
that the next moderator can see there was one and how it went. Resolving all
open cases at once is a loop over the same action, not a separate idea.
Everything expires on the server's retention window anyway.

**Acting** reuses what exists, in the order they should be reached for: block
for all (reversible, the ordinary answer), the federation blocklist for a
target on another server (the only thing that bites there), and delete last —
it cascades through devices, queues and invites, it cannot be undone, and it
is the least appropriate thing to reach for out of a moderation impulse. It
keeps APP-11's placement and confirmation.

**Contacting people** is the point of named reporting, so both directions get
a button: message the reported account, and message the reporter to ask what
happened. Both go through APP-11's existing start-or-open-a-chat path.

Two rules the implementation has to hold:

- **Nothing is prefilled.** No subject, no "regarding the report by …", no
  quoted category. This is the one place where a helpful convenience would
  directly expose the reporter, and it is tempting exactly because it looks
  helpful.
- **It is an ordinary chat from the moderator's own account.** There is no
  official operator message in the protocol, so the app must not frame it as
  one.

## Roles

The client mirrors SRV-33 rather than enforcing it — the server is where the
rule lives — but the UI must not show what it will not serve:

- a moderator sees reports about regular members only; staff-targeted reports
  and the counters on staff rows are admin-only, and the server does not send
  them, so the app renders their absence as absence rather than as zero;
- a moderator resolves cases it can see and blocks under SRV-08's existing
  limits — `admin_screen.dart` already draws that distinction and keeps it;
- marking a report by a staff member abusive is admin-only.

Anyone may *report* anyone, staff included. The report button in the peer
profile is never hidden because of who the other person is.
