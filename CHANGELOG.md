# Changelog

User-facing changes to the Freizone Android app, newest first. Each entry
covers everything since the previous one and is written to be usable
as-is (or lightly trimmed) for a Play Store / App Store release listing.
Internal/roadmap reference codes in parentheses, e.g. `(SRV-03)`, point back
to the fuller technical writeup in `docs/ROADMAP.md` (this repo) and
`freizone-server/docs/ROADMAP.md`.

## 0.12.7+16 — 2026-08-01

### Fixed
- **A chat that stopped being readable now repairs itself.** If the encryption
  between you and one contact ever fell out of step, their messages silently
  stopped arriving and the only way back was to find "Reset secure session" in
  their profile — and even then, nothing happened until you sent them
  something. Freizone now notices on its own and re-establishes the encrypted
  session in the background. Both sides need this version for it to work, and
  messages that were already stuck undelivered are lost — but the conversation
  keeps working from there on. (SRV-03)
- **"Reset secure session" now works on its own.** Previously it only took
  effect once you sent the next message, because your contact had no way of
  hearing about it before that. It now tells them right away.

## 0.12.6+15 — 2026-08-01

### Fixed
- **Notifications no longer stop arriving after a long time away.** When the
  push service handed out a new address for this device while Freizone was
  closed, the change was lost — the server kept sending to the old one, gave
  up on it, and no notifications arrived again until you happened to open the
  app by hand. Freizone now picks the new address up and tells your server
  about it even while closed. (APP-12)

### Added
- A push status line in Settings → Push delivery: which service is actually
  in use (useful when the choice is left on automatic) and how many of your
  accounts are registered for notifications, with a tap through to the details
  per account and a "Re-register now" button.

## 0.12.5+14 — 2026-08-02

### Fixed
- When sharing into Freizone from another app, the account sections on the
  "Send to…" picker now show your full address instead of just the server
  name, so two accounts on the same server are no longer shown identically.
- Fixed the on-screen keyboard occasionally leaving its space reserved on
  screen after leaving and returning to the app, even though the keyboard
  itself was gone.

## 0.12.4+13 — 2026-08-01

### Added
- **Tappable links.** Web addresses, `www.` addresses, and email addresses in
  a message are now underlined and tappable — opening asks first, showing
  where it actually goes, since the sender of a message isn't always someone
  you already trust. A Freizone address quoted in a message (`id*server`) is
  tappable too and offers to start a chat with that person, without ever
  contacting a server on its own. (APP-14)
- **Receive shares from other apps.** Freizone now appears in Android's share
  sheet for text and pictures — pick a chat afterwards, and the shared
  content lands in that chat's composer (a picture downscaled exactly like
  one picked from the gallery), with nothing sent until you press send. An
  optional Settings switch, off by default, additionally offers your recent
  chats as individual targets right in the share sheet itself. (APP-15)

### Changed
- **Shorter invite codes.** An invite code is now a short, easy-to-read code
  like `ABCD-EFGH-JKMN` instead of a long string of hex characters — easy to
  read aloud or copy onto paper, and forgiving to type back in (case doesn't
  matter, and the dashes are optional). Codes now expire after two weeks by
  default, shown next to the code when you generate one. (SRV-12)
- The invite/address QR card now follows dark mode properly — the background
  and its icons used to stay locked to a light appearance, making the address
  underneath hard to read. (APP-04)
- Updated the privacy policy to cover pictures shared into Freizone from
  other apps, and the new optional share-shortcuts feature above.

## 0.12.3+12 — 2026-07-30

### Changed
- **Add a caption to a picture you're sending.** Choosing a photo no longer
  sends it straight away. It now appears as a small preview above the input
  field — with an X to remove it again — so you can type a caption first and
  send both together. Picking the photo before writing anything works just as
  well as the other way round. (APP-04)
- **You can see that your message is on its way.** A message now appears in
  the conversation the moment you send it, marked with a clock while it's
  still going out, and the input field clears right away instead of looking
  stuck on a slow connection. If a message can't be sent it stays visible
  with a "Tap to retry" button rather than quietly disappearing, and you can
  keep typing the next one while the previous is still in flight. Note that
  an unsent message is not kept if you close the app. (APP-08)
- Replying to a picture, and pinning one, now shows a small preview of that
  picture instead of an empty line. (APP-04)

## 0.12.2+11 — 2026-07-30

### Changed
- Freizone now checks whether the person you're writing to can actually
  receive pictures before offering to send one. Not every server stores
  images, and servers can set their own size limits — so in a chat where
  pictures aren't possible the image button simply isn't shown, and a
  picture that's too large for the other side is refused right away,
  telling you the actual limit, instead of failing mid-send. (APP-04)

## 0.12.1+10 — 2026-07-30

### Fixed
- **Sending a picture works.** Choosing a photo from the gallery did
  nothing at all: the picker closed and the chat stayed empty, with no
  error to explain it. Pictures now send as intended, and a picture you
  sent appears in the conversation right away instead of occasionally
  showing a "tap to retry" placeholder. (APP-04)
- Received pictures no longer take up space on your server after they
  arrive. Once a picture is safely on your device it is removed from the
  server, so your storage allowance isn't slowly used up by images you
  already have. (APP-04, SRV-07)

## 0.12.0+9 — 2026-07-29

### Added
- **Send pictures.** Tap the image button in a chat to pick a photo from
  your gallery and send it, with an optional caption. Pictures are
  compressed automatically before sending, so they arrive quickly without
  eating your data. Tap a received picture to view it full-screen and zoom
  in. Like everything else in Freizone, images are end-to-end encrypted —
  the server stores them without ever being able to see them. (APP-04)

## 0.11.8+8 — 2026-07-28

### Fixed
- Some conversations could permanently stop receiving new messages after a
  connection hiccup, showing no error but never decrypting anything from
  that contact again. Message delivery is now resilient to the redelivery,
  timing, and race conditions that caused this, so a conversation should no
  longer break like this in the first place. (SRV-03)
- Push notifications delivered via Firebase (FCM) now name the account
  they're for, matching what UnifiedPush notifications already showed.

### Added
- New **Send with Enter** option (Settings → Chat): press Enter to send a
  message instead of starting a new line. Off by default. With a hardware
  keyboard, Shift+Enter still inserts a line break either way.

### Other
- Assorted reliability and diagnostic-logging improvements, and dependency
  maintenance.

## 1.0.6+6 — 2026-07-27

### Added
- **Account recovery from a seed phrase** (Settings → Recovery phrase to
  back up; "Recover an existing account" during setup to restore): losing
  your device no longer means losing your identity. Back up a 24-word
  recovery phrase once, and restore it later — even on a server that
  currently has new registrations closed — to get back your exact same
  address; your other devices on the account are signed out automatically.
  Chat history itself isn't recovered (the server never keeps it), but
  existing conversations re-establish themselves automatically once you're
  back. (APP-01)
- A one-time reminder on the chat list nudges you to back up your recovery
  phrase after creating a new account.
- If several UnifiedPush apps (distributors) are installed, you can now
  choose which one delivers your notifications (Settings → Push delivery).

### Fixed
- **Broken/undecryptable conversations can now be recovered manually:**
  long-press a chat (or use its contact profile) to reset the secure
  session, which quietly re-establishes encryption with that contact.
  (SRV-03)
- The app no longer freezes at startup if one of your accounts' home
  servers is unreachable — every account now connects independently, and
  requests time out instead of hanging indefinitely.
- Reconnecting after the app was backgrounded is now near-instant, and a
  home server that's actually offline is retried with backoff instead of
  hammered.
- The app now releases its live connection while in the background, so
  background push notifications (both Firebase and UnifiedPush) are
  delivered reliably again instead of only arriving once the app is
  reopened.
- You can no longer accidentally start a chat with your own address.
- Clearer error message when trying to recover an account that doesn't (or
  no longer) exist on the given server.
- If your account's home server is gone for good (not just temporarily
  down), you can now remove it from this device instead of it being stuck
  in the account switcher forever.
- Various small polish items (e.g. peer profile screen layout).
