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
  and APP-13 are waiting on. Getting a picture back *out* of a transcript — into
  the device gallery — is APP-20

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
- 2026-08-05 — the search box's text sat too high, and the cause was worth
  finding rather than nudging a padding: the field **grew from 40 to 48 pixels
  the moment a query existed**, because the clear button appears then and an
  `IconButton` carries a 48×48 minimum in its `ButtonStyle` that
  `constraints` alone does not override. So the text moved as soon as you typed.
  Fixed by sizing both icon boxes for the icons they hold and stating
  `textAlignVertical: TextAlignVertical.center` — a dense field with no label
  otherwise anchors its content to the top of whatever height the icons force.
  The field is now `AdminSearchField` in `lib/widgets/`, purely so it can be
  pumped alone: the regression test asserts that the text, the search icon and
  the clear icon share a centre line to within a pixel, and that the height does
  not change when the clear button appears. Vertical alignment is invisible to
  every other kind of test

### APP-11 — Admin-side user detail view
Status: `done` · Depends on: SRV-08 · Also benefits from: SRV-09, SRV-14
Design: [design/11-admin-user-detail.md](design/11-admin-user-detail.md)

Rows in the admin user list were an overflow menu and nothing else. They now open
a detail screen — deliberately not the peer profile, whose actions belong to a
conversation partner rather than an arbitrary account.

- 2026-08-02 — shipped, with two additions beyond the original plan: who invited
  this account (admins only, from SRV-14) and a button to start or open a chat
  with them
- 2026-08-05 — the screen was rebuilt to the shape the two profile screens
  already had, which is what it should have been from the start. Above the
  figures: the large avatar with its role badge, the role and block state as
  chips, the short id in headline size and the server beneath it, then both
  addresses as **copyable** rows. The header was previously a 32-pixel icon
  beside a `SelectableText` id — which read as a database row rather than a
  person, and made an operator select an id by hand where every other screen
  hands it over in one tap. At the bottom, block-for-all and delete became
  coloured section headings with a sentence each and a button, following
  `profile_screen.dart`'s "Danger zone" and `peer_profile_screen.dart`'s
  "Protection": a `ListTile` invites the tap before the text has been read,
  which is the wrong shape for two actions that reach every device an account
  owns. The screen stays its own file for the reasons at the top of it — a
  personal block and a ratchet reset are not an operator's actions — but nothing
  about its *layout* had a reason to differ, and the divergence was not a
  decision anybody had made
- 2026-08-05 — looked at on device together with APP-19, no findings

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
Status: `done` · Depends on: SRV-01, APP-08 step 2 · Also affects: shared Go core
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
- 2026-08-03 — the error banner learned to keep quiet. Andreas' first sighting of
  it was `stream error: TimeoutException after 0:00:10` — a single SSE connect
  attempt timing out, which the reconnect loop retries by design and the offline
  badge already shows. Failures now go through `_noteFailure`, which always logs
  and raises the banner only when the error is not mere unreachability
  (`isServerUnreachable`): a red banner for the most common self-healing
  condition would have trained the dismissal of the one thing meant to say "look
  at this". Applied to the stream, the group broadcast, the snapshot debts,
  prekey upload, push registration and the two capability checks
- 2026-08-03 — five of the open items, in one pass:
  - **group receipts**, and the design decision Andreas made with them: a
    receipt goes **only to the author** of the message it is about. Reading is
    between reader and author; fanning it out would hand every member a running
    attendance list of everyone else, at N times the traffic. `ReceiptSignal`
    gained an optional `group_id` (extending `v: 2` rather than minting a version,
    so an older build reads it as a one-to-one receipt and moves that watermark a
    little early -- a tick too soon, against a visible placeholder message if it
    had been a new `v`). The author files it per member and the k-of-N indicator
    counts over the copies that message was *owed*, not over current membership.
    `enterGroup` now also claims the open-chat slot, which is what makes "read"
    mean anything -- and `exitGroup` releases it, named for the screen so it is
    never confused with the signed `leaveGroup`
  - **filter chips** (All / Unread / Groups, with counts) above the list body,
    hidden entirely when there is nothing to filter. In memory: a filter is where
    you are looking now, not a setting
  - **the large-group warning** at 50 members, wording the actual cost (one
    encrypted copy per member per message) rather than a bare number
  - **batch delivery**: the fan-out encrypts every copy first, then posts one
    request per distinct recipient server (`/v1/messages/batch` and its federated
    twin), splitting at that server's advertised limit and falling back to
    individual posts for a server that does not advertise it *or* a batch request
    that fails outright. Encryption cannot be batched -- there is no group key --
    so only the transport collapses. The rollback that protects the ratchet had to
    change shape: the per-peer lock is held for the encryption only, and a failed
    copy is rolled back **only if that session has not moved since**, since
    restoring over somebody else's advance would be worse than the one-message gap
    the rollback avoids
  - **the proactive snapshot** the design has asked for since the start
    (freizone-server's `docs/design/01-groups.md`): a member whose `state_hash` has
    never been seen to agree with ours gets the whole fact set before their next
    copy. Their last hash is remembered per member and persisted, so a restart
    does not put a snapshot in front of every first message again
  - **`_askForGroupFacts`'s own edge**: the sender's server now comes from the
    envelope's encrypted content (`MessageContent.senderServer`) instead of only
    from an existing one-to-one conversation, so a group we hold no facts about
    can be asked about even when the only member who has written is federated and
    a stranger one-to-one
- 2026-08-05 — **device run of the last two pieces came back clean**, replying
  (APP-17) and the delivery sheet both, which closes this item. Worth noting
  against the two runs before it, which found four real problems each: those
  landed on the *receive* and *storage* paths, where several accounts on one
  device and a background isolate make the state harder than it looks. These two
  are a screen reading state that was already correct.

  What remains are the two gaps recorded as **accepted** below, not open work:
  blocking is one-directional inside a group, and a deleted account keeps its
  member row. Neither is fixable without a fact that cannot exist.

  The log of how it got here, in the order things were done:
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
  - ~~**attachments in a group**~~ — **done 2026-08-04.** The receive half was
    already there (`storeGroupMessage` keeps `content.attachments`,
    `ensureAttachmentDownloaded` is keyed on a chat-neutral id); the send half
    turned out to be blocked in the core and is tracked there as **SRV-18** — a
    blob was bound to one *device*, so "one upload per server" would in fact
    have been one upload per member. With that shipped: the group bubble renders
    a picture through the same `ImageAttachment` the one-to-one bubble uses, the
    composer grew the picker and staged-picture bar from `ChatScreen`, and the
    fan-out resolves its recipients *before* encrypting so it can upload once
    per distinct recipient server. The reference is keyed **per member**, not
    per server — a server advertising `max_blob_recipients: 1` (what silence
    means too) stores a blob per device, and keying by server could not express
    that. A server that cannot hold the picture costs only its own members the
    picture, not the group the message: they get the caption and the bubble says
    "N members could not receive the picture", or the delivery fails outright
    when there is no caption to send instead. **One decided piece is missing:**
    re-encoding a smaller rendition for a server with a smaller
    `max_blob_bytes`. `dart:ui` encodes only PNG and `image_picker` downscales
    at pick time, so that needs a Dart JPEG encoder — a dependency this repo
    deliberately does without. Those members are treated like a server with
    attachments off, and the picture is **not** shrunk for everybody, which is
    what that decision ruled out. Reasoning in
    [design/16-groups.md](design/16-groups.md)
  - **2026-08-04, first device run** — four findings from Andreas' test on a
    Pixel, all fixed. The significant one: a **transient** upload failure was
    recorded as a permanent "this member cannot receive pictures", and since a
    delivered copy is never revisited that verdict could not be undone — one
    dropped connection stranded the picture for good ("1 member could not
    receive the picture", twice, then unreproducible). Only a *stated* refusal
    (`404` blobs off / unknown device, `413` too large) is permanent now;
    anything else fails that member's delivery so the outbox retries the whole
    copy and it arrives complete. The others: the group transcript had neither
    the one-to-one chat's patterned backdrop nor its scroll-to-bottom (both
    simply missing); a picture only began downloading when the chat was opened,
    so the foreground session now starts it on arrival — which needed
    `ImageAttachment` to listen to `MediaStore`, since `ensureAttachmentDownloaded`
    answers null while an attempt is in flight and the spinner would otherwise
    never have been replaced; and that spinner was a fixed 28px inside an
    aspect-ratio clip, so in a short bubble it filled the rounded corners and
    read as a square — it is sized from the box now
  - **2026-08-04, second device run** — a picture received in a group stayed a
    blank bubble until the chat was left and re-entered, then appeared at once.
    Four causes, all fixed; regression tests in
    [`test/media_store_test.dart`](../test/media_store_test.dart). **The one that
    caused it:** `MediaStore`'s in-flight map was keyed by *message id*, while
    the files are per `accountId/chatId/messageId`. A received message id exists
    once per account that received it, so with several accounts on one device in
    the same group the first account's download made the picture look already
    claimed for all the others — they waited instead of fetching, and the file
    they waited for went into somebody else's directory, so the completion
    notification left them nothing to adopt and nothing more to wait for. Keyed
    by the same three ids as the file now. On-device mtimes showed it plainly:
    one picture, four accounts, full files landing at +0.8 s, +9 s and +71 s, the
    last only after a restart cleared the claim. The other three: the store's
    `instance()` cached the resolved store rather than the future resolving it,
    so racing first callers each built their own notifier; `ImageAttachment`
    dropped a notification arriving while it was still stat-ing files, and now
    also re-checks the disk when the transcript rebuilds; and the group receive
    path never wrote the inline preview thumbnail (only the one-to-one path
    did), which is *why* it read as empty — the placeholder is
    `surfaceContainerHighest` inside a bubble of the same colour. Note for the
    record: fixing the store race made the keying bug deterministic instead of
    intermittent, because split stores had been accidentally providing the
    per-account isolation the key was missing
  - ~~**the delivery sheet**~~ — **done 2026-08-04.** Tapping the k-of-N
    indicator lists the message's recipients, worst first and then by id, so
    whoever it failed for is at the top and the order cannot reshuffle
    underneath a tap (APP-10's rule). The row's state is a *combination* of two
    independent facts, which is why it became `GroupConversation.stageFor` with
    tests of its own rather than a `switch` in the widget: `GroupDelivery.state`
    is what that recipient's **server** did with our copy, the watermarks are
    what the **recipient** confirmed, and only "the server took it" leaves
    anything for a receipt to add. Hence a stage named `sent` distinct from
    `received` — a copy sitting in somebody's queue until their phone next
    connects is not a copy they have. Retry is offered only when a copy actually
    failed, labelled "Resend to those it failed for" because the guarantee worth
    stating is the one about *not* re-sending: `retryGroupSend` never revisits a
    delivered copy, so nobody gets it twice. Two details the wiring forced: the
    indicator stays inert for a message nobody was owed a copy of (a group of
    pending invitees) rather than opening an empty sheet, and the sheet re-reads
    the message from the session on every rebuild instead of capturing it — the
    fan-out mutates deliveries in place, and a receipt arriving while the sheet
    is open is precisely what it was opened to watch
  - the UI — **first cut done 2026-08-03**: groups in the one chat list with
    their own glyph and author-prefixed preview, a `GroupChatScreen` with
    author lines and a k-of-N send indicator, creating a group, and joining or
    declining one behind a notice that says the group will see your address.
    The group info screen (member list, role actions, invite, leave/dissolve)
    the state-change system lines, the filter chips and the large-group warning
    followed on the same day; message actions (APP-21), replying (APP-17) and
    the delivery sheet closed it out on 2026-08-04

### APP-17 — Replying to a message in a group chat
Status: `done` · Part of: APP-16

Long-press to reply, and a quote block that says **who** is being answered.
Replying already works in a one-to-one chat; a group has the long-press menu
since APP-21 but no reply entry in it, and `_GroupBubble` renders no quote.

Most of the plumbing is already there: `sendGroupMessage` takes a `replyToId`,
the fan-out puts it and a `ReplyPreview` into every copy's `v: 4` content, and
the receive path stores `replyToId` / `replyPreviewText` / `replyPreviewMine`.
What is missing is the UI, plus one wire field:

- **The quoted author has nowhere to travel.** `ReplyPreview` carries `text` and
  `mine` — a bare "were you the one being quoted", flipped to the receiver's
  perspective by the sender. In a one-to-one chat that identifies the author
  completely, because there are only two. In a group it does not: a third member
  reading Ben's reply to Carla gets `mine: false`, which says only "not you".
  So the preview needs the quoted message's **author account id**, as a new
  optional field — additive, so an older build simply ignores it.
- **Absence must still render sensibly**, since a reply from an older build
  carries no author: fall back to resolving it from local history
  (`messageById(replyToId)?.senderAccountId`), and if that misses too — a member
  who joined after the quoted message, or whose history was cleared — show the
  quote without an author line rather than guessing.
- The quote block itself should be the one-to-one bubble's, including APP-13's
  camera-icon stand-in for a quoted picture, and the author line should use
  `avatarColorFor` so a name in a quote matches the same person's colour in the
  transcript and the member list.

- 2026-08-04 — shipped as planned, with the wire field as `author` inside
  `reply_preview` and sent **only** by the group fan-out: in a one-to-one chat
  `mine` identifies the author completely, so that message stays byte-identical
  to what it was before this item. Both halves of the reply UI became shared
  widgets rather than a second copy — `ReplyQuote` (the block inside the bubble)
  and `ReplyComposerBar` (the "replying to …" bar), the same move APP-21 made
  with `PinnedMessageBar`. Three things worth recording:
  - the four-branch author fallback is a **pure function**
    (`util/quoted_author.dart`, `resolveQuotedAuthor`) rather than a getter on
    the bubble, because the failure mode is a confidently wrong name and that
    deserves tests of its own. Its last branch is the interesting one: with no
    stated author, no local copy of the quoted message, and `mine: false`, the
    quote renders **with no author line at all** — "not you" is not a name
  - resolving from local history has to read `mine` and not just
    `senderAccountId`: that field is null on our own messages, which is the one
    author a transcript never stores, not a missing one. Without that branch a
    reply to *my own* message from an older build would have lost its label
  - the author line takes `avatarColorFor` as asked, **except inside my own
    bubble**, whose background is the theme's primary — the avatar palette is
    curated for contrast against white, not against an arbitrary accent, so a
    quote there would have been a colour with no readability guarantee. Deemed
    the lesser loss: the colour identifies a person, and my own bubble is the
    one place the surrounding transcript already says who is speaking
- 2026-08-05 — verified on device, no findings

### APP-18 — Names, not short ids, in a group transcript
Status: `done` · Part of: APP-16 · Related: APP-19

A group labels each author with five characters of their account id, so reading
one means holding a mental table of `qk43r` → Carla. Where this account has
already assigned that person a name, show the **name with the short id in
parentheses** instead — in the transcript, the member list and the reply quote
(APP-17).

The long-press menu on a group message grows two entries about its author:

- **Message them directly** — open the existing one-to-one chat, or start one
  (the invite-to-chat path) when there is none.
- **Name this person / change name**, effective for every chat *this* account has
  with them, not just the group it was set from.

One constraint shapes this: `displayName` lives on `ChatTarget`, i.e. on a
**conversation**, and so does `blocked`. A group member this account has no
one-to-one chat with therefore has nowhere to store a name today. Creating an
empty conversation to hold one would litter the chat list with chats nobody
started — the very thing `PeerEndpoint` was split out of `Conversation` to avoid.
So this needs a small per-person record keyed by account id, which is the first
piece of APP-19 and the reason the two are related. Whether that record is
per-account or app-wide is APP-19's open decision; APP-18 only needs it to exist
per account, which both options provide.

- 2026-08-05 — raised again from the device: APP-19 shipped the store and the
  contacts area, but nothing in a group *read* it, so the item that was supposed
  to make group conversations legible had not landed at all. Built as planned,
  with four things worth recording:
  - the label is **one function**, `util/person_label.dart`'s `personLabel`, and
    all six surfaces call it: the transcript's author lines, a reply's quote, the
    "replying to …" bar, the member list, the delivery sheet and the chat-list
    preview. A per-screen `?? shortAccountId(...)` would have drifted, and a
    person labelled two ways reads as two people — the exact confusion this item
    exists to remove
  - the chat-list preview is the **one deliberate exception**
    (`personLabelCompact`): a name with no id. That row is a single truncated
    line, and `Clara (qclar): bis morgen` would spend a third of it on
    parentheses. Safe precisely because nothing is decided from a preview — the
    full label is one tap away. Unnamed, it still shows the short id
  - the **member list lost the full 21-character id** it used to print, in favour
    of the same label the transcript uses. It answered no question that screen
    asks: it was never copyable from there, and a full address belongs to the
    contact and peer-profile screens, which have one
  - `ChatTarget.lastMessagePreview` became `previewFor(ContactStore)` —
    `titleFor`'s reasoning applied to the second thing a chat-list row draws: a
    required parameter is what makes the compiler point at every place a name is
    shown, rather than a forgotten lookup quietly falling back to an id
- 2026-08-05 — **system lines are deliberately left as short ids.** A line like
  "qk43r joined the group." is frozen into the stored transcript when it is
  written (`state/group_system_lines.dart`), not resolved when it is rendered, so
  that re-labelling it later cannot rewrite history — and the receive path that
  writes it runs in the push isolate, where the contact store must not be
  touched. Consequence to live with: a named person reads as "Clara (qclar)" in a
  bubble and as "qk43r" in the line above it. Revisit by resolving *display*
  from a stored id rather than by storing a label, which is a change to what a
  system line is, not a lookup

### APP-19 — An app-wide contacts area
Status: `done` · Related: APP-18
Design: [design/19-contacts.md](design/19-contacts.md)

One place to keep the people this device knows, with its own icon in the main bar
rather than a slot in the overflow menu. Beyond naming, it is where the
multi-account questions get answered: which of my own accounts to start a chat
from, and — the one that matters most — **which of my accounts already talk to
this person**, so I do not write to someone from an identity they cannot place.

- 2026-08-04 — shape decided. The store is **central**, shared across this
  device's accounts: one person with one device does not have to inherit their
  accounts' split-brain. Every *action* on a contact stays account-specific
  (block, chats), which is the complexity accepted in exchange. A contact **is
  one address**, so one name — a person with a work and a private account is two
  contacts, which they would have to be named apart as anyway; no per-account
  name override. A contact exists only by a deliberate act (naming someone in a
  chat or group, or creating one by hand), never from having seen an account. A
  hand-typed address is **resolved at creation and stored canonical only**, on
  the phantom-member precedent from APP-16 — a stored prefix is a contact that
  fails the moment it is used; the public `GET /v1/accounts/{id}` directory makes
  that possible without any account of ours. The detail screen lists existing
  chats with the account each belongs to, and offers "start new chat" with an
  account picker *only* when an account of mine is not already talking to them,
  which keeps entering a chat distinct from starting one
- 2026-08-04 — the contact store is also the **only** place a name lives: every
  screen reads it from there, deleting a contact drops the name everywhere and
  keeps every chat. `BlockedPeer.displayName` goes away;
  `ChatTarget.displayName` stays only in its *other* meaning, a group's own name.
  Needs a one-time import of the aliases already sitting in each profile, or
  switching the source of truth would silently discard every name ever assigned.
  Deleting became **three** actions, ordered by the rule that losing a message is
  the worst outcome available: **remove a contact** takes away the name entry and
  nothing else — no chat, history or crypto touched; **delete a chat** drops the
  conversation, its media and the peer's `knownPeerIds` entry so a resumption
  arrives as a request to accept or decline, but **keeps** the ratchet session,
  because dropping it produces an SRV-03 desync in which the very message that
  should have been that request is undecryptable and lost; **remove permanently**
  is the durable one for an orphaned chat and takes the session too, gated on
  evidence from the public `GET /v1/accounts/{id}` directory (`404`, or no active
  device, means nothing can arrive from them again, so nothing can be lost).
  "Unreachable" is explicitly not treated as gone. The account picker also
  consults `federationLocked` per account, so it never offers to start a chat from
  an account that cannot reach the contact — otherwise the option fails after
  being chosen, which is the mistake this screen exists to prevent
- 2026-08-05 — being built in four phases, because the risk is concentrated in
  the second: **(1)** the store and the one-time import, **(2)** the read path,
  where the name's source of truth actually moves, **(3)** the contacts list and
  the detail screen with its account picker, **(4)** the three deletions.
- 2026-08-05 — **phase 1 shipped**, and it deliberately changes nothing a user
  can see: `ContactStore` (`lib/state/contact_store.dart`) is device-wide, in its
  own JSON file beside `AppSettings` rather than in any profile, and
  `importExistingAliases` lifts every alias out of every profile at startup. Four
  things settled while building it:
  - the store takes **plain maps**, not `AppState`, and the profile-reading half
    is a separate adapter (`contact_import.dart`). The store is meant to be
    account-independent, so a dependency on per-account state would have
    contradicted the decision it exists to implement — and it is testable
    without building a profile
  - **collision order is deterministic**: profiles are iterated by sorted account
    id, not in whatever order the directory listed them, or which of two names
    survived would depend on the filesystem. Identical names in two profiles are
    not a collision and are not reported — that would train the dismissal of the
    one notice meant to say "you have a decision to make"
  - the import reads `blockedPeers[…].displayName` as well as the conversation
    aliases. That field exists *only* because the blocked list had to show a name
    with no conversation left, so skipping it would have lost the names of
    exactly the peers a user had most reason to label. Within one profile the
    live conversation alias wins over the block-time snapshot
  - "has the import run" is **recorded**, not inferred from an empty store: a
    user who deletes every contact must not have their old aliases resurrected on
    the next start
  - the import reads **raw profile JSON**, not `AppState` — a correction Andreas'
    question forced out. Phase 2 takes `display_name` off `Conversation`, so an
    import going through the parsed model would find nothing left to import
    unless the two phases shipped in separate releases *and* every user passed
    through the intermediate one. A skipped version would have lost every
    assigned name. `LocalStateStore.listProfileJson` exists for this
- 2026-08-05 — **phase 2 shipped: the contact store is now the only place a
  person's name lives.** `displayName` moved off `ChatTarget` down onto
  `GroupConversation`, where it keeps its other meaning — the name a group gave
  itself — so a `Conversation` has no such field and `writeBaseJson` no longer
  emits the key. `BlockedPeer.displayName` and `AppSession.setDisplayName` are
  gone, and `startConversation` lost its `displayName` parameter. No cleanup
  migration was needed for the old values: a profile is rewritten in full on
  every message, so the key disappears on the next save because nothing writes
  it. Decided against threading the store through `AppSession` (option (a)) in
  favour of passing it to the screens like `AppSettings` (option (b)): push
  notifications carry no names, so the background isolate needs nothing, and only
  three places in `AppSession` ever touched a peer alias. Three findings:
  - `titleFor` takes the **store** rather than a name the caller looked up. The
    signature must stay uniform — a chat list draws both kinds through it — and a
    *required* parameter is what made this compiler-guided: 18 call sites named
    themselves, where an optional one would have let a forgotten lookup fall
    back to an address and look like a missing name
  - **a rebuild at the root does not reach a pushed route**, which is what I had
    told Andreas would carry the notifications. A `MaterialPageRoute` builder
    runs once and the route holds its result; a theme survives an ancestor
    rebuild only because `Theme` is an `InheritedWidget`. So each screen showing
    a name listens for itself via `Listenable.merge([session, contacts])`
  - `NewChatSheet`'s optional name was the one non-mechanical case: it now writes
    the contact *after* `startConversation` returns, because the returned
    conversation carries the **canonical** id and the field may hold a prefix —
    resolve-at-creation, arrived at from the other direction
- 2026-08-05 — **phase 3 shipped: the contacts area exists.** Its own icon in the
  chat list's app bar rather than an overflow entry, because it is the one screen
  there that is *not* about the selected account. The list shows every contact
  with the address still under the name — a name is what one person decided to
  call another, and somebody else could claim the same one. Adding by hand
  resolves before it saves (`contact_resolver.dart`), and the detail screen
  answers the multi-account questions. Four things worth recording:
  - the resolver distinguishes **"no" from "could not ask"**, and only the first
    is an answer. A 404 or a non-Freizone host means the address is wrong; an
    unreachable server or a 500 means nothing was learned, so no contact is
    created and the button becomes "Try again". Without that split, one dropped
    connection writes a contact that fails the first time it is used, long after
    anybody remembers typing it
  - resolution is genuinely account-independent — `GET /v1/accounts/{id}` is
    public — but it does need a **host to ask**, so a bare id is resolved against
    the active account's server, the same convention the new-chat sheet applies.
    Worth stating, since the design document's "needs no account of ours" is true
    of authentication and not of host selection
  - the detail screen splits my accounts into **already talking** and **could
    start**, which is what keeps "open the chat" distinct from "start a new one".
    An account that cannot reach the contact is listed separately *with the
    reason* rather than omitted: `federationLockedFor` is consulted before the
    action is offered, and silently hiding it would make "any account that isn't
    talking to them yet" false in exactly the federated setups that motivate
    having several accounts
  - the import notice from phase 1 finally has somewhere to appear, at the top of
    the list, and it is only ever raised for a real disagreement
- 2026-08-05 — **phase 4 shipped, and with it the item.** The three deletions:
  *remove a contact* (the name only) landed with phase 3; *delete a chat* now
  also drops the peer from `knownPeerIds`; and *remove permanently* is new,
  taking the ratchet session too, gated on evidence from the public account
  directory (`peer_absence.dart`), and offered below "Delete chat" because it
  does strictly more. Three things to record:
  - **deleting a chat reverses an earlier deliberate choice.** `acceptConversation`
    added the peer to `knownPeerIds` specifically so that a later delete would
    *not* "regress them to an unactioned request"; the 2026-08-04 decision wants
    the opposite — deleting is a decision about the relationship, so somebody
    writing again is an event worth surfacing rather than a chat quietly
    reappearing. Implemented as decided, with the reversal written into
    `deleteConversation`'s own doc comment so the next reader does not find only
    the old rationale. The "delete chat" wording now says so
  - the verdict type is deliberately five-valued, not a boolean: `gone`,
    `noActiveDevice`, `notAFreizoneServer` are definite absences and lose nothing
    by construction, while `unknown` **and** `present` both keep
    `couldStillLoseMessages` true. Collapsing "I could not ask" into "gone" is
    exactly how this action would cost somebody their messages
  - the risk is stated as what it actually is rather than as "cannot be undone":
    if that peer does write again, their first messages cannot be read until the
    encryption has been rebuilt. Only shown when the check could not establish
    absence
  Left open on purpose, as the design document already had it: whether a
  permanent removal should mark the peer so their *first* undecryptable envelope
  triggers an immediate re-key instead of waiting for SRV-03's evidence to
  accumulate. It only matters in the case just called unlikely.
- 2026-08-05 — **verified on device, no findings**, across all four phases: the
  name import on first start, the contacts list and detail screen, adding by
  hand, and the three deletions. Notable only because the two device runs during
  APP-16 found four real problems each — those were on the receive and storage
  paths, where several accounts on one device and a background isolate make the
  state genuinely hard; this is a store with one writer and screens that read it.

### APP-20 — Save a picture from a transcript to the device gallery
Status: `planned` · Part of: APP-04

A picture in a transcript can be looked at and nothing else. Full-screen view
exists (`ImageViewScreen`, reached by tapping the bubble in a one-to-one chat and
in a group alike, since both render through `ImageAttachment`), but its app bar
holds only the back button, and the long-press sheet offers reply, pin and
"delete for me" — so a picture somebody sent cannot leave the app at all. Two
routes to add, plus an optional third:

- **From the full-screen view** — a save action in `ImageViewScreen`'s app bar,
  which is empty today and is where someone who is already looking at the picture
  will reach for it.
- **From the long-press sheet** — one more entry in `_showMessageActions`, shown
  only for a message that actually has a picture. Both chat kinds have that sheet
  now (APP-21), so this is one entry per screen and no gesture work.
- **Automatically on receipt** — a setting, so the pictures of a chosen
  conversation (or of all of them) land in the gallery without being asked for
  each time.

Four things decided 2026-08-04, before any of it is built:

- **A gallery copy leaves the app's protection**, and the automatic variant is
  therefore **opt-in, off by default**. Everything the app stores today sits in
  its own private directory; a picture in the gallery is readable by every app
  holding media permission and, on most phones, uploaded to Google Photos within
  minutes. That is the whole point of the feature and also the one property an
  end-to-end-encrypted messenger must not hand over by accident, so the setting
  has to state what it does rather than read as a tidy convenience toggle. The
  manual save is an act each time and needs no such framing.
- **Share as well as save**, not instead of it. `share_plus` is already a
  dependency and hands the picture to whatever app the user picks; saving files
  it in the gallery. Different destinations, both offered — in the full-screen
  view's app bar and in the long-press sheet.
- **Only received pictures.** One this account sent came out of this device's own
  gallery in the first place (`image_picker`), so saving it would file a second
  copy of something already there. Worth revisiting when APP-04's **camera
  capture** lands: `image_picker`'s camera source writes to the app's cache
  directory, not the gallery, so a self-taken picture would then be one that
  exists nowhere else — at which point "only received" stops being the obvious
  rule.
- **The storage permission is requested, not designed around.** Saving means an
  insert into Android's own `MediaStore` (`MediaStore.Images`, `RELATIVE_PATH` of
  `Pictures/Freizone` so the copies are grouped) — not to be confused with this
  app's `MediaStore` (`lib/state/media_store.dart`), the local media cache. On
  API 29+ that insert needs no permission at all; `minSdk` is Flutter's default
  **24**, so API 24–28 devices are in scope and there the write needs
  `WRITE_EXTERNAL_STORAGE`. The manifest gets it with
  `android:maxSdkVersion="28"` and the platform side asks for it at runtime
  before the first save, rather than the cheaper alternative of hiding the action
  below API 29. Following APP-15 and `secure_screen.dart` this belongs on our own
  `MethodChannel` in `MainActivity` rather than a dependency — and it is the
  first runtime permission the app asks for *itself* (`CAMERA` and
  `POST_NOTIFICATIONS` are requested by `image_picker` and
  `flutter_local_notifications`), so `MainActivity` needs
  `requestPermissions` plus an `onRequestPermissionsResult` that resolves the
  pending channel result. A refusal has to leave the picture where it is and say
  so, and be re-askable later.

One detail that survives all of it: the on-disk file is already plaintext
(`MediaStore.fileFor`, written after `core.decryptBlob`), so a save copies bytes
and decrypts nothing — but a picture whose download has not finished has no file
yet, and the action must be absent rather than fail.

### APP-21 — Pin and delete a message in a group
Status: `done` · Part of: APP-16 · Related: APP-17
Design: [design/16-groups.md](design/16-groups.md) (section "Message actions in
a group")

A group bubble had no long-press gesture, so neither pinning a message nor
deleting one from this device was reachable — both purely local, both long
available in a one-to-one chat. Reply is the same menu's third entry and stays
with APP-17, which needs a wire field first.

- 2026-08-04 — **done.** Long-press menu on a group bubble (pin/unpin, "delete
  for me"), the pin marker on the bubble, and the sticky pinned bar above the
  transcript. `deleteMessageLocally` / `pinMessage` / `unpinMessage` now take a
  chat id resolved through the new `AppSession.chatTarget`, instead of looking
  only in `state.conversations` — a group id was a silent no-op before.
  `PinnedMessageBar` and the delete confirmation became shared code (one bar,
  one wording, `ChatTarget`-typed) rather than a second copy in the group
  screen, and the group transcript builds eagerly now so the bar can actually
  scroll to an older pin.

### APP-22 — Verified-operator badge
Status: `planned` · Also affects: freizone-server (SRV-19)
Design: [design/22-verified-badge.md](design/22-verified-badge.md)

Show that a server is operated in agreement with the project. SRV-19 carries the
attestation and the verification rule; what lands here is placement — the setup
wizard, the account switcher's existing avatar slot, the server line of a peer's
profile, and the admin area's own status with an expiry warning. And, the
delicate half, the places it is kept out of: a tick beside a person's name says
something this attestation does not.

- 2026-08-05 — created alongside SRV-19
