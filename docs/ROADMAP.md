# Roadmap — freizone-app (Android client)

Planned and shipped work whose **essential** part lands in this repo. Items whose
core work is server-side or protocol-level live in
[freizone-server's roadmap](https://github.com/behringer24/freizone-server/blob/master/docs/ROADMAP.md)
under `SRV-` codes, even when most of the visible result appears here.

Each item has a short **reference code** used to discuss it:

- `APP-` — freizone-app (this file)
- `SRV-` — freizone-server
- `GAW-` — freizone-gateway

Status values: `planned` · `in progress` · `done` · `deferred`.

## How to read this file

Entries are deliberately short: what the item is, its status, and a dated log of
what happened. The reasoning — why an approach was chosen, what was rejected,
which trade-offs were accepted — lives in a per-topic design document under
[`design/`](design/), linked from the entry. Items small enough to state in a few
lines have no separate document.

Released versions and what each contained: [`CHANGELOG.md`](CHANGELOG.md).

Items are listed in numeric order. That is not the order they were worked in —
APP-09 predates APP-08, for instance — but it is the order they are easiest to
find in.

## Items

### APP-01 — Recovery seed phrase
Status: `done` · Depends on: SRV-06 · Also affects: shared Go core, freizone-server
Design: [design/01-recovery-seed-phrase.md](design/01-recovery-seed-phrase.md)

Back up the identity **root key** as a 24-word phrase, so losing the phone
without a second device no longer means permanent identity loss. Because
`account_id == hash(root_pubkey)`, restoring the same root key restores the
**same** account id, short id and address — recovery keeps the identity rather
than minting a new one.

- 2026-07-26 — BIP-39 in the shared Go core (`pkg/mnemonic`), so the 32-byte seed
  never crosses into Dart; two new FFI exports
- 2026-07-27 — backup and restore UI shipped and verified end-to-end on emulator
  and device: same id restored, old device revoked, admin role intact

### APP-02 — Multi-device history transfer
Status: `planned` · Also affects: shared Go core · Depends on: SRV-02

Move existing local chat history onto a newly linked device. Needs the
multi-device linking channel first (SRV-02).

### APP-03 — iOS client
Status: `planned` · Also affects: freizone-gateway (GAW-01)

No `ios/` directory yet; only Android is built and tested. iOS push delivery
needs the gateway's APNs path (GAW-01).

### APP-04 — Multimedia messaging
Status: `in progress` · Also affects: freizone-server (SRV-07)
Design: [design/04-multimedia-messaging.md](design/04-multimedia-messaging.md)

Send media, in priority order: (0) clickable links, (1) gallery images,
(1.5) camera images, (2) video, (3) audio, (4) possibly voice messages. Inlining
media in a message was ruled out; the companion server-side transport shipped as
SRV-07.

- Done — item 0 (APP-14), and phase 1: pick from gallery, encrypt, upload to the
  recipient's server, render in the bubble, view full-screen
- **Open** — camera capture, then video, which is what SRV-11 (resumable uploads)
  and APP-13 are waiting on

### APP-05 — Backup
Status: `planned`

Versioned local data backup, optionally synced per device to iCloud (iOS) or
Google Drive (Android).

### APP-06 — Chat text export
Status: `planned`

Export a single chat as a `.txt` file, no media: timestamp, name, short address
in parentheses, and the text — shareable through the OS share sheet.

### APP-07 — Biometric app lock
Status: `planned`

Require a biometric unlock when opening the app.

### APP-08 — Send feedback / outgoing message queue
Status: `done` · Part of: APP-04 (attachment path)
Design: [design/08-outgoing-message-queue.md](design/08-outgoing-message-queue.md)

On a slow connection the send button felt unresponsive: nothing visibly happened
until the round trip finished, so users re-tapped or retyped. The send path is now
optimistic — the message appears immediately and shows its own state.

- Done — step 1: the composer clears at once, the message is stored before the
  network call, and delivery state is visible per message
- 2026-08-02 — step 2's open fork (queue ciphertext or plaintext?) decided by
  APP-16: **plaintext**, encrypted at send time. A group message is encrypted
  once per recipient, so queued ciphertext would commit N copies to N specific
  session states that a single re-key invalidates. Groups also make step 2 a
  prerequisite rather than an improvement
- 2026-08-02 — step 2 shipped, and it was a limitation to remove rather than a
  queue to build: the send path already produced plaintext at send time and
  already serialized per peer. Unsent messages are now persisted (a `pending`
  one restores as `failed`, since nothing is in flight in a dead process), the
  picture is read back from the sender's own on-disk copy instead of an
  in-memory map, and `flushOutbox` retries oldest-first at startup and on the
  transition back from unreachable, bounded at three automatic attempts. The
  runtime half — flush on reconnect, picture recovery — has no test coverage
  and wants a run on a real device
- 2026-08-02 — the first device test found it inert: nothing ever saved while a
  message was unsent, so the outbox had nothing to retry from, and
  `_reloadVolatileStateFromDisk` then erased the memory-only bubble on the next
  resume. Fixed by saving at compose, at retry and on failure. Retries are also
  idempotent now — a stable wire `message_id` per message plus treating `409`
  as delivered, where before every attempt minted a fresh id and could deliver
  twice
- 2026-08-02 — retry then lost the *picture*, arriving as text only:
  `MessageAttachment.fromJson` drops an entry with an empty `blob_id`, which is
  right off the wire and wrong for our own history, where that is precisely
  what an outgoing picture looks like before its upload returns an id. Now
  distinguished by a `local` flag. Replies were checked at the same time and
  were already correct; there is a test for that now too
- 2026-08-02 — verified working on device. A follow-up question about the
  Double Ratchet then found the last hole: a failed POST left the ratchet
  advanced, so every retry widened the gap the peer has to bridge — and worse,
  a failed *first contact* left a session behind, which makes
  `_getOrCreateCryptoSession` omit the X3DH prekey block on the retry,
  producing a message the peer could never decrypt. A failed send now rolls the
  session back

### APP-09 — New-user onboarding guidance
Status: `planned`
Design: [design/09-onboarding-guidance.md](design/09-onboarding-guidance.md)

Two empty states a new user hits, neither explained today: no account on this
device (the setup wizard drops straight into a server-address form with no
framing), and an account with no conversations yet.

### APP-10 — Admin user-list search & sort
Status: `done`
Design: [design/10-admin-list-search-sort.md](design/10-admin-list-search-sort.md)

The Server Admin user list rendered every account from one unpaginated fetch in
whatever order the server returned. Now has type-as-you-go search over the id and
a sort-order menu, both client-side over the fetched list.

- 2026-08-02 — shipped. Search matches the normalized id, so display hyphens
  never have to be typed; each ordering has one fixed direction and breaks ties
  by id so the list cannot reshuffle between rebuilds

### APP-11 — Admin-side user detail view
Status: `done` · Depends on: SRV-08 · Also benefits from: SRV-09, SRV-14
Design: [design/11-admin-user-detail.md](design/11-admin-user-detail.md)

Rows in the admin user list were an overflow menu and nothing else. They now open
a detail screen — deliberately not the peer profile, whose actions belong to a
conversation partner rather than an arbitrary account.

- 2026-08-02 — shipped, with two additions beyond the original plan: who invited
  this account (admins only, from SRV-14) and a button to start or open a chat
  with them

### APP-12 — Push reliability: FCM token refresh while the app is closed
Status: `done` · Device verification outstanding
Design: [design/12-push-reliability.md](design/12-push-reliability.md)

An FCM token that rotated while the app was dead was silently lost, after which
no wake ever arrived again until the user happened to open the app — which they
had no reason to do, precisely because nothing was notifying them.

- 2026-08-01 — shipped: a Kotlin service subclassing firebase_messaging's own,
  starting a throwaway `FlutterEngine` to re-register every stored account
- **Open** — verification on a real device across an actual token rotation, which
  cannot be forced on demand

### APP-13 — Replace the reply quote's camera icon with a real thumbnail
Status: `planned` · Part of: APP-04
Design: [design/13-reply-quote-thumbnail.md](design/13-reply-quote-thumbnail.md)

A reply to a picture shows a stand-in camera icon in the quote block *inside* the
bubble. Not to be confused with the composer's reply preview and the pinned-message
bar, which already show the real picture — this is the hard one, because the quote
is a self-contained snapshot that may outlive the message it quotes.

### APP-14 — Clickable links in messages
Status: `done` · Part of: APP-04 (item 0)
Design: [design/14-clickable-links.md](design/14-clickable-links.md)

Message text was a flat `Text`, so a URL had to be selected and copied by hand.
http(s), `www.`, email addresses and Freizone `id*server` addresses are now
tappable, behind a confirmation sheet.

- 2026-07-31 — shipped. Detection is a pure function with 24 unit tests;
  rendering falls back to a plain `Text` when there is nothing to link

### APP-15 — Receive shares from other apps (Freizone as a share target)
Status: `done` (both levels) · Also relates to: APP-04 (images), SRV-07 (blob limits)
Design: [design/15-share-target.md](design/15-share-target.md)

Freizone appears in other apps' share sheets, both as the app itself and as
per-chat direct-share targets.

- 2026-07-31 — shipped, on an own platform channel rather than a dependency:
  MainActivity already had one, and it keeps the security-relevant part — reading
  the sender's `content://` stream — under our own control

### APP-16 — Groups (client side)
Status: `in progress` · Depends on: SRV-01, APP-08 step 2 · Also affects: shared Go core
Design: [design/16-groups.md](design/16-groups.md)

The client half of SRV-01. Group logic (event signing, the fold, `state_hash`,
snapshot merge) lives in the shared Go core as `pkg/group` behind four FFI
exports, with the state blob opaque to Dart. Here: a `ChatTarget` base under
`Conversation` and a new `GroupConversation`, one state file per group, fan-out
over APP-08's outbox, and the group UI.

- Designed 2026-08-02. Two findings that shape the order of work: APP-08 step 2
  is a hard prerequisite, since a fan-out dying mid-way loses the remainder
  permanently today — and groups settle step 2's open fork, because a group
  message must be encrypted per recipient, which only the plaintext-queue
  variant supports
- 2026-08-02 — phase 1 shipped: the `ChatTarget` base under `Conversation`, and
  the media path moved off `peerAccountId` onto a chat-neutral id. No behaviour
  change by construction, and measured that way — analyzer output unchanged,
  tests 216 → 219
- 2026-08-02 — phase 2 done: APP-08 step 2, the durable outbox
- 2026-08-02 — phase 3 shipped: `native/group.go` exposes `pkg/group` over four
  FFI exports (`GroupCreate`, `GroupSignEvent`, `GroupApplyEvents`,
  `GroupResolveState`), with the state blob opaque to Dart. cgo-free like the
  rest of the core, so it tests on the host, and the exports were checked in
  the cross-compiled `.so` for both ABIs rather than assumed
- 2026-08-02 — phase 4 shipped: `GroupConversation` (transcript only),
  `GroupStateStore` (one file per group per account, atomic writes), group
  transcripts in the profile, and the local operations on `AppSession` —
  create, sign, apply, delete — with no network yet. `sweepOrphanedMedia` and
  account deletion learned about groups on the way past
- 2026-08-02 — phase 5's wire layer shipped: `v: 4` group chat content, carried
  by `MessageContent` itself rather than a second class duplicating its fields,
  and `v: 5` as `GroupControl` following the `RekeySignal` pattern. A
  one-to-one message stays byte-identical, and an older build still shows a
  neutral placeholder rather than misfiling a group message into a DM
- 2026-08-02 — the peer endpoint is out of `Conversation`: `PeerEndpoint` holds
  the address half, the send core takes one instead of a conversation, and
  `Conversation` forwards its old field names so no call site changed.
  Behaviour-neutral by construction and measured that way. A fan-out can now
  reach a group member without inventing a one-to-one conversation for them
- 2026-08-02 — the send fan-out works for text: one separately encrypted copy
  per joined member over that member's own pairwise ratchet, a `GroupDelivery`
  per recipient carrying its own random stable wire id and delivery state, and
  a retry that addresses only the copies that never arrived. A member removed
  while a copy was queued no longer receives it
- 2026-08-03 — the group info screen's invite, from Andreas' first test run of
  it: the address field now takes every form the rest of the app does (short
  id-prefix, dash-grouped full id, `*server`, `*local`), and the address is
  resolved to the canonical full id *before* the `member_add` is signed. It
  previously signed whatever was typed, which folded in a **phantom member** —
  listed and invited, but unreachable, because every certificate in that
  account's chain is signed over the canonical id: the snapshot send failed with
  "invalid dh identity certificate", so the invitee heard nothing at all. An
  address that resolves to nothing now adds no member. Enforced in the core too
  (SRV-01), on the signing side only. A group invitation also **notifies** the
  invitee now and shows the group unread — nothing is ever sent into a group
  before they accept, so it was the one membership change worth waking someone
  for, and it was completely silent
- 2026-08-03 — second test run: the invitee got nothing at all, and the cause
  was in the core, not the invite. `loadGroupState` (native/group.go) accepted
  `null` and an absent blob as "no facts yet" but not `{}` — which is exactly
  what Dart's `const <String, dynamic>{}` encodes to, and exactly what
  `applyGroupControl` passes for a group it has never heard of. `State
  .UnmarshalJSON` then failed the call with "stored state has no genesis
  event" (a check that is right for a blob genuinely read back from disk), so
  the invitee's first snapshot threw on arrival: no group, no notification, no
  way to accept, and no second chance either — the ratchet had already advanced
  past the envelope and its id was already marked processed, so a redelivery is
  ignored by design. Only re-inviting could fix it. Recognizing "no facts"
  by *probing for events* rather than pattern-matching the bytes, so
  `{"events":[]}` and any future field-only blob behave the same. Covered by a
  test that merges a real snapshot into the blob the receive path actually
  passes — the old tests only ever used `nil` and `null`
- 2026-08-03 — SRV-17 landed on the client side too, and it belongs here because
  simultaneous establishment is a *group* phenomenon: the prekey block now
  carries a tri-state `rekey`, the send path states it on every establishment
  (`_encryptAndSend`'s `afterOwnReset`, true only behind a deliberate reset), and
  the receive path takes the sender's word instead of sniffing for a `v: 3`
  payload. `parsed.rekey ?? (RekeySignal.tryDecode(...) != null)` — the fallback
  survives for peers on older builds, and `false` is trusted as an answer rather
  than read as "unknown". Needs a native-core rebuild
- 2026-08-03 — invite/accept round trip verified end to end between two
  accounts, and the two gaps it surfaced closed: **declining an invitation**
  (a self-signed `leave`, which the fold already deletes the member row for
  whether or not the invitee had joined — so no new event type, and the group
  learns the refusal instead of keeping an invitation open forever; the group is
  then forgotten locally, transcript and pictures included), and **tapping a
  group notification** now opens the group. The payload carries a *tagged* group
  id rather than letting the tap guess from the id's version marker, so a
  payload left in the tray by an older build still opens the peer chat it meant.
  Opening a group clears the account's notification and launcher badge, which
  until now only a one-to-one chat did
- 2026-08-03 — convergence, after Andreas saw a third member take several
  messages from all three before everyone saw everyone. Three gaps, all now
  closed:
  - a control envelope that failed to send was **lost** —
    `_broadcastGroupEvents` swallowed the failure per member and nothing retried
    it. Now recorded as a *snapshot debt* (`AppState.groupSnapshotDebts`,
    persisted: the failure is usually the network, and being closed in that
    state is when it must not be forgotten) and paid off as a whole snapshot on
    reconnect, on resume, and on opening the group. A snapshot rather than the
    lost events: the fact set is grow-only and the fold dedupes by event id, so
    "everything I know" needs no bookkeeping of what went missing. A debt
    against a non-member is dropped rather than paid — sending group facts to
    somebody now outside the group would disclose the membership, and with it
    every member's address
  - convergence was **reactive only**: nothing ever sent a `sync_request`, only
    answered one, so a device that was itself behind stayed behind until
    somebody else spoke. Opening a group now asks one member (the founder if
    joined, else any joined member — any member holds the whole set, so one
    answer is as good as ten), at most once per group per five minutes
  - `flushOutbox` covered **only one-to-one** messages, so a fan-out that died
    part-way had no automatic second attempt at all, despite having as many ways
    to fail as the group has members. Group sends are in the flush now, and
    address only the copies that never arrived
  - and the reason none of this was visible: `AppSession.lastError` was written
    from a dozen places and **read by none**. The chat list now shows it in a
    banner that stays until dismissed (the field itself is transient — the next
    envelope that decrypts cleanly clears it — so the screen keeps its own copy)
- 2026-08-03 — two gaps found while taking stock of what groups still need:
  - a group message set `deliveredUpTo`, and the live path sends receipts over
    the *conversation* with the sender — so a group message confirmed that
    member's unrelated direct messages as delivered, or as read when their chat
    was the readable one, and the watermark is monotonic so nothing walked it
    back. Group receipts remain unbuilt; when they arrive they need their own
    per-group, per-member field rather than this one
  - `deleteGroup` (forget a group locally) had **no UI caller at all**: leaving
    or dissolving left the group in the chat list for good, and a group whose
    fact set failed to load could not be removed either. Now on the chat list's
    long-press (the only route that needs no fact set) and in the info screen,
    sharing one confirmation (`util/group_actions.dart`) that says a group one is
    still a member of will simply come back -- pointing at leave/dissolve, which
    are the signed facts. The group screen also stops offering a composer once
    this account is no longer a member
- 2026-08-03 — state events render as system lines (diffed from the folded view
  before and after a batch, not translated event by event -- authority is decided
  by the fold, so a late grant can retroactively admit an act and a revocation
  can bring a removed member back; the batch is consulted only to tell "left"
  from "was removed"). Same lines on both apply paths, so an inviter and an
  invitee read the same history. `group_system_lines.dart` is pure, because the
  receive half runs in the background isolate
- 2026-08-03 — Andreas' test run of the new removal, plus three questions.
  Removing a group while still a member was a trap: the fact set went, the others
  kept sending, and an arriving message re-created a transcript with no name, no
  member list, no info screen and a send that failed with "no group". Now
  "Leave and remove" / "Decline and remove" in one step, and for the founder --
  who cannot leave -- a refusal that points at dissolving. Around it: a group with
  no facts yet says so instead of offering a composer, its info screen offers the
  way out instead of "Group not found", and the receive path *asks* the member who
  wrote for the facts (`_askForGroupFacts`) rather than waiting for a volunteer.
  Re-invitation after a removal now notifies too -- the first check keyed on "this
  group is new to this device", which a removal leaves false
- **Open**, in the order they are likely to be done:
  - ~~no history for a member who joins later~~ — **decided 2026-08-03: history
    is never forwarded.** A new member gets the fact set, never past messages.
    Pairwise fan-out leaves no group copy to forward: a backfill would be one
    member re-sending everyone else's words on their own session, signed by the
    forwarder and attributed to the author, and it would retroactively hand an
    invitee exactly the traffic that "only joined members get a copy" withheld
    while their invitation was open. Reasoning in
    [design/16-groups.md](design/16-groups.md)'s out-of-scope section; the join
    dialog now says so before you accept
  - ~~the receive path~~ — **done 2026-08-03**: `v: 4` into its own transcript,
    `v: 5` applied without being stored or notified, out-of-order events held
    and retried, `state_hash` compared on every group envelope and answered
    with a snapshot, simultaneous X3DH establishment settled. The group half
    lives in `group_receive.dart` as plain functions over `AppState`, because
    the background push isolate decrypts too and whoever decrypts must act:
    the ratchet has already advanced past the envelope
  - **accepted, recorded, not fixed** (both in
    [design/16-groups.md](design/16-groups.md)'s "Known gaps"): blocking is
    one-directional inside a group — a blocked member is invisible to us,
    including other members' replies to them, while our own copies still reach
    them; and a deleted account keeps its member row forever, since no fact can
    express "this account no longer exists" and no member could prove it. Only a
    moderator removing them resolves the second one
  - **group receipts** — designed but unbuilt. `GroupConversation` already has
    the per-member watermark maps and the wire needs nothing new, but nothing
    sends or reads a `v: 2` receipt in a group yet. Whatever carries the anchor
    must be per group and per member: reusing the one-to-one path is what caused
    the cross-talk fixed above
  - **batch delivery** in the fan-out, and **attachments in a group** (one
    upload per distinct recipient server)
  - the UI — **first cut done 2026-08-03**: groups in the one chat list with
    their own glyph and author-prefixed preview, a `GroupChatScreen` with
    author lines and a k-of-N send indicator, creating a group, and joining or
    declining one behind a notice that says the group will see your address.
    The group info screen (member list, role actions, invite, leave/dissolve)
    followed on the same day. Still to come: filter chips, the delivery sheet,
    and system lines for state events
