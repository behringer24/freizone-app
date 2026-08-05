# Design: An app-wide contacts area

Status: shape decided 2026-08-04 · **built and verified 2026-08-05**, in four
phases · Roadmap: [APP-19](../ROADMAP.md)

## How it is being built

Four phases, ordered so the risky one is not also the first:

1. **The store and the one-time import.** Self-contained and invisible: the
   names are lifted into the store while every screen still reads them from the
   profile. Nothing can regress, because nothing depends on it yet.
2. **The read path** — where the source of truth actually moves. `ChatTarget
   .displayName` loses its peer-alias meaning and keeps only "a group's own
   name", `BlockedPeer.displayName` goes away, and every screen asks the store.
   This is the phase that can silently un-name people, which is why phase 1
   lands and is tested first.
3. **The contacts list and the detail screen**, with the account picker and its
   reachability check.
4. **The three deletions.**

### What phase 1 settled

- The store takes **plain maps**, and the profile-reading half is a separate
  adapter (`contact_import.dart`). A store whose whole point is to be
  account-independent should not import per-account state; keeping the seam
  there also means the import's rules can be tested without building a profile.
- **Collision order is deterministic** — profiles are iterated by sorted account
  id. Left to the directory listing, which of two names survived would depend on
  the filesystem. Two profiles that agree on a name do not collide and are not
  reported: a notice raised for a non-decision is a notice that gets dismissed
  unread, which is the one thing this notice cannot afford.
- The import reads `blockedPeers[…].displayName` too, not just the conversation
  aliases — that field exists purely for a name whose conversation is gone, so
  skipping it would have discarded the names of exactly the peers a user had most
  reason to label. Within one profile the live alias wins over the block-time
  snapshot.
- Whether the import has run is **recorded**, not inferred from an empty store.
  Otherwise deleting every contact would resurrect the old aliases on the next
  start — turning a deliberate decision into a bug.
- The import reads **raw profile JSON**, not `AppState`. This was a correction:
  the first version went through the parsed model, which creates an ordering trap
  it took Andreas' question to expose. Phase 2 takes `display_name` off
  `Conversation`, so `Conversation.fromJson` stops reading the key — and an
  import reading parsed state would then find *nothing left to import*. That
  makes the migration silently correct only if phase 1 and phase 2 ship in
  separate releases **and** every user passes through the intermediate one. A
  user updating across two versions would lose every name they had assigned.
  Reading the JSON makes the migration independent of the model it migrates away
  from, which is the property a one-shot migration needs in any case.

### What phase 2 settled

- `titleFor` takes the **store**, not a name the caller resolved. The signature
  has to stay uniform, since a chat list draws groups and one-to-one chats
  through one call — and making the parameter required is what turned this into
  a compiler-guided change: 18 call sites named themselves instead of a
  forgotten lookup silently falling back to an address.
- **A root-level rebuild does not reach a pushed route.** The plan said one
  `ListenableBuilder` at the root of `FreizoneApp` would refresh every screen on
  a rename, the way a theme change does. It would not: a `MaterialPageRoute`
  builder runs once and its result is held by the route, so an ancestor
  rebuilding leaves it untouched. A theme survives that only because `Theme` is
  an `InheritedWidget` and its dependents re-run. So every screen that shows a
  name listens for itself — `Listenable.merge([session, contacts])` in the chat
  list, the chat screen, the peer profile and the blocked list. The share picker
  does not: it is built when a share arrives and nothing renames while it is
  open.
- The one place that needed real thought rather than mechanical replacement is
  `NewChatSheet`. Its optional name field used to ride along on
  `startConversation(displayName:)`. It now writes the contact **after** that
  call returns, because the returned conversation's `peerAccountId` is the first
  moment the *canonical* id is known — the field may hold a five-character
  prefix, and a contact keyed by one would never match anything again. Same
  reasoning as resolve-at-creation, arrived at from the other direction.

### What phase 3 settled

- **"No" and "could not ask" are different outcomes.** The design said an
  unreachable server must leave no contact behind, with a retry offered; building
  it made clear that this needs a *typed* failure rather than an error message.
  `ContactResolutionProblem` separates a definite denial (404, or a host that is
  not a Freizone server) from a non-answer (unreachable, or a 5xx) — the second
  never creates a contact and turns the button into "Try again". Collapsing the
  two would mean one dropped connection writes a record that fails the first time
  it is used.
- Resolution is account-independent for **authentication** but not for **host
  selection**: a bare id has to be asked somewhere, and that is the active
  account's server, matching what the new-chat sheet already does. The document's
  earlier phrasing ("needs no account of ours at all") was true of the former and
  glossed over the latter.
- The detail screen partitions my accounts into *already talking* and *could
  start*, and shows a third group — **cannot reach** — with its reason rather
  than omitting it. Omitting was the original plan ("either omits that account or
  shows it with the reason"); showing it won, because an account missing from a
  list of my own accounts reads as a bug, where a greyed row with "federation is
  off on this account's server" reads as an explanation.

### What still stores a name, after phase 2

Nothing, for a person. `display_name` moves off `ChatTarget` and down onto
`GroupConversation`, where it means "the name this group gave itself" — so a
`Conversation` has no such field to write, and `writeBaseJson` stops emitting the
key. No cleanup migration is needed for the old values: a profile is rewritten in
full on every message, so the key disappears from disk on the next save simply
because nothing emits it any more. `BlockedPeer.displayName` goes away entirely.

The consequence worth stating: the contacts file becomes the **only** copy of
every assigned name. Losing it loses them all, with nothing left to re-import
from — the exact price of "one place a name lives", and the reason names belong
in APP-05's backup.

## The problem this comes from

Short ids are unreadable as people. In a one-to-one chat that barely matters:
there is one other person, you named them once, and the app bar says the name.
In a group it matters a lot — the transcript labels each author with five
characters of their account id, and a reader has to hold a mental table of
`qk43r` → Carla. Groups turned a tolerable weakness into the main thing standing
between a group chat and being readable, which is what raised this.

[APP-18](../ROADMAP.md) fixes the visible half within a group: show the name this
account has already assigned, with the short id in parentheses, and let it be
assigned or changed from the transcript. This document is about the question
APP-18 runs into and cannot answer on its own.

## Why a name has nowhere to live today

`displayName` is a field on **`ChatTarget`** — that is, on a *conversation*
(`lib/state/chat_target.dart`). So is `blocked`, on `Conversation`. Both are
per-account and purely local, which is right, but it means:

- A group member this account has never had a one-to-one chat with has **nowhere
  to store a name at all**. There is no conversation to hang it on.
- A name is conceptually about a *person*, and it is currently a property of a
  *chat with* that person. The two only coincide because, until groups, every
  person you could name was someone you had a chat with.

Creating an empty conversation just to hold a name is the obvious shortcut and
the wrong one: the chat list is a list of conversations, so it would litter it
with chats nobody started — the exact problem `PeerEndpoint` was split out of
`Conversation` to avoid (APP-16).

So a name needs a record of its own, keyed by the person's account id. That is a
contacts store whether or not it ever gets a screen.

## What a contacts area would answer

Given such a store, a screen for it answers several things at once:

- **One place to manage names**, rather than renaming inside whichever chat
  happens to be open.
- **Starting a chat with a contact**, including choosing **which of my own
  accounts** to start it from.
- **Which of my accounts already talk to this person.** Not a convenience: if I
  hold a work account and a private one, writing to someone from the account
  they do not know is a disclosure I cannot take back. The app is in a position
  to prevent that mistake, and today it does not.
- **Block status**, which stays per account — blocking someone as my private
  account says nothing about my work account, and merging the two would be
  wrong.

Andreas currently favours giving it **its own icon in the main bar** rather than
burying it in the overflow menu.

## Decided: one central store, account-independent

**Decided 2026-08-04.** The contact store is central and shared across this
device's accounts, not scoped to one of them. Andreas' reasoning, which is the
part worth keeping: *I am one person with one device and several accounts. I do
not have to inherit my accounts' split-brain.* The accounts are a property of how
he reaches people, not of who those people are.

The complexity that follows — every *action* on a contact is account-specific —
is accepted deliberately in exchange for one place to keep people.

There is a **privacy consequence** worth stating plainly, because it is the price
of the decision rather than an oversight: separate accounts exist partly to keep
spheres apart, and one shared contact list links those spheres **locally**. Nothing
leaves the device, so this is not a protocol leak — but whoever holds the unlocked
device, or a backup of it, sees one merged social graph rather than two separate
ones, and the contact screen shows the link outright ("these two of my accounts
talk to this person"). APP-07's biometric app lock is the existing mitigation.

### A contact is one address, and therefore one name

No per-account name override. The case that seems to want one — "Herr Müller" at
work, "Thomas" privately — is answered by the record's own granularity instead: a
contact **is one account address**, so a person with a work account and a private
one is *two* contacts, "Thomas beruflich" and "Thomas privat". They have to be
named apart anyway, or they could not be told apart in the first place.

That collapses two of the open questions into one rule, and it is the simpler
model rather than a compromise: one address, one name, however many of my
accounts happen to be chatting with it. What the store does *not* do is model a
human with several addresses — deliberately, and worth remembering as the thing
to revisit if it ever bites, since retrofitting it later is expensive.

### What brings a contact into existence

Always a deliberate act, never a side effect of having seen someone:

- assigning a name, from a group transcript or a one-to-one chat (APP-18), or
- creating one by hand from an address.

Merely sharing a group with somebody does not make them a contact — otherwise
the store fills with every account this device has ever been in a room with, and
being central, that noise would span every account at once. A group member who
is not a contact keeps rendering as their short id.

### When the address gets resolved

The open question this raises: a hand-typed address may be a short id or a
prefix, and a contact created without immediately starting a chat has no other
occasion to resolve it.

**Resolve at creation, store only the canonical id, and refuse to store an
address that does not resolve.** This is not a fresh judgement — it is what
SRV-01/APP-16 learned the hard way. A group invite that signed whatever was typed
folded in a **phantom member**: listed, invited, and impossible to session with,
because every certificate in that account's chain is signed over the canonical
id. A contact holding a prefix would be exactly that phantom, one layer up, and
would fail at the moment the user finally tried to use it.

Two things make this cheap:

- `GET /v1/accounts/{id}` is a **public** key directory, unauthenticated. So
  resolution needs no account of ours at all, which is what lets an
  account-independent store do it — a nice fit rather than a coincidence.
- The path only exists for hand-typed addresses. A contact created by naming
  someone in a group or a chat already has the canonical id from the group's
  facts or the conversation.

Store the account id and the server. Not the root public key: `account_id ==
hash(root_pubkey)`, so the id already commits to the key, and holding a copy
would make the contact record look authoritative about crypto when it is not —
the key is fetched and verified against the id when a session is established.

A lookup that fails because the server is unreachable must leave **no** contact
behind, with a retry offered, rather than a half-made one to discover later.

## The contact detail screen

The screen APP-18's "message them directly" needs anyway, and where the
multi-account questions get answered:

- **Existing chats**, at the bottom: one row per chat that already exists with
  this contact, each naming *which of my accounts* holds it. Block status is
  shown here too, since a block is per account and this is the only place all of
  them are visible at once.
- **"Start new chat"** below that, with an account picker — offered **only** when
  some account of mine is not already talking to this contact. That is what keeps
  "enter the existing chat" clearly distinct from "start a new one", instead of a
  single "start chat" that silently means one or the other.

This also dissolves the earlier worry about copying a contact between accounts:
nothing is copied. There is one contact record, and starting a chat from another
account simply means maintaining another chat with it.

## The store is a generalization, not a new idea

A per-person record that outlives the conversation already exists here:
`AppState.blockedPeers` holds an address and a name and deliberately survives
`deleteConversation`, so deleting a blocked peer's chat cannot silently unblock
them. `AppState.knownPeerIds` is a second such set. The contact store generalizes
that pattern rather than introducing one.

It also means the contact outlives the chat by construction, which is what lets a
conversation be picked up again without a fresh invitation.

## The contact list is the only place a name lives

**Decided 2026-08-04.** Every screen reads the assigned name from the contact
store; nothing else stores one. Change it centrally and it changes everywhere.
Delete the contact and the name is gone everywhere — **without losing any chat**;
those conversations simply fall back to the short address, as they do for someone
never named.

Three consequences, because the name is currently stored in three places:

- **`ChatTarget.displayName` cannot simply be deleted.** It carries two different
  meanings through one field: a *peer alias* on `Conversation`, and a **group's own
  name** on `GroupConversation` (refreshed from the folded fact set — the group
  named itself, it is not a contact). Only the first moves to the contact store;
  the group keeps its own.
- **`BlockedPeer.displayName` goes away.** It exists purely so the blocked-contacts
  screen can show a name with no conversation left, which is exactly what the
  contact store now answers. A blocked peer who was never a contact shows their
  short address, which is honest rather than a regression.
- **The existing names have to be imported once.** Every alias assigned so far
  lives in `conversation.display_name` inside each account's profile. Moving the
  source of truth without a one-time migration that lifts them into the contact
  store would silently discard every name the user has ever assigned. Because the
  store is central and the names are per profile, the import reads every profile —
  and two accounts that named the same address differently need a rule (first one
  wins, and say so, rather than picking silently).

## Three deletions, and only the last one touches crypto

**Revised 2026-08-04**, after weighing the earlier two-action split against the
rule that decides this: **losing a message is the worst outcome available.** That
ranks above tidy storage, so it is what the routine action is built around.

### What phase 4 settled

- **Deleting a chat reverses a choice that was already in the code.**
  `acceptConversation` put the peer into `knownPeerIds` precisely so a later
  delete would *not* turn them back into an unactioned request — the opposite of
  what this document decided. The decision here wins (deleting is a statement
  about the relationship, so a resumption is an event, not a chat quietly
  reappearing), but the old rationale was deliberate and is now written into
  `deleteConversation`'s doc comment beside the new one, so nobody rediscovers
  only half of it.
- The verdict is **five-valued, not a boolean**. `gone`, `noActiveDevice` and
  `notAFreizoneServer` are definite absences; `unknown` and `present` both keep
  `couldStillLoseMessages` true. A boolean would have invited exactly the
  collapse this check exists to prevent — "could not ask" quietly becoming
  "gone".
- The dialog states the risk as **what is actually at stake** rather than as
  "cannot be undone": their first messages will be unreadable until the
  encryption has been rebuilt. Shown only where absence could not be
  established, so the warning keeps its meaning.

### 1. Remove a contact — the name, and nothing else

Deleting a contact in the contacts area removes **only the name entry**. No effect
on chats, history, media, sessions or block state. Everywhere that showed the name
simply shows the short address again, exactly as for someone never named.

That is the whole action. It is a labelling decision, not a relationship one, and
keeping it that narrow is what makes it safe to use freely.

### 2. Delete a chat — local cleanup that cannot lose anything

Drops the conversation, its history and its media, and takes the peer out of
`AppState.knownPeerIds` so a resumption arrives as a message **request** to accept
or decline rather than silently reopening the chat.

**The ratchet session is kept, invisibly.** That is the point rather than an
oversight: it is the only arrangement in which the peer's next message is still
decryptable, and therefore the only one in which the resumption can be *seen* at
all. The peer is told nothing and notices nothing.

Two alternatives were considered and rejected:

- **Drop the session and let the peer's next message re-establish.** It cannot:
  they still hold their half and have no reason to send a prekey block, so the
  envelope arrives undecryptable, goes to `_giveUpOnEnvelope` as SRV-03 desync
  evidence, and is lost — the very message that should have become the request.
- **Drop the session and send the peer a re-key signal**, so they discard theirs
  and re-establish on their next message. Lossless *in principle*, and invisible
  in practice (a reset is indistinguishable from ordinary SRV-03 recovery, and
  SRV-17's `rekey: true` already says "deliberate"). Rejected because the loss
  window only narrows rather than closing: if they send before draining that
  signal, their message is still encrypted under the old chain and still dies. A
  narrower race is not a guarantee.

The honest cost of keeping the session: a deleted chat leaves ratchet state behind
that nothing surfaces, and over years those accumulate. They are small — ratchet
keys, not history — and action 3 is the release valve. An automatic expiry (drop
sessions for chats deleted more than N days ago and never resumed) is possible and
deliberately *not* proposed: it would reintroduce exactly the loss this action
exists to avoid, for a peer who happens to write on day N+1.

### 3. Remove permanently — for a peer who is actually gone

The durable removal an orphaned chat needs: conversation, history, media,
`knownPeerIds`, **and the ratchet session**. Nothing is left.

What makes this safe is that it is **evidence-based rather than a guess**. The
public account directory answers definitively, needs no authentication, and needs
no federation switch — `GET /v1/accounts/{id}` returns the account with its
devices and each device's `status`:

| What the directory says | What it means |
|---|---|
| `404` | the account no longer exists — nothing can ever arrive from it again |
| exists, no `active` device | reachable in principle, messageable by nobody |
| `NotFreizoneServerException` | that host stopped being a Freizone server |
| unreachable | **unknown**, not gone — see below |

With the first three, permanent removal loses nothing by construction: there is no
sender left to lose a message from.

"Unreachable" must not be treated as gone — that is a temporary condition wearing
the same clothes. Permanent removal stays *available* there, because a user who
knows the server is dead should not be held hostage by a check that cannot
conclude, but it is offered with the consequence stated plainly: if that peer ever
does come back, their first messages will be undecryptable until a re-key
completes.

This is also where the earlier idea of shortening that window belongs: on a
permanent removal the peer can be marked so the *first* undecryptable envelope
from them triggers an immediate re-key instead of waiting for SRV-03's evidence to
accumulate. Left open, since it only matters in the case we just called unlikely.

## The account picker checks reachability

**Decided 2026-08-04.** "Start new chat" is not offered for one of my accounts
merely because that account has no chat with the contact yet — it has to be able
to reach them. Federation switched off on that account's own server, that server
blocking the contact's, or the contact unreachable from there all make the option
fail *after* the user picked it, which is the shape this whole screen exists to
avoid.

The app already answers this: `AppSession.federationLocked(convo)` is the same
check the chat screen uses to replace its composer with an explanation. The picker
consults it per account and either omits that account or shows it with the reason,
rather than offering an action that cannot work. Without it the promise "any
account that isn't talking to them yet" is false in exactly the federated setups
that motivate having several accounts.

## Still open

- Whether a **permanent removal** should shorten the re-key window for a peer who
  turns out not to be gone after all, as described above. Only reachable in the
  "unreachable, so unverifiable" case.
- **A profile that arrives after the import has run** carries aliases nothing
  will collect. Impossible today — a newly registered account has no aliases, and
  seed recovery (APP-01) restores an identity, not a history — but **APP-05**
  (backup) and **APP-02** (multi-device history) both introduce exactly that
  path. Whoever builds either needs to lift that profile's aliases at the point it
  is adopted, rather than relying on a device-wide "already imported" flag that
  was true long before the profile existed.

## Out of scope

- **Server-side contacts.** A contact list is local, full stop. The server holds
  the one account-to-account link it cannot avoid (`invite_codes.created_by`,
  admin-only — see freizone-server's SRV-14) and must not learn who anyone
  keeps in an address book.
- **Names travelling between devices.** That is APP-05 (backup) and APP-02
  (multi-device history), not this.
- **A name anyone else can see.** An assigned name is mine about them, not a
  profile field they publish, and it stays that way.
