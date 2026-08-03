# Changelog

All notable changes to the Freizone Android app are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each release heading records the Android `versionCode` alongside the
`versionName`, because Google Play orders uploads by the former.

Entries are written to be usable as-is, or lightly trimmed, for a Play Store
release listing — so they describe what changed *for the user*, not how it was
built. Reference codes in parentheses (e.g. `APP-12`, `SRV-03`) point at the item
in [`ROADMAP.md`](ROADMAP.md) or in
[freizone-server's roadmap](https://github.com/behringer24/freizone-server/blob/master/docs/ROADMAP.md),
each of which links the full design document.

## [Unreleased]

## [0.13.0] — 2026-08-03 (versionCode 17)

Groups, made usable: everything between inviting somebody and knowing they got
it. Needs a rebuilt native core (`native/build_android.ps1`).

### Added
- **Group messages show who received and read them.** The checkmarks under your
  own group message now say "Received by 3 of 5" and "Read by all", from the
  recipients' own confirmations rather than from what your server accepted. A
  confirmation goes **only to the person who wrote the message** — who has read
  what stays between the reader and the author, and nobody else in the group is
  told. Needs both sides on this version. (APP-16)
- **Filter chips on the chat list**: All, Unread and Groups, with counts. They
  only appear when there is something to filter. (APP-16)
- **Inviting into a group of 50 or more warns first.** There is no group key and
  no server-side fan-out: every message is encrypted and sent once per member, so
  each additional member costs everyone. Said once, out loud, instead of being
  discovered as slowness. (APP-16)
- **A group send now goes out in one request per server** where the server
  supports it, instead of one per member — a large group on few servers is
  markedly less work for everyone. Discovered per server, so a group spanning an
  older server keeps working, and a failure is still per recipient. (APP-16)
- **A re-established encrypted session now says that it is one.** When Freizone
  has to rebuild the encryption with a contact — after a reset, or automatic
  recovery — the message that carries it states so outright instead of leaving
  the other side to work it out from the content. This closes the one case where
  a recovery could quietly fail to take: two sides rebuilding at the same moment,
  where whoever had the higher address kept a session the other could no longer
  read. Works with older versions in both directions, no setting to change.
  **Needs a rebuilt native core** (`native/build_android.ps1`). (SRV-17)
- **A group's transcript now says what changed.** Who was invited, who joined,
  who left or was removed, who became a moderator or admin, a new name or topic,
  and the group being dissolved — each as a centered line where it happened,
  instead of the member list changing silently behind your back. Everyone sees
  the same lines, whoever made the change. (APP-16)
- **A warning banner on the chat list when something failed to go out.** Until
  now a delivery that quietly failed — a membership change that never reached a
  member, a message that gave up — left no trace anywhere you could see it. The
  banner stays until you dismiss it. A server that is merely unreachable right
  now does *not* raise it: that retries itself and is already shown by the
  account going grey with an offline badge.
- **The join dialog says what you will and won't see.** Joining a group shows
  messages from that point on; anything written before stays with the people who
  were there. That is deliberate and permanent — a group message exists only as
  one copy per recipient, so there is no group history to hand over, and nobody
  can re-send someone else's words under their own name. (APP-16)
- **Invitations can be declined.** Next to "Join group" there is now a
  "Decline", which takes you out of the group's member list for everyone —
  a moderator can otherwise not tell a refusal from an unread invitation — and
  removes the group from your chats. Only someone in the group can invite you
  again after that. (APP-16)

### Fixed
- **Reading a group message no longer marks unrelated direct messages as read.**
  A group message from someone you also have a one-to-one chat with sent that
  chat a delivery — and, if it happened to be open, a read — confirmation,
  moving its checkmarks on the strength of a message in a completely different
  conversation. Group read receipts don't exist yet; now nothing pretends
  otherwise. (APP-16)
- **Removing a group you are still in now leaves it first.** Removing it while
  the others were still sending left a broken half-state: the group vanished,
  came back the moment somebody wrote, had no name and no member list, its info
  screen was empty, and sending failed with "no group". The dialog now offers
  "Leave and remove" (or "Decline and remove" for an invitation you never
  answered) and does both in one step. A founder cannot leave their own group, so
  there it says to dissolve the group first. (APP-16)
- **Being re-invited after a removal notifies you again.** The first version of
  the invitation notification only recognised a group this device had never heard
  of — after a moderator removed you, the group was still known here, so a fresh
  invitation arrived silently. (APP-16)
- **A group whose details haven't arrived yet says so** instead of showing a
  composer that fails, and asks the member who wrote for them, rather than
  waiting for someone to volunteer a snapshot. (APP-16)
- **A group you left or dissolved can be removed.** Both used to leave the group
  sitting in the chat list permanently, with no way to get rid of it, and a
  group whose stored state was damaged was stuck there too. Long-press it in the
  chat list, or use "Remove from this device" in the group info screen. It says
  plainly that a group you are still a member of will come back when somebody
  writes — leaving is a separate, deliberate step. (APP-16)
- **A group you are no longer in says so** instead of offering a composer whose
  send then fails. (APP-16)
- **A member who may be missing group facts gets them with the next message.**
  Previously they were only sent after somebody noticed a mismatch, which needed
  that member to speak first — and a member who is missing facts leaves people out
  of their own sends. (APP-16)
- **A group whose details are missing can now ask a federated member for them.**
  It could only ask a member on your own server or one you had messaged
  one-to-one; the address now comes from the message itself. (APP-16)
- **Groups catch up on their own now.** If a membership change couldn't be
  delivered to someone — their server briefly away, yours without a network —
  it was simply lost: nothing retried it, and nobody could notice, because a
  group only compares states when somebody sends a message. Adding a third
  person could therefore take several messages from everyone before all three
  saw each other. Freizone now remembers who was never told, hands them the
  full state as soon as it can (on reconnect, on resume, and when you open the
  group), and asks one member for theirs when you open a group, in case *you*
  are the one behind. (APP-16)
- **A group message that failed to send is retried automatically**, like a
  one-to-one message has been since 0.12.x — it previously needed a manual
  retry in the group. Only the copies that never arrived are re-sent. (APP-16)
- **Tapping a group notification opens the group**, the same as it always did
  for a one-to-one chat. Group notifications previously only switched to the
  right account and left you on the chat list. Opening a group also clears its
  notification and the launcher badge now, which only one-to-one chats did.
  (APP-16)
- **Inviting someone into a group now accepts their address in any form.** The
  invite field takes the short id, the full dash-grouped one, with or without
  `*server`, and `*local` — everything you can already type when starting a
  one-to-one chat. Previously only the exact 21-character id without dashes
  worked: any other form added the person to the member list while the
  invitation itself failed with "invalid dh identity certificate", left them
  unreachable for group messages, and never told them anything. An address that
  can't be found is now refused outright instead of adding a member nobody can
  deliver to, and inviting someone whose invitation is still outstanding sends
  it to them again instead of complaining. (APP-16)
- **An invitation actually arrives now.** The invited side threw the whole
  invitation away the moment it came in: the group state it merges into is empty
  for a group you have never heard of, and the core refused that empty state
  instead of treating it as "nothing yet". So there was no group, no
  notification, and no way to accept — and since the invitation is only sent
  once, nothing arrived later either. Group messages then never reached that
  person, because nothing is sent to a member who hasn't accepted. **Needs a
  rebuilt native core** (`native/build_android.ps1`), the fix is in the Go core.
  (APP-16)
- **A group invitation now notifies you.** Nothing is sent into a group until
  you accept, so an invitation used to arrive completely silently — the new
  group simply appeared somewhere in the chat list. It now raises a
  notification and shows the group as unread. Tapping a group notification also
  no longer opens a one-to-one chat with whoever sent it. (APP-16)

## [0.12.7] — 2026-08-01 (versionCode 16)

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

## [0.12.6] — 2026-08-01 (versionCode 15)

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

## [0.12.5] — 2026-08-02 (versionCode 14)

### Fixed
- When sharing into Freizone from another app, the account sections on the
  "Send to…" picker now show your full address instead of just the server
  name, so two accounts on the same server are no longer shown identically.
- Fixed the on-screen keyboard occasionally leaving its space reserved on
  screen after leaving and returning to the app, even though the keyboard
  itself was gone.

## [0.12.4] — 2026-08-01 (versionCode 13)

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

## [0.12.3] — 2026-07-30 (versionCode 12)

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

## [0.12.2] — 2026-07-30 (versionCode 11)

### Changed
- Freizone now checks whether the person you're writing to can actually
  receive pictures before offering to send one. Not every server stores
  images, and servers can set their own size limits — so in a chat where
  pictures aren't possible the image button simply isn't shown, and a
  picture that's too large for the other side is refused right away,
  telling you the actual limit, instead of failing mid-send. (APP-04)

## [0.12.1] — 2026-07-30 (versionCode 10)

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

## [0.12.0] — 2026-07-29 (versionCode 9)

### Added
- **Send pictures.** Tap the image button in a chat to pick a photo from
  your gallery and send it, with an optional caption. Pictures are
  compressed automatically before sending, so they arrive quickly without
  eating your data. Tap a received picture to view it full-screen and zoom
  in. Like everything else in Freizone, images are end-to-end encrypted —
  the server stores them without ever being able to see them. (APP-04)

## [0.11.8] — 2026-07-28 (versionCode 8)

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

## [1.0.6] — 2026-07-27 (versionCode 6)

Numbered above 1.0 by accident; the line was renamed down to 0.11.x afterwards,
so this release is *older* than the 0.11.8 entry above it despite the higher
version. `versionCode` is the only monotonic ordering here.

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
