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
- **Attachments in a group are not sent yet.** A picture has to be uploaded
  once per distinct recipient *server*, against that server's own blob
  capability, which is a second concern layered on the fan-out rather than
  part of it. Text first.
- **Receipts go to the author only**, keeping traffic linear.
- **Above ~50 members the client warns.** This is not a protocol limit — see the
  server-side design for why — so it is purely a UI guard.

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
