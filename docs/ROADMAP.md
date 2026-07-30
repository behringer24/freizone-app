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
the gateway's APNs path (GW-01).

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

**Still open:** (0) clickable links, (1.5) camera capture, saving/sharing
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
Status: planned
On a slow connection or a slow server the send button feels unresponsive: the
user taps, and until the round trip finishes *nothing* visibly happens, so they
cannot tell whether the message went out — and re-tap or retype it.

Today's send path is fully synchronous from the UI's point of view:
`_send()` (`screens/chat_screen.dart`) awaits `session.sendMessage` before it
clears the composer, and `sendMessage` (`state/app_session.dart`) appends the
`StoredMessage` to `convo.messages` only *after* `_encryptAndSend` returns. So
for the whole duration the text stays in the input field, no bubble appears,
and the only feedback is the button going `onPressed: null` — no spinner, no
greyed-out icon. Slow paths that make this visible: resolving the peer's
device/prekey bundle (`_ensurePeerDeviceResolved`, a network call of its own on
a first or re-keyed conversation), and cross-server sends, which post to the
*recipient's* server — an operator we don't control and whose latency we
cannot bound.

**Step 1 — optimistic local send (no queue).** Append the `StoredMessage`
before the network call and give it a per-message delivery state
(`pending` → `sent` → `failed`), rendered in the slot the delivery-receipt
checkmarks already use in `chat_screen.dart`; clear the composer immediately
and restore the text only if the send fails. This alone removes the "did it go
out?" question and is the smaller change — but the message is then only in
memory/local state, and a send that dies with the process is silently lost. To avoid that the user already starts typing the next message, the composer needs to be disabled until the message is > sent and not failed - otherwise we cannot restore the unsent (failed) text in the composer.

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
Status: planned
The Server Admin Users list (`admin_screen.dart`) renders every account from
one unpaginated fetch (`AppSession.adminAccounts` / `listAccounts`) and will
get long. Add an incremental (type-as-you-go) substring search over id/short
id, plus a sort-order control (icon opening a menu) — candidates: id, role,
created date, status, and once SRV-09 lands, pending-message count or
oldest-pending age. Pure client-side filtering/sorting of the
already-fetched list for now; only worth a server-side paginated/search
endpoint if the account count ever makes the full fetch itself slow.

### APP-11 — Admin-side user detail view
Status: planned · Depends on: SRV-08 · Also benefits from: SRV-09
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

### APP-12 — Push reliability after long inactivity / reboot
Status: planned
Push registration today only happens inside `AppSession.init()`
(`app_session.dart:821`, `_registerPush()` → `registerForPush()` in
`push/push_manager.dart`), which only runs when the app's Dart UI code
actually creates a session for an account — i.e. when a user opens the app.
`initPush()` (`main.dart:19`) itself runs on every process start, including
UnifiedPush's background-isolate relaunch for delivering a wake
(`--unifiedpush-bg`) — but that only wires up callbacks, it doesn't
re-register anything.

**Not the mechanism to add: periodic re-registration.** In the mainstream
apps (WhatsApp/Signal/Telegram/Gmail-style), delivery does not depend on the
target app's process being alive at all — Play Services (FCM) or the chosen
distributor (UnifiedPush) hold one system-level, always-on connection
per-device, independent of whether the app itself has been opened recently.
Token/endpoint churn is handled *reactively*: Android delivers `onNewToken`/
`onNewEndpoint` to a manifest-declared receiver/service, the same way an
incoming message wake already reaches this app's background isolate/
`_firebaseBackgroundHandler` — no polling loop needed, and there's no
documented FCM/UnifiedPush behavior where a token simply expires from
inactivity (only from uninstall, cleared app data, or an explicit rotation).
A prior draft of this entry claimed otherwise; that claim doesn't hold up
and is corrected here.

**What is worth doing:**
1. **Audit that the existing reactive callbacks are actually robust in the
   background**, not just in the foreground: `onNewEndpoint`/`onUnregistered`
   (UnifiedPush) and `onTokenRefresh` (FCM, `_onFcmTokenRefresh`) all run
   through `push_manager.dart`'s top-level callbacks, which per the file's own
   header comment must tolerate running in a background isolate with no
   captured app/UI state — worth specifically verifying none of them silently
   depend on something only present in a foreground run.
2. **Add the `BOOT_COMPLETED` receiver that's genuinely missing today**
   (`AndroidManifest.xml` has none) — standard practice in messaging apps,
   primarily to restart the app's own local housekeeping after a reboot
   (Play Services/the distributor typically reconnect on their own regardless)
   and, defensively, to re-run `registerForPush()` for every locally stored
   account once. Doesn't apply to a fresh install with no account yet — there
   is nothing to register until the setup wizard creates one.
3. **Already correct, confirmed while investigating this:**
   freizone-gateway sends FCM with `AndroidConfig{Priority: "high"}`
   (`freizone-gateway/internal/push/fcm.go:47`) — the documented way to keep
   delivery exempt from Android's Doze/App-Standby-Bucket throttling of apps
   the user hasn't engaged with recently, which is a more likely real-world
   cause of "no notifications after a long absence" than token expiry. Note
   this as already handled, not as an open gap.
4. Genuinely undefendable causes, out of scope for app-side work: OEM
   battery/autostart managers (Xiaomi/Huawei/Samsung) killing Play
   Services'/the distributor's own background connection regardless of what
   this app does — mitigated only by user-facing guidance (e.g. a Settings
   hint to exempt the app from battery optimization), not by app code.
