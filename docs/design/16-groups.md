# Design: Groups (client side)

Status: **planned** · Roadmap: [APP-16](../ROADMAP.md) · Depends on: SRV-01, APP-08 step 2
· Also affects: shared Go core, freizone-server (`pkg/group`)

The protocol itself — group identity, the authority model, event encoding,
convergence — is designed in freizone-server's
[design/01-groups.md](https://github.com/behringer24/freizone-server/blob/master/docs/design/01-groups.md)
and is not repeated here. The one-line recap that matters for this document: a
group is a **self-certifying cryptographic object with no server behind it**.
Messages ride the existing pairwise Double Ratchets with **no group key**, and
membership plus roles are a **grow-only set of signed facts** that converges via
a `state_hash` carried on every group message.

This document covers only what that means for this repo.

## What already works in our favour

Worth stating first, because it decides how large this item actually is:

- **The per-peer send primitive is already correct.** `AppSession._deliver` /
  `_encryptAndSend` handle device resolution, prekey claim, first-contact
  session establishment, federation and re-key. A fan-out is a loop over that,
  not a new send path.
- **Session serialization already exists per peer.** `_withPeerSessionLock`
  is per peer, so a fan-out takes N locks in sequence and never needs a global
  one.
- **Unknown envelope versions already degrade correctly.**
  `MessageContent.decode` renders a neutral placeholder for a `v` it does not
  know, which is exactly what an older build must do with a group message.
- **`pendingApproval`** (the 1:1 "message request" state) is the precedent for
  an unaccepted group invitation — same idea, same place in the UI vocabulary.
- **`MessageAttachment`** needs no change at all: one blob key per attachment,
  uploaded once per distinct recipient server, referenced per recipient.
  *Correction, 2026-08-04:* true of the format, and the format is indeed
  unchanged — but the *server* bound a blob to one device, so "once per
  recipient server" needed SRV-18 before it could be built. See "Sending a
  picture into a group".

## Group logic lives in the Go core

`pkg/group` lands in freizone-server (public, like `pkg/ratchet` and
`pkg/wire`) and is reached over FFI, following APP-01's precedent of keeping
key material and format rules on the Go side. One implementation serves the
app, `cmd/devclient` and any future client, and it is testable without Flutter.

Four new exports in `native/core.go`, in the established JSON-in/JSON-out shape:

| Export | Does |
|---|---|
| `GroupCreate` | Derives the group root key from the account root key and a fresh `group_nonce`, emits genesis (plus a meta event if a name was given), returns the initial state blob |
| `GroupSignEvent` | Builds an event's signing bytes and signs it, returning the event with its `signer` block |
| `GroupApplyEvents` | Merges incoming events into a state blob; returns the new blob, its `state_hash`, and a per-event verdict (`applied` / `known` / `rejected` + reason) |
| `GroupResolveState` | Folds a state blob into the derived view the UI renders: members with roles, pending invitees, name, topic, my own role |

**Shipped 2026-08-02**, with two refinements the implementation argued for.
Genesis is the founder's membership, so `GroupCreate` emits no self-add and no
self-accept — two events nobody would ever have checked. And `GroupSignEvent`
decides *which key* signs rather than taking it as a parameter: raising someone
to admin is the founder's alone and needs the group root key, everything below
is an ordinary device signature. Asking the caller would be one more thing a
client could get wrong for no benefit. Every mutating call also returns the
resolved view alongside the blob, so the UI never needs a second round trip
just to redraw.

The **state blob is opaque to Dart** — it is persisted and handed back, never
interpreted, exactly as a `RatchetSessionJson` is today. Dart renders only
`GroupResolveState`'s output. That keeps the convergence rules in one place and
means a Dart bug cannot produce a state that disagrees with another client's.

The group root key is derived **inside the core** from the account root key
(`HKDF-SHA256(account_root_seed, "Freizone-Group-Root-v1" || group_nonce)`), so
the seed never crosses the FFI boundary — the same reason `pkg/mnemonic` lives
where it does. Because the nonce is stored in the genesis event, a founder who
restores from the seed phrase and receives the group state from any member can
re-derive the key with no extra backup material.

## Data model: a `ChatTarget` base

`Conversation` is built around `peerAccountId`, and `chat_screen.dart` (~1450
lines) plus `chat_list_screen.dart` are built around `Conversation`. A group has
no peer.

So: extract a slim **`ChatTarget`** base carrying what the screens actually
need — a stable id, a title, `messages`, `lastActivityAt`, `hasUnread`,
`pinnedMessageIds` — and let `Conversation` (1:1) and `GroupConversation`
inherit from it.

- Stays 1:1-only: `peerServer`, `peerDeviceId`, `peerDevicePubKey`, `blocked`,
  `pendingApproval`, and the single receipt watermark pair.
- New on `GroupConversation`: `groupId`, the derived roles view, `myRole`,
  `invitePending`, and **per-member receipt watermarks** — a map
  `account_id → delivered/read`, because "read by 12" cannot be expressed by
  the single `peerReadUpTo` value a 1:1 conversation uses. The wire format needs
  nothing for this: a `v: 2` receipt already names a `message_id`, the author
  resolves the group locally, and the envelope already says who sent it.

**The refactor is its own commit, before any group code**, with no behaviour
change. Mixing it into the feature would make both unreviewable.

**Shipped 2026-08-02.** `ChatTarget` and `StoredMessage` live in
`state/chat_target.dart`, which `conversation.dart` re-exports — so every
existing `import 'conversation.dart'` keeps working and the diff stays at the
files that actually changed. The media path moved off `peerAccountId` to a
neutral `chatId` (`MediaStore.fileFor`/`thumbFor`/`chatDir`/`deleteChatMedia`,
`AppSession.ensureAttachmentDownloaded`/`_deleteChatMedia`/`_storeOwnAttachment`,
`ImageAttachment`); the layout on disk is unchanged, since a group id is the
same 21-character bech32m string a peer's account id is. `StoredMessage` also
gained an optional `senderAccountId`, null for every one-to-one message and
therefore absent from existing history — the one forward-looking addition, made
now rather than touching the same class twice. Verified against a baseline taken
before the change: `flutter analyze` unchanged at 33 pre-existing issues, tests
216 → 219, the three new ones pinning the persisted key set so a field lost in
the extraction fails loudly instead of quietly failing to load.

## Persistence: one file per group

The profile JSON is rewritten on **every single message** — the documented
reason image bytes were kept out of it. A group's fact set has the opposite
write profile: ~80 KB that changes rarely.

- `groups/<group_id>.json` — the opaque state blob, written atomically
  (temp + rename). Since the fact set is grow-only, a lost write costs at most
  one re-sync, never a corrupt state.
- The **transcript stays in the profile JSON**, alongside 1:1 conversations, so
  the chat list, unread handling and pinning keep one loading path.
- Deleting a group deletes both, and `sweepOrphanedMedia` already covers the
  attachment files.

**Shipped 2026-08-02** as `groups/<account id>/<group id>.json` — per account,
matching how media is already laid out, since one device holds several
accounts. A damaged or unreadable group file is treated as absent rather than
fatal: the fact set is grow-only and any member can hand back a full snapshot,
so the cost is a re-sync, and refusing to start an account over one group's
file would be far worse.

Two things the wiring settled:

**Exactly one derived value is cached outside the fact set**, and it has one
writer. A chat-list row needs a title, and folding every group's file to draw
the list would be absurd — so the folded name is copied onto the transcript
whenever the fact set changes, together with whether this account's own
invitation is still outstanding. Everything else the UI needs comes from
`GroupResolveState` at the moment it is asked. A second copy of the membership
here would be a cache that can disagree with the signed truth, which is the one
thing the split exists to prevent.

**`sweepOrphanedMedia` had to learn about groups.** It collects the message ids
that still exist and deletes every media file not among them; iterating only
one-to-one conversations would have swept away the pictures of every group
message on the next startup. It now walks `AppSession.chats`, which is both
kinds. The same reasoning applies to account deletion, which now removes the
group directory alongside the profile and the media.

**Superseded by the SRV-23 cut (2026-08-10), recorded 2026-08-15.** Everything
in this section describes storage the app no longer owns: a group's facts live
in the core, under `groups/<group id>/` beside its held events and per-member
sync state, and its transcript under `chats/<group id>/` like any other chat's.
Three consequences worth having written down, because each was a live bug until
they were:

- **Removing a group is `CoreAccount.deleteChat`**, which for a group id also
  calls `pkg/client`'s `ForgetGroup`. That last part is what actually takes it
  off the list: `Client.Groups` is a directory listing, so a group whose facts
  are still on disk is still a row — however long ago one left it. Between the
  cut and 2026-08-15 there was no way to remove those facts at all, carried as a
  written-down known limitation rather than fixed.
- **There is no orphan sweep any more, and none is needed.** A picture is
  deleted with the message it belongs to (`Client.DeleteMessage`) or with the
  chat (`ClearTranscript` + `DeleteChatMedia`), so nothing outlives its
  reference in the first place. `sweepOrphanedMedia` is gone rather than
  narrowed: what was left of it only cleared the pre-cut Dart tree, which is an
  artefact of the migration and not something worth running at every start
  forever. `media_store.dart` went with it, having had no other caller since
  the cut, and so did `GroupStateStore`'s two deletions.
- **Account deletion had to learn the same lesson**, and this is where a group's
  facts were being left behind wholesale: it removed the pre-cut
  `groups/<account id>/` directory and not `core-<accountId>`, which holds the
  real fact sets along with everything else the account owns. Fixed 2026-08-15
  (`deleteCoreState`) — and that one *is* permanent code, because every install
  creates that directory. The pre-cut trees beside it are cleared by hand, once,
  on the few devices that have them.

**And with it, the Dart-side fold itself (2026-08-15).** Tracing what still
reached `GroupStateStore` found nothing did, and the trace did not stop there:
every method that would have used it had lost its own caller at the cut. Gone,
with the reason each is not missed:

| Removed | What does it now |
|---|---|
| `loadGroupStates`, `_storeGroupState`, `GroupStateStore` | the core persists a group's facts, in `groups/<group id>/facts.json` |
| `_groupStates`, `_refreshGroupName(s)` | `groupState` folds on demand from `CoreAccount.groupInfo`; a row's name arrives with the row (`ChatSummary.title`) |
| `signGroupEvent`, `applyGroupEvents`, `_groupIdentity` | the core signs, merges and verifies — `CoreAccount.invite`, `setRole`, `leaveGroup` and friends act on an open handle |
| `group_system_lines.dart` and its test | `pkg/client` has its own `groupStateChangeLines` and writes the lines into the transcript itself (`groups.go`) |

That last one is the one worth pausing on: the narration existed **twice**, in Go
and in Dart, and only the Go copy has run since the cut. Two implementations of
one rule that nothing forces to agree is exactly what SRV-23 exists to end, so
this was less a cleanup than the last piece of the cut being finished.

Still standing deliberately: `FreizoneCore.groupCreate`, `groupSignEvent`,
`groupApplyEvents` and `groupResolveState` now have no caller in the app either,
but they are exported C symbols with Go tests, and the FFI surface serves more
than this one consumer. Narrowing it is a decision about that surface rather
than leftover cleanup, and is not made here.

## Sending: fan-out over a durable outbox

**APP-08 step 2 is a hard prerequisite, not a nice-to-have.** A fan-out that
dies at recipient 7 of 20 loses the rest permanently today, because
`Conversation.toJson` deliberately drops `pending`/`failed` messages. That is
correct for 1:1 and fatal for a group.

**Groups also settle step 2's open fork: enqueue plaintext, not ciphertext.** A
group message must be encrypted N times against N different sessions; the
ciphertext model would commit N ciphertexts to N specific session states at
enqueue time, any of which a `Reset secure session` or an SRV-03 re-key
invalidates. Plaintext in the queue, encryption at the moment of sending, strict
serialization per peer — the option APP-08 lists second — is the only one that
composes with fan-out.

The rest follows:

- **One outbox item per (message_id, recipient device)**, so progress is k/N, a
  partial fan-out is visible rather than silent, and a retry can address the
  failed recipients alone (see the delivery sheet under "UI").
- **Each copy needs its own wire message id, and it must be stable.** APP-08
  step 2 made a retry re-use the message's id so the server's `409` means
  "already delivered" instead of a double send. In a group that same id cannot
  be re-used across recipients: two members on the same server would collide,
  the second copy would be answered `409`, and this client would record it as
  delivered to someone who never got it. So the id is per recipient — and
  deliberately not `message id + account id`, which would let a server (or two
  servers comparing notes) recognise N copies as one group message. A random id
  per recipient, kept with that recipient's outbox item so a retry re-uses it,
  gives idempotency without the linkage.
- **Batch where possible**: group the items by recipient server and use
  `POST /v1/messages/batch` (or the federated variant) where that server's
  `GET /v1/server-status` advertises `batch_messages`, falling back to
  individual posts per server otherwise. In a non-federated community that is
  N→1. **Not yet done** — the fan-out posts individually, which works against
  every server and is exactly what the fallback would do anyway. Batch is an
  optimization, and doing it needs `_encryptAndSend` split so the payload can
  be produced without posting it.
- **Attachments in a group. Done 2026-08-04**, once the core could store one
  blob for several recipients (freizone-server's SRV-18 — until then "once per
  recipient server" was not implementable at all, since a blob was bound to one
  device). See "Sending a picture into a group" below.
- **Receipts go to the author only**, keeping traffic linear.
- **Above ~50 members the client warns.** This is not a protocol limit — see the
  server-side design for why — so it is purely a UI guard.

## Sending a picture into a group

Shipped 2026-08-04, on top of freizone-server's SRV-18.

A blob lives on the **recipient's** server, so a group picture has as many
destinations as the group has distinct servers. The fan-out therefore gained a
phase: who is owed a copy is resolved *first* (member, endpoint, device id),
because "one upload per recipient server" cannot be worked out one member at a
time. Then one upload per server, then the copies are encrypted and posted as
before.

**The reference is per member, not per server.** Sharing one blob id across a
server's members is the normal case and the whole point of SRV-18 — but a server
that advertises `max_blob_recipients: 1`, which is also what a server predating
SRV-18 means by saying nothing at all, stores a blob per device. Its members get
an upload and a blob id each. Keying the result by member account id instead of
by server is what lets both work without a special case; the first draft keyed
it by server and simply could not express the second.

**The key is per server, not per picture.** One `encryptBlob` per recipient
server rather than one for the whole fan-out, so the key handed to one server's
members cannot decrypt another server's stored copy. Costs one encryption per
server, which is nothing next to the upload it saves.

**A server that cannot hold the picture does not fail the send.** Partial
delivery is the normal case in a group, so:

- Attachments switched off there, or the picture over that server's
  `max_blob_bytes` → its members get the **caption**, and their `GroupDelivery`
  is marked `attachmentSkipped`. The bubble says "N members could not receive
  the picture" — persisted, because it stays true and a retry cannot mend it:
  those copies count as delivered, so re-delivering the picture would mean
  re-sending the whole message. Sending it again is the user's call.
- The same, but the message has **no caption** → that member's delivery is
  marked *failed* instead. Sending them the empty remainder would put a blank
  bubble in their transcript; failing it means the k-of-N indicator says so and
  a retry addresses them again.

**A partial upload is refused rather than half-used.** If the server stores the
blob for some named recipients and not others (one at their quota), the client
treats the whole upload as failed for that server. It uploads per server, so it
could not act on the difference anyway — and handing the refused members a
reference that will 404 is worse than telling them the picture didn't arrive.

**A retry re-uploads, accepted.** The one-to-one path skips the upload when a
previous attempt already got a blob id and only the POST failed, using the id
stored on the message. A group has no single id to store — one per server, and
the persisted `attachments` entry is a placeholder carrying only metadata — so a
retry after a failed *post* uploads again and the first copy is left for the
server's retention sweep. Persisting per-member blob ids to avoid it would put
key material for N servers into local history to save a rare duplicate upload,
which is the wrong trade.

### What the first real test run on a device changed

Four findings from Andreas' run on a Pixel, 2026-08-04. The third is the one
that mattered.

**A transient upload failure was recorded as a permanent refusal.** Symptom: "1
member could not receive the picture" in a two-person group, twice, then not
reproducible. The cause was not the network hiccup itself but what the code did
with it: every upload failure — a refusal, a timeout, a `5xx`, anything — landed
in the same `catch` and marked that member `attachmentSkipped`. Since a delivery
that counts as sent is never revisited, that verdict could never be undone: one
dropped connection and the picture was stranded for good.

Now `isPermanentBlobRefusal` splits the two. Only the server's own no is
permanent — `404` (blobs off, or an unknown/inactive recipient device) and `413`
(over its size cap); those keep the caption-plus-note behaviour. Everything else
fails that member's *delivery* instead, so **nothing** is sent to them yet and
the outbox retries the whole copy, which then arrives complete. A short delay
beats a permanently mutilated message, and it is the difference between a
message that heals itself and one that needs the user to notice and re-send.

**The transcript had no backdrop and did not start at the bottom.** Both were
simply missing rather than decided: `PatternBackground` and ChatScreen's
post-frame `jumpTo`. The backdrop is applied to the empty state too, or a new
group would change appearance the moment its first message landed.

**A picture began downloading when the chat was opened**, i.e. exactly when the
user was waiting for it. The lazy fetch in `ImageAttachment` stays — it covers
history, a failed attempt, and the background push isolate, which deliberately
writes only the inline thumbnail — but the foreground session now also starts the
download when the message *arrives* (`PollOutcome.attachmentMessageId` →
`_prefetchAttachment`, unawaited so it cannot delay a receipt or a
notification). The id used to come from the app's own receive path; since the
core took that over it is named on the outcome the core returns.

That exposed a second-order problem worth recording: `ensureAttachmentDownloaded`
returns null while an attempt is already in flight, so the widget's own call
became a no-op and its spinner would have spun until the bubble was rebuilt from
scratch. `MediaStore` was already a `ChangeNotifier` and nothing listened to it;
`ImageAttachment` does now, and adopts the file when somebody else's download
settles. It deliberately never starts a download from that listener, so the
notify-on-`markFetching` cannot loop.

**And the listener was necessary but not sufficient** — the next device run
(2026-08-04) hit exactly the failure it was built to prevent: a group picture
stayed a blank bubble, and leaving the chat and re-entering it showed the picture
instantly. Making a download's completion the *only* way the bubble finds out
turned every lost notification into a permanently stranded picture, and there
were four ways to lose one.

**The one that actually caused it: the in-flight map was keyed by message id
alone.** A received message id exists once *per account that received it*, and
each account has its own file — so on a device with several accounts in the same
group (which is how this app gets tested, four accounts in one group) the first
account's download made the picture look already claimed for every other
account. They dutifully waited instead of fetching, and the file they were
waiting for was written into somebody else's directory: when the notification
came there was nothing to adopt, and nothing further would ever notify. The key
is now the same three ids the file is derived from (`accountId/chatId/messageId`)
— the claim and the thing claimed finally have the same identity.

The device evidence is worth keeping, because the file mtimes told the whole
story before any code was read. One picture, four accounts, all on one phone:
the sender wrote its copy at 17:16:37, all three receivers got their inline
thumbnail at 17:16:43, and their full files landed at 17:16:43, 17:16:52 and
**17:17:54** — the last one only after the app was restarted, which is what
cleared the in-memory claim. Serialised downloads with a minute-long tail, from
a map that should have had four independent entries and had one.

Sobering detail: fixing the store race below made this *worse*, not better. With
the stores accidentally split, each account sometimes got its own in-flight map,
which is exactly the isolation the key was missing — so the bug went from
intermittent to reproducible on the first open. A fix that makes a latent bug
deterministic is doing its job; it just has to be read that way.

The other three:

* `MediaStore.instance()` cached the store, not the future resolving it, so
  concurrent first callers each built one. Finding the documents directory is a
  platform-channel round trip, and a notification cold-starting the app makes
  three calls into that window at once (the startup orphan sweep, the arriving
  picture's prefetch, the bubble drawing it). The paths still agreed — every one
  is derived from ids — so the file was written and would have been found; only
  the in-flight map and its listeners were split, which is precisely the state
  where nobody hears anything. The future is what's cached now, and a rejected
  one is not kept, so a transient failure stays transient.
* `ImageAttachment` attached its listener before stat-ing the files but recorded
  the store only afterwards, in `setState`, and the callback needs the store to
  know what to adopt — so a notification landing in between was dropped, and
  nothing notifies twice. It also re-checks the disk in `didUpdateWidget` now:
  the file is the truth, the session already notifies after a finished prefetch,
  and that makes a lost notify recoverable rather than fatal.
* The group receive path never wrote the inline preview thumbnail at all — only
  the one-to-one path called `_writeAttachmentThumbs`. That is *why* the bubble
  read as empty rather than as a picture arriving: with no thumbnail the
  placeholder is `surfaceContainerHighest`, which is exactly the received
  bubble's own colour. It writes them now, keyed by group id like every other
  path that takes a `MediaStore` chat id.

Two lessons, recorded because both will recur:

* A derived cache (the files) may be authoritative, but only if something still
  re-reads it. An event is an optimization on top of that, never the sole path.
* **A claim must be keyed by what it claims.** A message id identifies a message,
  not a *file*, and the moment several accounts share a device every id-keyed
  side table has to be re-read with that in mind.

**The spinner looked square.** It was a fixed 28px inside a clip whose size
follows the picture's aspect ratio, so in a short or narrow bubble it filled the
rounded corners. Sized from the box now (35% of the shorter side, 14–28px, stroke
scaled with it).

### The one thing that did not get built

freizone-server's SRV-18 decided: encode once at the normal target size, and
re-encode **only** for a server whose `max_blob_bytes` is smaller, rather than
letting one frugal server set the quality for the whole group.

The re-encode half is not in this build, and not for want of trying: `dart:ui`
can only encode PNG (which for a photo is *larger*, not smaller), and
`image_picker` does the downscale natively at pick time, when the group's
servers are not yet known. Producing a smaller JPEG at send time needs a Dart
JPEG encoder — a new dependency, which `pubspec.yaml` deliberately avoids for
exactly this ("so attachment compression needs no second package").

So a server whose limit is below our ~1600px/q80 rendition is treated exactly
like one with attachments switched off: its members get the caption and are
counted in the bubble's note. What was **not** done is shrink the picture for
everybody, which is the one option that decision explicitly ruled out. In
practice this needs an operator who set `FREIZONE_MAX_BLOB_BYTES` below roughly
a megabyte (the default is 8 MiB), so it is rare rather than theoretical. If it
ever bites, the fix is the `image` package plus a `compute` isolate for the
re-encode, and the per-server structure to hang it on is already here.

## Receiving

- **Simultaneous session establishment. Done 2026-08-03**, and it turned up a
  contradiction in the protocol text rather than just a missing implementation:
  a `prekey` block over an existing session is *ambiguous*, and the rule
  written for groups would have broken the re-key it shares a shape with.
  A deliberate re-key (`v: 3`) is now adopted unconditionally, since the
  session the tie-break would keep is one the peer can no longer read;
  everything else is treated as a race and settled on the lower account id,
  with the losing session kept in `AppState.inboundSessions` for reading.
  PROTOCOL §5 says so now, and the residual gap — a re-key riding an ordinary
  message, which the spec permits — is tracked as SRV-17.
  A joining member reaches for every existing member at once and they reach
  back, so most new pairs in a group start with each side holding its own X3DH
  initiator session and neither able to read the other's. In a 1:1 chat
  somebody speaks first and this effectively never happens, which is why
  `AppSession._handleIncoming` only builds a responder session when there is no
  session at all. PROTOCOL §5 now specifies the rule: the lower `account_id`'s
  session wins, and the loser is kept **for reading only** — without that,
  every message sent before the two converge is stranded undecryptable. This
  found `cmd/devclient` first; the app needs the same, and it is the one item
  here that is a correctness requirement rather than a feature.
- `MessageContent.decode` must accept a **set** of known versions instead of
  comparing against `currentVersion`. Today `v: 4` would render as "newer app
  feature" in our own build. **Done 2026-08-02**, along with the rest of the
  wire layer: `MessageContent` carries both versions rather than a second class
  duplicating its fields, since `v: 4` *is* `v: 1`'s shape plus `group_id` and
  `state_hash` — the presence of a group id is what selects the version, and a
  one-to-one message stays byte-identical. `v: 5` is `GroupControl`, following
  the `RekeySignal` pattern of an `encode`/`tryDecode` pair that declines
  anything that is not its own shape, so the receive path can try each decoder
  in turn. Events inside it stay opaque: they are signed objects only the core
  reads, and a malformed one costs itself rather than the envelope.
- **Control envelopes arrive out of order.** An `events` envelope routinely
  overtakes the `snapshot` carrying the genesis it depends on, so events that
  are not admissible *yet* go into a small bounded hold buffer and are retried
  whenever new facts arrive. Events rejected for a reason no later fact can
  change — a bad signature, another group's id — are dropped.

**Shipped 2026-08-03**, and where the group receive path *lives* was forced by
something easy to miss: `processIncomingMessage` advances the ratchet and marks
the envelope processed **before** it looks at the payload, and both are
irreversible. So whoever decrypts a group envelope has to act on it, or the
facts inside are gone for good — including the background push isolate, which
decrypts and has no `AppSession`. Handling group envelopes there and handing
them up to be dealt with later would have silently lost every membership change
that arrived while the app was closed.

So `group_receive.dart` holds plain functions over `AppState`, reachable
without a session, and the hold buffer is `AppState.pendingGroupEvents` —
persisted for the same reason: the snapshot that unblocks a held event may be a
long way behind, and the envelope it came in cannot be replayed.

The one thing that stays with `AppSession` is *sending*: answering a
`sync_request`, or a `state_hash` mismatch, needs somewhere to send from. Its
cached folded view is also what goes stale when the isolate-safe half writes
the file, so a group envelope makes it re-read that group from disk.

A group message whose group is not known yet still gets a transcript rather
than being dropped — same reason again: the ratchet has moved past it, so there
is no second chance. It shows as an unnamed group until the facts catch up.
- `v: 4` → a group message: resolve the group, append to its transcript,
  compare `state_hash`.
- `v: 5` → group control: applied via `GroupApplyEvents`, **never stored and
  never notified**, but still acknowledged and deleted from the queue — the same
  contract `v: 3` re-key signals already follow.
- **`state_hash` mismatch** → send our full snapshot, at most once per distinct
  foreign hash, so two permanently divergent peers cannot ping-pong.
- **A group message from an account we do not consider a member** is held in a
  small bounded buffer with a TTL and re-evaluated after the snapshot exchange,
  rather than dropped — that is the normal state of affairs for a member whose
  join we have not seen yet.
- The push wake path is unchanged: a wake means "sync", exactly as today.

## UI

Three properties of the existing UI decide most of this before taste enters:

- **The horizontal swipe axis is taken.** `chat_list_screen.dart`'s body is a
  `PageView.builder` where a swipe switches *accounts*. A "Chats | Groups"
  `TabBar` is exactly the gesture users would try there, so tabs are out.
- **The account switcher is already `AppBar.bottom`.** A second strip beneath it
  would compete for the same mental slot ("which account" vs. "which kind of
  chat") and make the title area three layers deep.
- **The bubble already has the slot a sender name needs**: the reply quote
  renders its author bold at 12 px, left-aligned, inside the bubble.

### Chat list: one list, no second surface

`_buildConversationTile` is nearly generic already, and a group row is the same
tile:

- **Avatar** — `avatarColorFor(groupId)` works unchanged, since a group id is
  also a 21-character bech32m string, so a group gets a deterministic colour for
  free. Only `PeerAvatarLabel` needs a group case (initials of the name instead
  of an id fragment).
- **Prefix icon** — `Icons.group` in the exact slot that holds the
  `federationLocked` padlock today.
- **Preview** — `lastMessagePreview` prefixes the author in a group:
  `"Clara: see you tomorrow"`.

Groups and 1:1 chats share one list, sorted by `lastActivityAt`. The reason is
not effort: there should be exactly one place that answers "what is new", and
`hasAnyUnread` already aggregates across everything for the switcher badge.

**Filter chips** (All / Unread / Groups) sit at the top of the list *body*, not
in the AppBar — a third permanent bar under the title and the switcher strip
would cost too much vertical space. They are a filter, not a navigation level,
so they introduce no swipe conflict.

### Bubbles: the author line

First child of the bubble's `Column`, only when `!mine` **and** the target is a
group:

```dart
if (senderLabel != null)
  Align(                       // the Column is CrossAxisAlignment.end
    alignment: Alignment.centerLeft,
    child: Text(senderLabel,
      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12,
                       color: senderColor)),
  ),
```

- The surrounding `Column` is `CrossAxisAlignment.end`, so the label must align
  itself explicitly.
- **Colour comes from `avatarColorFor(accountId)`** — the same function the
  avatar uses, so a name in the transcript and a face in the member list are
  visibly the same person rather than two unrelated colours.
- Only the first of a run of consecutive messages from one author shows the
  label. That is a decision for the list builder, not the bubble.
- **`peerTitle` in a reply quote must become the quoted message's author**, not
  the conversation partner. In a 1:1 chat those are the same; in a group they
  are not.

### Send state: one checkmark, details on tap

A group send is no longer `sent` or `failed` but "k of N delivered". The bubble
keeps its existing status slot: a clock while any recipient is outstanding, the
familiar checkmarks once all have been accepted, a warning triangle when some
failed for good. **Tapping it opens a delivery sheet** listing delivered /
pending / failed recipients, and a retry there re-sends **only the failed
recipients**, never the whole fan-out. A permanent "7/20" counter in every
bubble was rejected: it is a number nobody cares about five minutes later.

**The sheet, shipped 2026-08-04.** One thing had been glossed over above: a
recipient's row is not one state but the meeting of two independent ones.
`GroupDelivery.state` is what that recipient's *server* did with our copy;
the receipt watermarks are what the *recipient* confirmed. The server's answer
is consulted first, and only its "accepted" leaves anything for a receipt to
add — so a failed copy can never be talked into looking confirmed by a stale
watermark from an earlier message, and `sent` exists as a stage distinct from
`received`: a copy queued on somebody's server until their phone next connects
is not a copy they have, and saying otherwise is the one lie a delivery list
must not tell. That derivation is `GroupConversation.stageFor`, next to the
counts it shares its comparison with, rather than a `switch` inside the widget.

Rows sort worst first and then by account id — whoever it failed for is at the
top, and the order cannot reshuffle under a tap (APP-10's rule for the admin
list). Retry appears only when something actually failed, and is labelled for
what it will *not* do: the copies that arrived are never re-sent, so no member
receives the message twice. The sheet re-reads its message from the session on
every rebuild rather than capturing it, because the fan-out mutates deliveries
in place and a receipt arriving while it is open is exactly what it is open for.
A message nobody was owed a copy of — a group whose other members are all
pending invitees — leaves the indicator inert instead of opening an empty sheet.

**Receipts, and who is entitled to them** (built 2026-08-03). What the bubble
counts is the recipients' own confirmations, not what their servers accepted —
and a confirmation is sent **only to the author of the message it is about**.
Reading is between the reader and the person who wrote it; a group-wide fan-out
of receipts would hand every member a running attendance list of everyone else,
at N times the traffic, and nothing in the protocol makes the other members
parties to it. So `ReceiptSignal` carries an optional `group_id` — the envelope
already says *who* is confirming, but only that says which of the author's
transcripts the watermark belongs to.

Extending `v: 2` rather than minting a version is deliberate: a build that
predates the field reads a group receipt as a one-to-one one and moves that
conversation's watermark slightly early — a tick sooner than it should be, where
a new `v` would land in `MessageContent.decode`'s "newer app feature" path and
leave a visible placeholder message in their transcript instead.

Counted over the message's **own delivery list**, not the current membership:
"3 of 5" means the five that copy was owed to, and somebody who joined afterwards
was never owed one. One watermark per member answers for every message they have
caught up with, so nothing is stored per message.

### First cut, shipped 2026-08-03

The chat list, a group transcript, creating a group, inviting, and accepting.
Enough to use a group; not yet everything described here.

**A separate `GroupChatScreen`, against the earlier plan of one shared
transcript screen.** `ChatScreen` is built end to end around a peer — blocking,
message requests, the secure-session reset, receipt watermarks, the peer
profile — and none of that exists in a group. Threading a `ChatTarget` through
~1450 untested lines would have put the screen people use every day at risk for
a feature nobody has tried yet. The cost is two transcript renderers that can
drift, which is real; merging them is worth doing once the group side has
stopped moving, and is deliberately a decision to revisit rather than a
permanent split.

Still missing from this section: the filter chips, the delivery sheet behind
the send indicator, the group info screen and everything on it (member list,
role actions, invite by QR, leave/dissolve), and system lines in the transcript
for state events. Inviting exists as a session call but has no UI yet.

### Message actions in a group, shipped 2026-08-04 (APP-21)

A group bubble had no long-press gesture at all, so pinning a message and
deleting one from this device — both long available in a one-to-one chat, both
purely local — were unreachable in a group. Reply is the third entry of that
menu and stays with APP-17, which needs a wire field to say *whose* message is
being quoted; pin and delete need nothing on the wire and did not have to wait
for it.

Nothing was missing from the model: `messages` and `pinnedMessageIds` sit on
`ChatTarget`, and a group's are persisted and round-trip-tested already. What
was keyed wrongly was the session API — `deleteMessageLocally`, `pinMessage` and
`unpinMessage` looked their target up in `state.conversations` only, so a group
id would have been a silent no-op. They take a `chatId` now and resolve it
through `AppSession.chatTarget` (`conversations[id] ?? groups[id]`; the two
kinds of id cannot collide, both being generated rather than chosen).

Two pieces became shared code rather than a second copy, which is the drift
warned about above being paid down instead of grown:

- **`PinnedMessageBar`** (`lib/widgets/`), typed on `ChatTarget`, browse index
  and all — a pin with no bar to show it would be a feature nobody can see.
- **`confirmAndDeleteMessage`** (`lib/util/message_actions.dart`), following
  `block_actions.dart`'s established shape, so the one sentence that has to be
  exactly right — "delete" here never means "for everyone" — exists once. Its
  wording moved from "it stays for the other person" to "everyone else keeps
  their copy", true in both a chat and a group.

One consequence worth recording: the group transcript now builds its bubbles
eagerly (`ListView` with children, as `ChatScreen` does) instead of lazily
(`ListView.builder`). `Scrollable.ensureVisible` can only reach a widget that
exists, and the pinned bar's whole purpose is jumping to a message far above the
fold — which a lazily built list cannot do for anything outside its cache
extent. The messages are all in memory either way; if a very long transcript
ever makes this cost real, it costs the same in `ChatScreen` and is fixed in one
place for both.

A deleted message's picture is *not* deleted with it, in a group no more than in
a one-to-one chat: `sweepOrphanedMedia` already collects every file whose
message is gone, groups included, on the next start. (Since the cut it goes the
other way and sooner — `Client.DeleteMessage` takes the line's attachments with
it, so there is nothing left over to collect later.)

### Replying in a group, shipped 2026-08-04 (APP-17)

The menu's third entry, and the wire field it was waiting for. `ReplyPreview`
gained an optional `author` — the quoted message's account id — because `mine`
is a *perspective* bit and among N members "not you" is not an author. It is
absolute, so unlike `mine` it is never flipped for the receiver, and it is sent
**only by the group fan-out**: a one-to-one recipient learns nothing from it, so
that message stays byte-identical to what it was before this item, which is the
same rule `v: 4` follows.

Naming the author is a fallback chain, not a lookup, and its last branch is the
one that mattered to get right:

1. the `author` the sender stated;
2. otherwise the quoted message in **local history** — which covers a reply from
   a build predating the field. This branch has to read `mine` and not only
   `senderAccountId`: that field is null on our own messages, the one author a
   transcript never stores, and reading it as "unknown" would have dropped the
   label from every reply to *my own* message;
3. otherwise `mine` alone, which still separates "you wrote it" from "somebody
   did";
4. otherwise **no author line at all**. A quote that stays silent is the honest
   rendering; a guess among N members would be a confidently wrong name against
   a real person's words.

It lives in `util/quoted_author.dart` as a pure function rather than a getter on
the bubble, for the same reason `group_system_lines.dart` is pure: the failure
mode is silent and misleading, so it is worth testing without a widget.

Both halves of the reply UI became shared widgets — `ReplyQuote` and
`ReplyComposerBar` — continuing what `PinnedMessageBar` started above rather
than growing the drift a second time. One deliberate divergence from the plan:
the author line uses `avatarColorFor` as intended, **except inside one's own
bubble**, where the background is the theme's primary. The avatar palette is
curated for contrast against white, not against an arbitrary accent, so a
palette colour there has no readability guarantee — and one's own bubble is the
one place the transcript around it already says who is speaking.

### Group info screen

Server administration lives behind the AppBar menu because it is server-wide and
spans many accounts. Group moderation is the opposite — it is always *about one
member* — so it belongs where the members are listed.

`GroupInfoScreen`, the group counterpart to `peer_profile_screen.dart`, opens by
**tapping the AppBar title** in the chat, the standard gesture and currently
unbound:

- Name and topic, editable from moderator upwards.
- Member list with role badges, reusing `role_icon.dart` at the switcher's
  established size (white circle radius 12, icon 16) so "admin" looks the same
  everywhere in the app.
- **Role actions live in a member row's long-press menu**, the same pattern
  `_showChatOptions` uses for chat rows, gated by the caller's own group role
  exactly as `_canInvite` gates by `session.myRole`. Moderator management appears
  **only** for the founder.
- Invite, via contact picker or a `freizone://group` QR.
- "Leave group" at the bottom — replaced by "Dissolve group" for the founder,
  who cannot leave.

### Everything else

- An unaccepted invitation renders like the existing message-request state.
- **Join-time disclosure notice**: everyone in a group learns everyone else's
  address, forced by pairwise fan-out. The UI says so rather than letting it be
  discovered.
- State events render as centered system lines, reusing
  `StoredMessageKind.systemInfo`.
- A late-arriving revocation can retroactively undo an action (a removed member
  returns). That gets its own system line rather than letting the member list
  change silently.
- Above ~50 members, adding another warns.

### Plumbing this exposes

- `AppSession.ensureAttachmentDownloaded` and `_deleteConversationMedia` are
  keyed on `peerAccountId` and have to move to the chat target.
- `_deliveryStatusFor` becomes per-recipient aggregation instead of a single
  watermark comparison.
- `MessageContent.decode` accepting a version *set* (see "Receiving") is what
  keeps our own build from rendering `v: 4` as "newer app feature".

## Testing

- **Go (`pkg/group`)**: fold determinism regardless of event order, mutual
  concurrent removal, a late revocation invalidating an act, snapshot merge
  idempotency, rejection of every unauthorized rank combination.
- **`cmd/devclient`**: a full group across the two local Docker instances,
  including one federated member — the reference path, before any UI exists.
- **Dart**: the version-set decode, `ChatTarget` persistence round-trips, the
  per-member receipt watermarks.
- **On device**: the two-instance setup from `docker-compose.local.yml`.

## Phases

1. **`ChatTarget` refactor — done 2026-08-02**, including moving the media path
   off `peerAccountId`. See the data-model section above.
2. **APP-08 step 2: the durable outbox — done 2026-08-02.** The 1:1 half. The
   per-recipient item a group fan-out needs comes with the send path in phase 5.
3. **`pkg/group` + the four FFI exports + Dart bindings — done 2026-08-02.**
   `native/group.go`, cgo-free like the rest of the logic so it tests on the
   host; the exports verified present in the cross-compiled `.so` for both
   ABIs.
4. **Group state store and persistence — done 2026-08-02**, still no UI.
   `GroupConversation`, `GroupStateStore`, `AppState.groups`, and the local
   operations on `AppSession` (create, sign, apply, delete).
5. Send/receive path, fan-out, batch, receipts. The **wire layer is done**
   (2026-08-02): `v: 4` and `v: 5`, encode and decode, fully tested. What
   remains is the plumbing on either side of it.

   The **peer endpoint is extracted** (2026-08-02): `PeerEndpoint` holds the
   account id, home server and resolved device, `Conversation` owns one and
   forwards its old field names to it, and the send core
   (`_encryptAndSend`, `_getOrCreateCryptoSession`, the federation guard) takes
   an endpoint rather than a conversation. A fan-out can now reach a member
   without inventing a one-to-one conversation to litter the chat list with —
   and reaches them over the very same ratchet a one-to-one chat would use,
   since sessions are keyed by account id either way.
6. UI.
7. A federated group across both local instances, end to end.

## Known gaps

Both established by testing on 2026-08-03, both accepted for now, both recorded
because the behaviour is defensible but *not* obvious.

- **Blocking is one-directional inside a group.** A blocked member's group
  messages are decrypted (the ratchet and the queue have to stay clean) and then
  dropped, exactly as their direct messages are — so they are invisible here,
  including the replies other members write to them, which leaves visible holes
  in a conversation. Their *membership facts* are still applied: blocking a person
  must not freeze this device's view of who is in the group. And our own messages
  still go to them — a group message is one copy per member, and withholding one
  copy would silently give that member a different transcript from everyone
  else's while telling nobody. The alternative, dropping them from our fan-out,
  trades an invisible reader for an invisible gap in their history; neither is
  obviously right, so the simpler one stands.
- **A deleted account keeps its member row.** Nothing in a group's facts can say
  "this account ceased to exist", and no member can prove it — so when an admin
  deletes a user, every other member keeps them listed. Their messages simply
  stop; sends to them fail permanently and visibly (the k-of-N indicator, and one
  line in the error banner). A snapshot debt against them is dropped rather than
  retried forever once their server answers `404`
  (`AppSession._payGroupSnapshotDebts`), so the failure is stated once instead of
  on every resume. The only thing that actually resolves it is a moderator
  removing the member, which is a signed fact like any other.

## Out of scope

- **Broadcast** — SRV-16.
- **Group history on a newly linked device** — APP-02. A new device gets current
  *state* from any peer's snapshot, not past messages.
- **Group history for a member who joins later** — decided 2026-08-03: it is
  never forwarded. A new member gets the fact set and nothing that was said
  before they accepted.

  Not a simplification we might revisit: there is no group copy of a transcript
  to forward. Pairwise fan-out means every message exists only as one copy per
  recipient, encrypted for that recipient's ratchet, so a backfill would be
  member X re-sending Y's and Z's words on X's own session — signed by X,
  attributed to Y. What is authenticated hearsay in a chat log is exactly what a
  signature is supposed to prevent, and it would put re-publishing other
  people's messages in the hands of whoever happens to be online when somebody
  joins.

  It also runs directly against the rule that a copy goes only to members who
  have *accepted*: an invitee is deliberately kept out of group traffic while
  their invitation is open, and a backfill on `join_accept` would hand them
  precisely what that rule withheld, retroactively.

  Consequences accepted: a message sent while an invitation is still open
  reaches nobody but the sender's own screen (hence the "Nobody has accepted
  yet" hint next to its checkmarks), and joining shows an empty transcript,
  which the join dialog says up front.
- **Group avatars.** A blob lives on the *recipient's* server, so a group picture
  would be one upload per member and a re-upload for every join. Name and topic
  only in v1.
