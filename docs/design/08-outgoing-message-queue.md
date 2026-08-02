# Design: Send feedback and the outgoing message queue

Status: **in progress** · Roadmap: [APP-08](../ROADMAP.md)

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

Known limit, by design: a pending or failed message is **session-only** and
never written to disk (filtered in `Conversation.toJson`, covered by tests in
`test/conversation_test.dart`). Retrying needs the picture bytes, which
`AppSession._outgoingAttachments` holds in memory, so a failed bubble restored
after a restart could never actually be sent — it would be a dead end the user
cannot clear. Durability is exactly what step 2 is for.

**Step 2 — a real outbox, worth considering.** A persisted queue would
additionally survive app kill, allow composing while offline, and retry with
backoff. The non-obvious constraint is the Double Ratchet: encryption advances
the session per message, so ciphertext cannot be produced out of order or
re-produced later at will. Either enqueue **ciphertext** (encrypt at enqueue
time, retry = re-POST the identical bytes) — which keeps ratchet order intact
but means a queued item is already committed to one specific session state, so
a `Reset secure session` or a re-key (SRV-03) has to invalidate or re-encrypt
what is still queued — or enqueue **plaintext** and serialize strictly
per peer, encrypting only at the moment of a successful send. The queue also
has to hold the same cross-isolate lock the push isolate uses (SRV-03), or a
background wake and a retry will race the ratchet again. Retries are safe on
the wire (delivery is already at-least-once and the receiver de-duplicates by
message id, SRV-03), so a re-POST cannot produce a duplicate message for the
peer.

No server work: send is a plain authenticated `POST`, and nothing here changes
the protocol.

