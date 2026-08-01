# Freizone Roadmap — freizone-app

Planned changes whose **essential** work lands in this repo (the Android/Flutter
client). Cross-repo and protocol-level items live in freizone-server's
`docs/ROADMAP.md` (the project core).

Each item has a short **reference code**; the prefix names the owning repo:

- `SRV-` — freizone-server (core)
- `APP-` — freizone-app (this file)
- `GAW-`  — freizone-gateway

A change spanning several repos is listed **once**, in the repo where the
essential work happens; its entry names the other repos it touches.

Status values: `planned` · `in progress` · `done` · `deferred`.

## Planned

### APP-01 — Recovery seed phrase
Status: done · Depends on: SRV-06 · Also affects: shared Go core, freizone-server
Back up the identity **root key** as a recovery seed phrase (~24 words), so
losing the phone without a second device no longer means permanent identity
loss. Because `account_id == hash(root_pubkey)`, restoring the same root key
restores the **same account id and short id** (and the same `id*server`
address) — recovery keeps the user's existing identity, it does not mint a new
one. (A fresh re-registration without the seed would, by contrast, produce a
new id.)

Scope decision: the seed carries the **root key only** (not the per-device
key). Recovery therefore generates a *new* device keypair, signs its device
cert with the restored root key, and registers it — which needs a
root-key-authenticated recovery endpoint on the server (**SRV-06**), since
today adding a device requires an *existing* active device's signature and
re-registering an existing account is rejected (`409 account_exists`). So this
is **not** purely client-side.

The user also needs their **home-server address** (the account id doesn't
encode it), and must understand that **chat history is not recovered** — the
server keeps no plaintext/history by design (history is separate: APP-05 backup
/ APP-02 transfer). After recovery, existing conversations re-establish their
ratchet sessions via SRV-03 (each peer's old session still points at the lost
device until it re-keys).

**Shipped 2026-07-26** (server companion SRV-06 also shipped): BIP-39 24-word
phrase, encoded/decoded in the shared Go core (`pkg/mnemonic`, embedded 2048-word
English list) so the 32-byte seed never crosses into Dart. Two new FFI exports
(`RevealRecoveryPhrase`, `RestoreIdentityFromSeed`, plus `RecoveryWordlist` for
offline validation). Backup UI: a "Recovery phrase" entry in the profile screen
→ a warned, `FLAG_SECURE` backup screen with a numbered 24-word grid, copy
(clipboard auto-clears after 60s), QR (`qr_flutter`), and share (`share_plus`);
plus a one-time post-setup nudge on the chat list (dismissible, tracked by an
`AppState.recoveryBackupDone` flag). Restore UI: a "Recover an existing account"
branch in the setup wizard (server + QR-scan or manual 24-word entry) that calls
the SRV-06 endpoint via `ApiClient.recoverAccount` (root-key-signed request).
**Verified end-to-end 2026-07-27** (emulator and real device): create → back
up → wipe/lose the device → restore with the phrase → same account id/short
id, old device revoked server-side, account role (admin/moderator) intact,
messaging heals via SRV-03.

### APP-02 — Multi-device history transfer
Status: planned · Also affects: shared Go core · Depends on: SRV-02
Move existing local chat history onto a newly linked device. Depends on the
multi-device linking channel (SRV-02).

### APP-03 — iOS client
Status: planned · Also affects: freizone-gateway (GAW-01)
No `ios/` directory yet; only Android is built/tested. iOS push delivery needs
the gateway's APNs path (GAW-01).

### APP-04 — Multimedia messaging
Status: in progress · Also affects: freizone-server (SRV-07)
Send media, in priority order: (0) clickable links (1) images from the gallery, (1.5) images from the camera (2) video,
(3) audio, (4) later possibly voice messages.

The "large blobs may need a companion server-side transport" question is
settled: they do, and it shipped as **SRV-07**. Inlining media in a message
was ruled out — the global body cap is 512 KiB (~370 KB after base64), and
since federation is client-direct the limit that applies is the *recipient
operator's*, so inline photos would need every peer operator to raise a
security-relevant limit in lockstep.

**(1) Gallery images shipped 2026-07-29:** pick from the gallery → automatic
downscale/JPEG re-encode (image_picker does both natively, ~1600px at quality
80, no prompt — the behaviour other chat apps have trained people to expect)
→ encrypted with a fresh per-blob key in the shared Go core → uploaded to the
recipient's server → the message carries only the blob reference and that
key, inside its own end-to-end encryption. On receipt a tiny inline preview
thumbnail shows immediately and the bubble reserves the right aspect ratio
from the sender's pixel dimensions (so the transcript never jumps), then the
real picture swaps in once downloaded; tap for a full-screen zoomable view.

No breaking format change was needed: the v1 envelope has reserved an
`attachments` list since it was introduced, so older builds ignore the entry
and still render the caption. The per-blob key is deliberately NOT
ratchet-derived, so pictures stay downloadable after a secure-session reset
(SRV-03). Media files live outside the profile JSON (which is rewritten on
every message) and are removed with their conversation or account, plus an
orphan sweep at startup.

**Still open:** (1.5) camera capture, saving/sharing
received pictures, and (2)-(4) video/audio/voice — video will also want
resumable uploads, which SRV-07 does not do yet.

### APP-05 — Backup
Status: planned
Versioned local data backup, optionally synced per device to iCloud (iOS) /
Google Drive (Android).

### APP-06 — Chat text export
Status: planned
Export a single chat as a `.txt` file (no media): timestamp, name, short
address in parentheses, and the text — shareable via the OS share sheet into
other apps.

### APP-07 — Biometric app lock
Status: planned
Require a biometric unlock when opening the app.

### APP-09 — New-user onboarding guidance
Status: planned
Two distinct empty states a new user hits, neither currently explained:

1. **No account on this device.** `main.dart` already routes here (no
   account → `SetupScreen` instead of the chat list), so the routing itself
   isn't the gap — but `SetupScreen`'s address step (`setup_screen.dart`)
   drops the user straight into a server-address form with no framing of
   what they're about to do. Add a short lead-in explaining that this
   creates (or connects to) an account on a chat server, before the form.
2. **Account exists, zero conversations.** `chat_list_screen.dart`'s empty
   state (`conversations.isEmpty`, ~line 381) already shows "No
   conversations yet / Tap the button below to start one", but doesn't
   point at anything concrete. Make it reference the actual "+" FAB
   (`Icons.chat`, bottom-right, ~line 629) explicitly, e.g. with an arrow
   or by naming its position, so the hint maps to a real control instead of
   a vague "the button below."

### APP-08 — Send feedback / outgoing message queue
Status: in progress (step 1 shipped) · Part of: APP-04 (attachment path)
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

### APP-10 — Admin user-list search & sort
Status: done
The Server Admin Users list (`admin_screen.dart`) renders every account from
one unpaginated fetch (`AppSession.adminAccounts` / `listAccounts`) and will
get long. Add an incremental (type-as-you-go) substring search over id/short
id, plus a sort-order control (icon opening a menu) — candidates: id, role,
created date, status, and once SRV-09 lands, pending-message count or
oldest-pending age. Pure client-side filtering/sorting of the
already-fetched list for now; only worth a server-side paginated/search
endpoint if the account count ever makes the full fetch itself slow.

**Shipped 2026-08-02.** The rules live in `lib/util/admin_list_view.dart` with
tests, not in the screen: what counts as a match and which way each ordering
runs are both easy to get subtly wrong and impossible to spot by looking at a
list.

Search matches the *normalized* id on both sides (`normalizeAccountId`), so the
grouping hyphens the list displays never have to be typed and case never
matters — an id read off a screen, a sticky note or over the phone finds its
account either way. Substring, not prefix, so a fragment copied from the middle
still lands.

Each ordering has one fixed direction rather than an asc/desc toggle, because
for every one of them only one direction answers a real question: oldest
account first (the default, matching what the server already returns), admins
first, blocked first, most queued first, longest-waiting first. Every one breaks
ties by id — without that the list visibly reshuffles between rebuilds whenever
several accounts are equal under the chosen ordering. Accounts with nothing
queued sort *last* under "longest waiting", since they have no age at all and
would otherwise bury the rows that ordering exists to surface. The two SRV-09
orderings are left out of the menu entirely against a server that doesn't
report those figures.

### APP-11 — Admin-side user detail view
Status: done · Depends on: SRV-08 · Also benefits from: SRV-09, SRV-14
Rows in the Server Admin Users list aren't tappable today — only a per-row
overflow menu (set role, block/unblock, delete, `admin_screen.dart`). Make a
row open a detail screen — but **not** `peer_profile_screen.dart` itself,
since its actions don't fit this context: its block toggle is a personal,
single-user block (meaningless for an admin/moderator acting on an arbitrary
account they have no chat with), and "Reset secure session" assumes an
existing ratchet session with that peer, which an admin/moderator generally
doesn't have. Build a similar-but-distinct screen: account details (role,
created date, and once SRV-09 lands, the pending-message/quota signals),
with only **"Block for all" / "Unblock for all"** (SRV-08 wording) and
**"Delete"** as actions.

**Shipped 2026-08-02** as `lib/screens/admin_account_screen.dart`, with two
additions to the plan above.

**Who invited this account** (needs SRV-14, which exposes it). Shown to admins
only, because the server only tells admins — a moderator would otherwise be
left wondering why the row is always empty. Rendered as "Unknown" rather than
"nobody" when absent: the field is equally missing for an account that needed
no invite and for one whose inviter has since been deleted, so claiming the
former would be wrong on any server that has ever removed an account. Tappable,
since "who vouched for this one" is usually the start of a chain — and the
inviter is guaranteed to still exist whenever the field is set, because the
invite row cascades with its creator.

**A chat button** ("Start a chat" / "Open chat", depending on whether one
exists). Explicitly the operator's own, personal act: it goes out from their
account like any other message and the recipient sees nothing marking it as
coming from an admin. Hidden on the operator's own row, since
`startConversation` refuses a self-chat outright and offering it would only
produce an error. Left *enabled* for a blocked account, with a note — the
message queues server-side and arrives if the block is ever lifted, so
disabling it would remove a genuinely useful action, but saying nothing would
make it look delivered.

Rows in the list are now tappable; the overflow menu stays, so the two
most-used actions remain one tap from the list. The screen looks the account up
in `AppSession.adminAccounts` by id on every build rather than holding the
snapshot it was opened with, so a block or unblock is reflected immediately and
a deletion (here or elsewhere) is noticed rather than leaving stale figures on
screen. `AdminScreen` gained a `settings` parameter purely to hand on to
`ChatScreen`.

### APP-12 — Push reliability: FCM token refresh while the app is closed
Status: done · Device verification outstanding

**Shipped 2026-08-01.** `FreizonePushService` (Kotlin) subclasses
firebase_messaging's own service, calls `super.onNewToken` so the foreground
stream is untouched, and starts a throwaway `FlutterEngine` on
`pushTokenRefreshEntrypoint`, which calls `reregisterAllProfiles()`. The engine
is torn down when Dart reports back over `freizone/push_token_refresh`, with a
60s timeout as backstop.

Both flagged traps were real and are handled:

- **The manifest conflict.** Verified in the *merged* manifest, not just in
  source: firebase_messaging's `FlutterFirebaseMessagingService` is gone
  (`tools:node="remove"`), ours carries the `MESSAGING_EVENT` filter at default
  priority, and the SDK's own fallback `FirebaseMessagingService` sits at
  `priority="-500"` — so ours wins deterministically, which is the documented
  Firebase mechanism rather than luck.
- **A missing compile dependency, found by the build.** Subclassing the
  plugin's service needs `FirebaseMessagingService` on *this* module's compile
  classpath; through the plugin it is only a transitive runtime dependency,
  enough to run but not to extend. Added via the Firebase BOM so the version
  can't drift from what the plugin ships.

Also done: the device-wide mechanism resolution is hoisted into
`resolvePushMechanism()` and passed down, so `registerForPush` and
`_onFcmTokenRefresh` no longer re-ask the same question inside a per-account
loop. `AppState` gained a persisted `pushRegisteredAt`/`pushMechanism`, and the
Settings info line plus `PushStatusScreen` are in place.

**Still to verify on a device** (not reproducible on an emulator without
forcing a token rotation): that a real rotation with the app closed actually
reaches the server. `adb shell am broadcast` cannot fake it, since only the FCM
SDK can invoke `onNewToken` — the practical test is to clear Play Services'
FCM state or reinstall, watch logcat for
`[freizone/push] background token-refresh engine started`, then check the push
status screen's timestamp.

Push registration only happens inside `AppSession.init()`
(`_registerPush()` → `registerForPush()` in `push/push_manager.dart`), which
runs when the app's Dart UI creates a session — i.e. when a user opens the
app. `initPush()` (`main.dart`) runs on every process start, including
UnifiedPush's background relaunch, but only wires up callbacks; it registers
nothing.

**Audit done, and it splits cleanly in two.** Verified against the plugin
sources, not assumed:

- **UnifiedPush is fine.** `unifiedpush_android` merges its own
  `UnifiedPushService` (a `PushService` subclass) into the manifest, reacting
  to `PUSH_EVENT` broadcasts, and starts its *own* `FlutterEngine` with
  `listOf("--unifiedpush-bg")`. So `onNewEndpoint`/`onUnregistered` reach Dart
  even with the app fully dead, and `push_manager.dart`'s header comments
  about this are accurate.
- **FCM token refresh is lost while the app is closed.**
  `FlutterFirebaseMessagingService.onNewToken` does exactly one thing:
  `FlutterFirebaseTokenLiveData.getInstance().postToken(token)` — an
  **in-process LiveData**. With no live Flutter engine observing it, the new
  token goes nowhere and is **not persisted**. `firebase_messaging` offers no
  background hook for tokens either: `onBackgroundMessage` exists, an
  equivalent for `onTokenRefresh` does not.

**What that actually costs, stated precisely** — because it is smaller than it
first looks and that shapes the fix. On the next app start, `_registerFcm`
calls `getToken()`, which returns the *current* token and re-registers it. A
missed refresh therefore breaks nothing permanently. The damage is confined to
**the window while the app stays closed**, and that window is the originally
reported symptom: the token rotates, the server keeps the stale one, the
gateway's send comes back `UNREGISTERED`, freizone-server clears the push
target (`dropDeadPushTarget`), and no wake arrives again until the app is
opened by hand — which the user has no reason to do, precisely because nothing
is notifying them.

#### The fix: re-register from a background engine on `onNewToken`
Mirrors the pattern `UnifiedPushService` already proves in this app:

- A Kotlin `FirebaseMessagingService` subclass whose `onNewToken` calls
  `super` (so the foreground `onTokenRefresh` stream keeps working unchanged)
  and then starts a `FlutterEngine` on a dedicated Dart entrypoint.
- **Manifest care needed:** only one service may claim
  `com.google.firebase.MESSAGING_EVENT`. The plugin already declares
  `FlutterFirebaseMessagingService` for it, so ours has to *replace* that
  declaration (`tools:node="remove"` on theirs, or `tools:node="replace"`),
  not sit beside it — two services claiming the same event is undefined and
  exactly the kind of subtle break that would look like "push works on my
  device". Worth verifying in the merged manifest, not just in source.
- Dart side needs almost nothing new: `_onFcmTokenRefresh(newToken)` already
  iterates every stored profile and honours `pushPreference`. The new
  `@pragma('vm:entry-point')` entrypoint can call straight into it.
- Engine lifecycle is the fiddly part: it must stay alive until the Dart work
  finishes and then be torn down, so a small completion channel back to Kotlin
  is needed rather than fire-and-forget.

#### Also in scope: making the push state visible in Settings
Chosen deliberately after this took three attempts to pin down: the next "I
get no notifications" report should be checkable without logcat.

**What is app-wide and what is per-account** — worth stating, because an
earlier draft of this entry got it wrong and over-modelled the UI as a result:

- **The mechanism is app-wide.** `pushPreference` lives in `AppSettings`, not
  in the profile (`AppState` has no push field at all), and in `automatic`
  mode the resolution is device-wide too: `_registerUnifiedPush` decides from
  the installed distributors, and the chosen distributor is persisted by the
  plugin for the whole app. All accounts therefore land on the same mechanism
  in practice. The **FCM token is one per install**, which is exactly why
  `_onFcmTokenRefresh` pushes the *same* token to every account's server.
- **The registration is per-account.** `setPushTarget`/`setPushEndpoint` are
  signed requests against *that* account's own server, and UnifiedPush issues
  a separate endpoint per `instance`. So one account can be registered fine
  while another failed (server unreachable), and that is the part that
  genuinely varies.

So the UI splits along that line rather than repeating everything per account:

- **One info line under the existing radio buttons.** The radios already say
  what the user *chose*, and `_PushDistributorTile` already shows and picks the
  distributor — so the line's job is only to add what neither conveys: for
  `automatic`, which of the two it actually resolved to, plus whether anything
  is registered at all. It carries a `>` into the detail screen.
- **A sub-screen for the per-account registrations**, since "did account B's
  server accept my push endpoint" is a specialist question that does not belong
  in the main Settings flow. One row per account: registered or not, and when
  it last succeeded. Plus a "Re-register now" action, app-wide over all
  sessions — the same "all sessions" rule `_setPushPreference` and the
  distributor tile already follow.

Needs a little persistence: `AppSession.pushRegistration` is in-memory only
today, so the per-account outcome and its timestamp have to live on the
profile to survive a restart.

Worth folding in while here: `automatic` currently re-checks distributor
availability *inside* the per-account loop (in `registerForPush` and again in
`_onFcmTokenRefresh`). Harmless, since the answer is device-wide and identical
every time — but it is precisely what obscures the app-wide/per-account split
above, so hoisting it out is a small clarity win.

#### Considered and rejected: a `BOOT_COMPLETED` receiver
An earlier draft of this entry listed one as work item 2. On inspection its
value does not justify the surface: a reboot does not rotate an FCM token, and
Play Services and the UnifiedPush distributor re-establish their own
connections regardless — so it would only cover a token that rotated *during*
the off period. On top of that a `BroadcastReceiver` gets roughly ten seconds,
which is not a comfortable place to spin up a Flutter engine, so doing it
properly would mean pulling in `androidx.work` as another native dependency.
The `onNewToken` path above covers the realistic case on its own.

#### Confirmed already correct
freizone-gateway sends FCM with `AndroidConfig{Priority: "high"}`
(`freizone-gateway/internal/push/fcm.go`) — the documented way to stay exempt
from Doze and App-Standby-Bucket throttling for apps the user hasn't engaged
with recently. Not a gap.

#### Out of scope
OEM battery and autostart managers (Xiaomi/Huawei/Samsung) killing Play
Services' or the distributor's own background connection, regardless of what
this app does. Mitigable only by user-facing guidance (a Settings hint to
exempt the app from battery optimisation), never by app code — and the status
panel above is what would make such a case visible in the first place.

### APP-13 — Replace the reply quote's camera icon with a real thumbnail
Status: planned · Part of: APP-04
Not to be confused with the two thumbnail spots that **are** done: the
composer's reply preview bar and the pinned-message bar both show the real
picture already. This entry is only about the quote block *inside* a bubble,
which still shows a stand-in icon — see below for why it is the hard one.

A reply to a picture currently shows a small camera icon in the quote block
inside the bubble (`_MessageBubble`, `chat_screen.dart`) rather than the
picture itself. That icon is deliberately an interim stand-in, and it is
**best-effort**: whether the quoted message was a picture is resolved from
local history (`convo.messageById`, see `_buildItems`'s `quotedHasImage`), so
it silently falls back to the plain text-only quote once the original is no
longer stored on this device. The composer's own reply preview bar and the
pinned-message bar *do* show a real thumbnail already — they read it straight
off the referenced `StoredMessage` (`MessageAttachment.thumb`), which the
bubble quote cannot do, because a quote has to render even when the original
is gone.

Making it a real thumbnail means the reply has to *carry* one: add an
optional `thumb` to `ReplyPreview` (`message_content.dart`), alongside the
`text`/`mine` it already snapshots for exactly this reason. Trade-offs:
- **Backward/forward compatible** per SRV-10: the field is additive, and
  `ReplyPreview.fromJson` reads only the keys it knows, so an older client
  ignores it rather than failing.
- **Cost:** roughly 2 KB extra inside every reply to a picture (see
  `maxAttachmentThumbBytes`) — small, but it lands in the message queue,
  which is precisely what SRV-07 moved attachments *out of*. Worth a
  deliberate decision, not a silent addition; the same cap must be enforced
  on decode, as `MessageAttachment.fromJson` already does, so a peer cannot
  inflate our stored history through this path.
- Would also make the quote correct for a recipient who never had the
  original at all, which the local-history lookup can never cover.

### APP-14 — Clickable links in messages
Status: done · Part of: APP-04 (item 0)
Message text rendered as a flat `Text`, so a URL someone sent had to be
selected and copied by hand. http(s), `www.`, email addresses and Freizone
`id*server` addresses are now tappable.

**Shipped 2026-07-31.** Detection lives in `lib/util/link_detection.dart` as a
pure function (24 unit tests); rendering in `lib/widgets/message_text.dart`,
which falls back to a plain `Text` when there is nothing to link, so ordinary
bubbles keep the widget they had. The confirmation sheet is
`lib/widgets/link_confirm_sheet.dart`, and `_NewChatSheet` moved to
`lib/widgets/new_chat_sheet.dart` (gaining `initialId`) so a tapped address
can pre-fill it from the chat screen.

Verified on the emulator: all four kinds underlined in one message while
`foto.png` stayed plain and a trailing sentence period stayed outside the
link; a URL tap showed the sheet with the host called out and **Open**
actually reached Chrome (which is what the manifest `<queries>` entries buy —
without them that fails silently); an address tap opened the pre-filled
new-chat sheet with no network access and no keyboard; and a long-press
directly on a link still opened the message actions sheet.

**No protocol involvement at all.** The text is already decrypted locally;
detection is a pure rendering step on `StoredMessage.text`. Nothing changes on
the wire, so an older build simply shows the same text unlinked — this is
baseline per SRV-10 and needs no capability check. Implementation is
`Text.rich` with a `TapGestureRecognizer` per link span, replacing the plain
`Text` in `_MessageBubble` (`chat_screen.dart`); the bubble's existing
`GestureDetector(onLongPress:)` keeps the actions sheet, since span
recognizers only claim taps.

Worth stating because it shapes everything below: we linkify **plain text, not
markdown**, so the visible text always *is* the target. `[Your bank](https://evil.example)`
spoofing is structurally impossible here — a good reason not to introduce
markdown later either.

#### What becomes a link
- `http://…` and `https://…`.
- `www.…` — opened as **https**, never http (upgrade, never downgrade).
  Bare domains without `www.` are deliberately *not* matched: "photo.png",
  "z.B", version numbers and sentence ends would all turn into links, and the
  user could no longer see that a scheme was being invented for them.
- Email addresses, opened via `mailto:`. Detected in bare form
  (`someone@example.org`) since nobody types `mailto:` in a chat — flagged
  here as the one sub-decision that goes slightly beyond "mailto only";
  easy to drop if unwanted.
- `tel:` is out: on some devices a tap places the call outright.
- **`freizone://` stays plain text.** A tapped
  `freizone://join?server=evil.example&code=…` could otherwise add an account
  on someone else's server with one finger. The QR path is a deliberate
  physical act; a tap on text is not. Today it would fail anyway (no `VIEW`
  intent filter is registered), but this must stay a conscious rule for
  whenever deep links do land.
- Everything else — `javascript:`, `data:`, `file:`, `content:`, and above all
  `intent://`, which on Android can address arbitrary app components — is
  never launched. An **allowlist**, not a blocklist: `url_launcher` hands the
  OS whatever it is given.

#### Freizone addresses (`id*server.tld`) are links too
An address quoted in a message ("schreib mal qh29f*chat.example.org") should
start a chat, without copying it into the new-chat sheet by hand. This is an
**in-app action, not a URL launch** — `url_launcher` is not involved and the
address never leaves the app.

- Detection reuses the existing `parseFreizoneAddress`
  (`lib/util/freizone_address.dart`) rather than a second notion of what an
  address is.
- **A tap performs no network access.** It opens the existing new-chat sheet
  pre-filled with the address; the user presses Start. That matters more than
  it looks: resolving a peer contacts *that peer's server directly* (federation
  is client-direct, PROTOCOL §9), so a tap that resolved immediately would
  hand the user's IP to a server chosen by whoever wrote the message. Landing
  in the pre-filled sheet makes that an explicit choice, and reuses the
  confirmation UI that already exists instead of inventing another one.
- If the address is already a known conversation, jump straight to it — no
  network, nothing to confirm. If it is the user's own account, say so rather
  than starting a chat with oneself.
- Unlike `freizone://join`, this carries no secret and no capability: an
  `id*server` address is already public (resolvable via the server's own
  public `GET /v1/accounts/{id}`), which is why it can be tappable at all
  while `freizone://` stays plain text.

**Detection is heuristic, and that is worth stating.** Dart has no standalone
checksum check: the Bech32m checksum lives in the Go core, and the one FFI
export that touches it (`VerifyAddressID`) verifies an id against a *known
root public key*, which we do not have for an id just found in text. The
common display form is the 5-character short id anyway
(`shortFreizoneAddress`), which carries no checksum at all. So matching rests
on shape: a Bech32m-charset id part of at least 5 characters, a `*`, and a
host-shaped remainder. Guard against the silly cases — a minimum id length
keeps "2*3.5" from becoming an address. Adding a `NormalizeAddressID` FFI
export would make the full 21-character form exactly verifiable; noted as
optional hardening, not a prerequisite, since it would not help short ids.

#### Detection details (the part that needs tests)
A pure function in `lib/util/link_detection.dart` (text → spans with offsets),
so all of this is unit-testable without a widget:
- Trailing punctuation is trimmed: `.`, `,`, `!`, `?`, `:`, `;`, `"`, `'`, `»`
  and an unbalanced `)`.
- Balanced parentheses inside a URL survive, so
  `…/wiki/Beispiel_(Begriffsklärung)` stays intact.
- A run longer than ~2 KB is left as text rather than becoming one enormous
  link (a paragraph without spaces should not be "a URL").
- Bidi control characters (U+202A–U+202E, U+2066–U+2069) are stripped from a
  link's rendered text and never trusted anywhere: U+202E can visually reverse
  a URL.

#### Opening a link: always confirmed
A tap opens a bottom sheet rather than the browser directly. In a messenger
where a stranger can send the first message, one extra tap is a fair price
against phishing. The sheet shows:
- the full URL, wrapped and legible;
- the **host**, called out separately — if it contains non-ASCII characters,
  say so and mark them, since `https://аpple.com` (Cyrillic `а`) is
  indistinguishable otherwise. Deliberately *flagging* rather than converting
  to punycode, to avoid a dependency for it;
- a note when the scheme is plain `http` (unencrypted);
- actions: **Open** · **Copy link** · **Cancel**.

Launched with `LaunchMode.externalApplication` — the user's own browser, with
whatever protections they have there. Explicitly not an in-app webview: that
would add a browser surface to a privacy-focused app for no benefit.

#### Link previews: not planned, on purpose
A preview would contact the linked server when the message is *received or
displayed*, handing that server the recipient's IP and the fact and time they
read it — without the user having clicked anything. On a system that
deliberately withholds metadata from its own server, that would be an own
goal. Sender-side previews only move the leak to the sender and inflate the
message. If this is ever wanted, it needs its own entry and its own argument.

#### Work items
- `pubspec.yaml`: add `url_launcher`.
- `AndroidManifest.xml`: extend the existing `<queries>` block with `VIEW`
  intents for `https` and `mailto` — Android 11+ hides other apps otherwise
  and launching silently fails.
- `lib/util/link_detection.dart` + `test/link_detection_test.dart`.
- `lib/widgets/message_text.dart` (renders the spans) and a confirmation
  sheet; link spans underlined **and** coloured, not coloured alone: the
  bubble is `primary` for own messages and `surfaceContainerHighest` for the
  peer's, so one colour cannot carry on both — and underlining is the more
  accessible signal regardless.
- Applied to the bubble body only (including an image caption). Reply quotes,
  the pinned bar and the chat-list preview stay unlinked: they are truncated
  one-liners where a tap target only produces mis-taps.
- Verify on device that a long-press on a link still reaches the bubble's
  actions sheet.

Checked and unaffected: `PRIVACY.md` needs no change. The app itself never
contacts a linked server (no previews), and opening happens in the user's own
browser on their own initiative.

### APP-15 — Receive shares from other apps (Freizone as a share target)
Status: done (both levels) · Also relates to: APP-04 (images), SRV-07 (blob limits)

**Shipped 2026-07-31, both levels.** Implemented with an own platform channel
rather than `receive_sharing_intent`: MainActivity already had one
(`freizone/secure_screen`), so this follows an established pattern, adds no
dependency that has to keep pace with Flutter releases, and keeps the
security-relevant part — reading the sender's `content://` stream — under our
own control.

The native side is deliberately **pull-based**: it parks the share and waits to
be asked, because a share is often a *cold start* where nothing in Dart is
ready to show a picker yet. `onNewIntent` only nudges for the warm case.
Files: `MainActivity.kt`, `lib/util/share_intake.dart`,
`lib/screens/share_target_screen.dart`, `lib/util/share_shortcuts.dart`,
`lib/util/avatar_bitmap.dart`, and `ChatScreen`'s `sharedText`/
`sharedImagePath`.

Verified on the emulator: a cold-start text share opened the picker with all
accounts' chats grouped by server, and choosing one landed in that chat with
the text in the composer; the direct-share row showed three chats with their
real avatars and Freizone badges; tapping one skipped the picker entirely and
staged the shared picture in the composer (`1136×1434 · 292 KB`, removable via
its X), with nothing sent. `dumpsys shortcut` confirmed the published set
carries the share-target category, a `Person`, the long-lived flag and an
accepted icon bitmap.

**A shared picture is normalized exactly like a gallery pick**, and that had
to be added deliberately: `image_picker` downscales and JPEG-re-encodes a
gallery pick (~1600px, quality 80) *before* Dart sees it, so the first version
of this shipped a shared photo at full camera resolution — costing the
recipient quota and bandwidth and running into the receiving server's
`max_blob_bytes` (SRV-07) where a gallery pick never would. It is now brought
to the same size and format in `MainActivity.normalizeImage`, including EXIF
rotation (BitmapFactory ignores orientation, so a portrait photo would
otherwise arrive on its side) and deleting the full-size original from the
cache. Native rather than Dart because `dart:ui` can only encode PNG, which
for a photo is *larger* than the JPEG it started as; the limits are passed in
from Dart so `maxSentImageEdge`/`sentImageQuality` stay the single source of
truth.

**The direct-share row is off by default**, decided once the privacy-policy
wording made the trade-off plain to read: it is the only feature that puts
information about contacts outside the App's private storage, so it is
something to opt into rather than discover. The default also reaches installs
that predate the setting — their stored preferences have no such key, so they
read as off and `syncShareShortcuts` clears whatever an earlier build had
published. Sharing *into* Freizone works either way; without the setting the
target is picked afterwards.

Worth recording, since it cost a debugging detour: a share driven from
`adb shell am start --grant-read-uri-permission` **cannot** be read — the shell
does not own the MediaStore row, so the grant never reaches the app
(`SecurityException: ... has no access to content://media/...`). The code
handled it correctly by dropping the share, but the image path can only really
be tested through a genuine app-to-app share. Sharing Freizone's own invite QR
back into Freizone turned out to be the cleanest way to do that.

The original plan follows.

Freizone can share *out* (`share_plus`, used by the invite/address screens)
but could not receive: it did not appear in Android's share sheet when another
app shares a link or a picture. Two levels, worth keeping apart because the
second one costs something the first does not.

#### Level 1 — appear in the share sheet, pick the target in-app
An `<intent-filter>` for `ACTION_SEND` with `text/plain` and `image/*` puts
the app icon in the share sheet. The share carries **no target**, so the app
opens a picker: which account, then which conversation. Text lands in that
chat's composer (not sent — the user still presses send), an image lands
staged in the composer exactly as a gallery pick does, so a caption can be
added.

Reuses what already exists: `OutgoingAttachment.prepare` for measuring and
thumbnailing, and the staged-attachment composer from APP-04/APP-08.

Details that will bite otherwise:
- **The account choice has to come first, because it decides the size limit.**
  A blob is uploaded to the *recipient's* server, so `blobCapabilityFor`
  (SRV-07) can only be evaluated once the target conversation is known — an
  image that fits for one contact may be refused for another. So: pick target,
  *then* validate, and explain the limit if it does not fit.
- **Cold start.** The intent can arrive with the app not running, so it has to
  be handled in `main.dart` alongside the existing notification-launch path
  (`consumeLaunchNotificationPayload`), and only once `AccountManager` is
  ready — the picker cannot be shown before the accounts are loaded.
- **Do not trust the sender's mime type.** A shared `content://` URI must be
  read through the content resolver and validated as a decodable image;
  `OutgoingAttachment.prepare` already returns null when it is not, so refuse
  on null rather than uploading whatever arrived.
- `ACTION_SEND_MULTIPLE` is deferred: only one attachment per message renders
  today (see APP-13's sibling note in APP-04).
- Needs a plugin or a small platform channel for the incoming intent
  (`receive_sharing_intent` is the usual choice) — outgoing `share_plus` does
  not cover this direction.

#### Level 2 — the direct-share row (individual chats as targets)
Appearing *as a contact* at the top of the share sheet, the way WhatsApp and
Signal do, is a different mechanism: Android **Sharing Shortcuts**
(`ShortcutManagerCompat.pushDynamicShortcut` with `setLongLived(true)`,
`setPerson(...)`, categories matching a `<share-target>` in
`res/xml/shortcuts.xml`). It also solves the ambiguity for free, since a
shortcut can encode both account and conversation in its own intent — the
share arrives already addressed.

There is no usable Flutter plugin for this; it is native Kotlin work.

**And it has a privacy cost that needs a deliberate decision.** Publishing
sharing shortcuts hands each conversation's *label and icon* — contact name
and avatar — to the system shortcut store, where the launcher and the system
share sheet can read them. That is contact metadata leaving the app sandbox on
a system whose whole point is that it does not hand out metadata. Signal makes
this optional for exactly this reason. Options, in increasing order of
exposure: don't publish shortcuts at all (Level 1 only); publish them but
labelled with the short address rather than the alias and with a generic
icon; publish full name and avatar for the WhatsApp-like experience. Whichever
is chosen, it should be a setting the user can turn off, and off should mean
"existing shortcuts are removed", not just "no new ones".

Also worth noting for Level 2: shortcuts have to be kept in sync as
conversations are renamed, blocked or deleted, and they must be cleared on
account deletion — a shortcut outliving its account would leak a name that
should be gone.
