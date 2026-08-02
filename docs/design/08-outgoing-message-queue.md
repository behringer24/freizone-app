# Design: Send feedback and the outgoing message queue

Status: **done** · Roadmap: [APP-08](../ROADMAP.md)

On a slow connection or a slow server the send button felt unresponsive: the
user tapped, and until the round trip finished *nothing* visibly happened, so
they couldn't tell whether the message went out — and re-tapped or retyped it.

The send path used to be fully synchronous from the UI's point of view:
`_send()` (`screens/chat_screen.dart`) awaited `session.sendMessage` before it
cleared the composer, and `sendMessage` (`state/app_session.dart`) appended the
`StoredMessage` to `convo.messages` only *after* `_encryptAndSend` returned. So
for the whole duration the text stayed in the input field, no bubble appeared,
and the only feedback was the button going `onPressed: null` — no spinner, no
greyed-out icon. Slow paths that made this visible: resolving the peer's
device/prekey bundle (`_ensurePeerDeviceResolved`, a network call of its own on
a first or re-keyed conversation), the blob upload for a picture (SRV-07), and
cross-server sends, which post to the *recipient's* server — an operator we
don't control and whose latency we cannot bound.

**Step 1 — optimistic local send (no queue). Shipped 2026-07-30.** The bubble
now joins the transcript *before* any network work, as
`MessageSendState.pending` (`state/conversation.dart`), and
`AppSession.sendMessage` hands the network half to a shared `_deliver` that
resolves it to `sent` or `failed`. Rendered in the same slot the
delivery-receipt checkmarks use: a clock while pending, the checkmarks once
sent, and a tappable "Tap to retry" chip when it failed (`AppSession.retrySend`)
— drawn with `errorContainer` colours rather than bare error red, which would
have had no guaranteed contrast on the bubble's own `primary` fill. The
SnackBar was kept for the *reason* a send failed, since a status icon cannot
say "this server doesn't accept pictures".

Pictures are included: the own-copy local files are written up front so the
pending bubble renders the actual image, and the attachment entry starts as a
placeholder whose `blobId` is filled in once the upload returns one — so a
retry after a failed POST re-uses the blob it already uploaded instead of
leaking a second copy onto the recipient's server.

The composer is deliberately **not** disabled while a send is in flight, and
an earlier note in this entry claiming it had to be is superseded: that
reasoning assumed a failed send would restore its text into the composer
(which is why a half-typed next message would have been in the way). With a
failed bubble that stays put and offers its own retry, nothing needs
restoring, so blocking the input would only undo the responsiveness this item
is about. Overlapping sends are safe — `_encryptAndSend` already serializes
per peer, so the ratchet is never entered twice at once.

Known limit of step 1, since removed: a pending or failed message was
**session-only** and never written to disk, because retrying needs the picture
bytes `AppSession._outgoingAttachments` holds in memory — a failed bubble
restored after a restart would have been a dead end the user could not clear.

**Step 2 — a durable outbox. Shipped 2026-08-02.**

The design question was ciphertext or plaintext in the queue. The Double
Ratchet advances per message, so ciphertext cannot be produced out of order or
re-produced later at will: queueing it keeps ratchet order intact but commits
each item to one specific session state, which a `Reset secure session` or a
re-key (SRV-03) then has to invalidate or re-encrypt. **APP-16 settled it in
favour of plaintext**: a group message is encrypted once per recipient against
N different sessions, and the ciphertext model would commit N copies that a
single re-key invalidates.

That turned out to describe what the code already did. `_deliver` builds the
plaintext and calls `_encryptAndSend` at send time, and `_encryptAndSend`
already serializes per peer through the same lock the push isolate uses. So
step 2 was not a queue to build but a limitation to remove:

- **Unsent messages are persisted**, with their state. `send_state` is omitted
  for a sent message, so existing history stays byte-identical and only the
  exceptional case costs a key. `sendError` is deliberately *not* persisted: a
  reason from a previous run ("this server doesn't accept pictures") may no
  longer be true, and a stale explanation is worse than none.
- **`pending` never survives a restart.** Nothing is in flight in a process
  that no longer exists, so it loads back as `failed` and is retried. Restoring
  it as pending would leave a clock icon waiting on a send no code is running.
- **The picture is read back from disk.** This is what makes the whole thing
  possible, and it needed no new storage: the sender's own copy is already
  written *before* the pending bubble first paints, and its metadata rides in
  the message's own placeholder attachment entry. `_recoverAttachment` rebuilds
  the `OutgoingAttachment` from those two. If the file is genuinely gone the
  send is refused rather than delivering the caption alone, which would quietly
  send something other than what was composed.
- **`flushOutbox` retries** oldest-first, sequentially, per conversation — at
  startup and on the transition back from unreachable, the two moments a send
  that failed for want of a network might now succeed. Bounded at three
  automatic attempts per message per run, because a send can fail for a reason
  retrying never fixes (a peer whose server has federation off, a picture too
  large for it) and an automatic retry on every reconnect would be an endless
  invisible loop. A user's own "tap to retry" is not counted against that
  bound: asking again is a decision, not a loop.

Retries are safe on the wire — delivery is already at-least-once and the
receiver de-duplicates by message id (SRV-03) — so a re-POST cannot produce a
duplicate for the peer.

**The first device test found it inert, and why is worth recording.** Making
the *model* persist unsent messages did nothing, because no code path ever
saved at a moment when a message was unsent: `_deliver` called `saveProfile`
only after a successful send, and `sendMessage` explicitly did not save at all
(the comment there still said an unsent message was session-only). So the outbox
had nothing to retry from.

It was invisible rather than merely inert because of
`_reloadVolatileStateFromDisk`, which replaces `conversations` wholesale with
the disk copy whenever the app is resumed — correct for its own purpose, since
a frozen isolate cannot hold anything newer than disk, but it means a
memory-only message is not just unsaved, it is actively erased on the next
resume. Turning airplane mode off involves leaving and re-entering the app, so
the failed bubble vanished exactly when the user went to make it succeed.

Three saves fix it: at compose, when a retry starts, and when a send fails. The
failure save is best-effort and never masks the original error.

**A queued picture was then lost on the retry**, arriving as text only — found
by the same device test one round later. `MessageAttachment.fromJson` drops any
entry with an empty `blob_id`, which is right for something off the wire (an
attachment with no blob to fetch is malformed, and a broken image is worse than
none) and wrong for our own history, where an empty blob id is exactly what an
outgoing picture looks like before its upload has returned one. Persisting
unsent messages made those entries reachable for the first time, so the guard
started eating them. `fromJson` now takes a `local` flag: our own stored history
tolerates the empty id, the wire path does not.

Two consequences of the persistence fix worth noting together with it. The
placeholder entry is what `_recoverAttachment` rebuilds the upload from, so
losing it cost not just the reference but the mime type and dimensions as well.
And `sweepOrphanedMedia` deletes files no message refers to — before unsent
messages were persisted, a queued photo's own file was swept at the next
startup, so even a correct retry would have found nothing on disk.

**Replies were checked at the same time and were already fine.** `reply_to_id`,
`reply_preview_text` and `reply_preview_mine` are all persisted and read back,
and `_deliver` rebuilds the wire quote from them, flipping `mine` for the
recipient's perspective as it always did. An empty preview text — a reply to a
photo with no caption — is a real value rather than an absent one and survives
as such. Tested now rather than assumed.

**Retries are idempotent now, which they were not.** `_encryptAndSend` minted a
fresh random wire `message_id` per attempt, so a POST that actually arrived but
whose response was lost would be delivered a second time by the retry. A real
message now passes its own stable `StoredMessage` id, and `409 message_exists`
counts as success rather than failure — it says the peer already has it. That
also makes the resume race self-correcting: if a resume replaces an in-flight
message with the disk copy while the original send completes against the
orphaned object, the retry hits the 409 and settles as delivered instead of
sending twice.

**Does the Double Ratchet constraint still bite?** It still holds — it is
designed around, not gone. Encryption happens at the moment of sending, under
the per-peer lock, so there is only ever one encryption in flight per peer and
it happens in send order. That is precisely what choosing plaintext over
ciphertext bought.

What the durable outbox *did* expose is that the ratchet advances before the
POST, and a committed advance for a message nobody received burns a message
number. The peer's ratchet bridges gaps, but only up to a bound
(SRV-03's `too_many_skipped`), and retrying widened the gap every attempt —
made durable, at that, by the new save-on-failure. So a failed POST now rolls
the session back to where it was, and the retry re-encrypts the same message
number. Safe even when the POST secretly succeeded and only its response was
lost, because the retry carries the same wire id and the server answers `409`.

The rollback matters most in a case that had nothing to do with gaps. A
first-contact send creates the session as a side effect, and
`_getOrCreateCryptoSession` returns no `initial` block once a session exists —
so a first message that failed would be retried **without its X3DH prekey
block**, to a peer who has no session and therefore could never decrypt it. The
outbox turned that from a message that quietly vanished into one retried three
times into a black hole. Rolling the session away entirely means the retry
starts a fresh X3DH with a fresh prekey block; it costs one of the peer's
one-time prekeys per attempt, which is a far better trade than a message that
can never arrive.

**Why every send goes through the durable record, not only a backgrounded one.**
The record exists from the moment the user hits send, on every send, connected
or not — there is no separate "queue" object, the transcript is the queue and
`flushOutbox` scans it. Persisting only on backgrounding would miss exactly the
events that lose messages: an OOM kill, a force-stop or a crash gives no
lifecycle callback, and the dangerous window is between hitting send and the
POST returning. The cost is that the profile is rewritten two or three times per
send instead of once — the same write the app already performs for every
received message and every receipt, so a doubling of an existing cost rather
than a new one. It is still the same whole-file rewrite that keeps image bytes
out of the profile and puts group state in its own file (APP-16); moving the
outbox to a small file of its own is the natural next step if that write ever
starts to hurt, and is deliberately not done on speculation.

**Not covered by tests, and worth saying plainly.** The model half is: what
gets persisted, and that a pending message restores as failed. The runtime half
— the flush firing on reconnect, the picture read back from disk, and the three
saves above — is not, because nothing in this suite constructs an `AppSession`
or a `MediaStore`, and building that harness is a larger change than the
feature. That is precisely why the first device test found a feature that had
passed every test and did nothing.

No server work: send is a plain authenticated `POST`, and nothing here changes
the protocol.

