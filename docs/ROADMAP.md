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
- **Open** — APP-08 step 2 (the durable outbox) is next, then `pkg/group` over
  FFI. Two receive-path requirements the reference client turned up are recorded
  in the design document and must not be lost: simultaneous X3DH establishment,
  and holding control envelopes that arrive out of order
