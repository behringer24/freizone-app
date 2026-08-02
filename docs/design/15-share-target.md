# Design: Receiving shares from other apps

Status: **done** · Roadmap: [APP-15](../ROADMAP.md)


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
