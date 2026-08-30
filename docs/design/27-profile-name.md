# Design: Showing the name a contact asserts

Status: **planned** · Roadmap: [APP-27](../ROADMAP.md) · Related: APP-18, APP-19
· Protocol and core half: freizone-server
[SRV-32](https://github.com/behringer24/freizone-server/blob/master/docs/design/32-profile-name.md)

SRV-32 lets an account assert one optional name about itself, signed by a
device key and carried inside the encrypted channel. This is what the app does
with it: where it is stored, which of the two names wins on screen, and what
the user sees when the other side changes theirs.

## A suggestion is not a contact

APP-19 settled two rules that this could quietly break, and neither should
bend:

- the `ContactStore` is the **only** place a name lives, and it is
  **device-wide** across this device's accounts, so one person with one phone
  does not inherit their accounts' split-brain;
- a contact exists **only by a deliberate act** — naming someone, or creating
  one by hand — never from having seen an account.

A received suggestion is therefore *not* written to the contact store. It is
kept apart, as what it is: a claim the other side made, with its signature and
its timestamp. Three reasons, and each would be sufficient on its own.

**It is per receiving account, not per device.** APP-19 centralised the name
*I* assign, because that is my judgement about a person and should not differ
between my own accounts. A suggestion is the opposite direction: a statement
*they* made *to a particular account of mine*, and they may well have
introduced themselves differently to my work identity than to my private one.
Merging those would fabricate a single answer where there are honestly two.

**It keeps the reporting leak structurally impossible.** APP-28 forwards the
asserted name and must never forward the private petname — "Dad", "the guy
from the flea market". Two stores means the wrong one cannot be picked up by
a `??` fallback written months later by someone who did not read this
document.

**The receive path cannot reach the contact store anyway.** APP-18 already
records why: that path runs in the push isolate, where the contact store must
not be touched. The shared core holds an exclusive lock on the account
directory and writes from both isolates as a matter of routine, so the claim
store belongs there — in the core's per-account state, arriving with the
message that carried it.

**Adopting a suggestion is the deliberate act.** Tapping "use this name"
writes it into the `ContactStore` exactly as typing it would, and from then on
it is an ordinary contact under APP-19's rules. Until then it is only a label
on screen. That is what keeps the "never from having seen an account" rule
literally true rather than merely nearly true.

## What is displayed

`util/person_label.dart`'s `personLabel` stays the one function every surface
calls — APP-18's finding that a person labelled two ways reads as two people
is the whole reason it exists. The chain grows one link in the middle:

```
contact name (ContactStore)  →  asserted name (core, this account)  →  short id
```

Everything else about APP-18 is unchanged: the name carries the short id in
parentheses; `personLabelCompact` in the chat-list preview stays the one
deliberate exception, name alone; and group system lines stay frozen short ids,
since they are written at receive time and re-labelling them later would
rewrite history.

The peer profile and the contact detail screen show both names when they
differ, because that is the one place the difference is the point: *you call
them X, they call themselves Y.*

## When it changes

A new claim that verifies and is newer than the stored one is **adopted**, and
the transcript gets a plain system line — "now calls themselves Y" — on
SRV-29's precedent that a fact about the other side is stated once in the
transcript and not badged anywhere.

Adopting silently was rejected: a contact renaming itself to "Bank Support" is
exactly the case this feature could otherwise be used for, and the user is the
only one positioned to notice. Not adopting at all was rejected too — then
every name ages out and the reset button becomes required knowledge.

The line appears **even when a local name is set** and nothing visible
changes. That is precisely when it matters most: somebody the user named "Dad"
starting to call themselves something else is worth a line, and it is one line,
not a badge.

**A withdrawn suggestion** (SRV-32's empty name) leaves the last known label
standing where it is the only one — a conversation that is still running must
not lose its title — and the reset entry becomes inert rather than
disappearing. Dropping to a bare id at the moment somebody clears their
profile would look like the app forgot who they are.

## Setting your own

One optional field in the profile screen, empty by default, with a sentence
saying where it goes: to the people you talk to, with your messages, and not
to any server. Empty is a first-class value and clears the suggestion for
everyone.

No second field, and no separate "visible in federation" switch. The scope
split we discussed for a directory has no meaning here — the audience is the
set of people already in a conversation, whatever server they are on — and a
per-contact override, if it is ever wanted, is a client-side rule that needs
nothing from the protocol.

## The reset entry

Where a local name and a suggestion both exist, the contact and peer-profile
screens offer "use the name they gave" — the reset half of the original idea.
It only appears when there is something to reset to, and it does not appear at
all where there was never a local override, because there is nothing to undo.

## What it must not become

The asserted name is not verification and the UI must not decorate it as if it
were — no check mark, nothing resembling APP-22's operator badge, which means
something a name never can. Anyone may call themselves anything; all the
signature proves is that this account said it. Key verification stays what it
is, and this changes nothing about it.
