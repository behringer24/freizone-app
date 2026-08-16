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

### Added

* **A chat now tells you when the other person's account no longer exists.**
  Until now a message to an account that had been deleted simply failed, over
  and over, with nothing saying why — and every retry failed the same way. The
  chat now says so once, in the conversation itself, and the message field is
  replaced by a note instead of accepting messages that could never be
  delivered. Everything already in the chat stays readable, and this is only
  ever shown after their server has actually confirmed the account is gone —
  never because it was briefly unreachable (`SRV-29`)

### Fixed

* **Error messages no longer start with a piece of internal jargon.** Failures
  reported by the app's protocol core reached the screen with a `client:`
  prefix in front of the actual sentence

## [0.23.1] — 2026-08-15 (versionCode 29)

Two fixes from an audit rather than a report: a check of everything the
internal rebuild on 2026-08-10 might have left behind. Both are actions that
looked like they worked and then quietly undid themselves.

### Fixed

* **Pinning a message sticks again, and "Delete for me" stays deleted.** Both
  had been quietly undoing themselves since an internal rebuild on 2026-08-10:
  a pin showed until the next message arrived in that chat — or the next app
  start — and then vanished; a message deleted from this device came back the
  same way. Both now take effect where the messages actually live, in every
  kind of chat (`APP-21`)
* **Deleting a single message also removes its picture from this device.**
  Until now the picture's bytes stayed behind where nothing could see or
  reach them — invisible, but not gone, the same gap 0.23.0 closed for
  deleting a whole account (`APP-21`, `SRV-23`)

## [0.23.0] — 2026-08-15 (versionCode 28)

### Added

* **The attachment-storage chart now continues past today**, for a server's own
  admins. One line is what was measured, up to this moment. A dashed line shows
  what is left of it as attachments reach the end of their retention — every
  one of them has a known expiry date, so this is calculated, not estimated, and
  it is the upper bound: a picture is released as soon as its recipient has it,
  which only empties the server faster. A third, dimmed line adds uploads
  continuing at the rate of the last few days, and levels off where storage
  settles — because attachments are kept for a fixed period, storage cannot grow
  without end, and that level is the number worth knowing. Today is marked, so
  it is always clear which part of the chart already happened. Tap or drag
  either forecast line to read both figures for that day (`SRV-25`, `APP-24`)

### Fixed

* **Deleting an account now removes everything it held on this device.** Its
  messages, its pictures, its groups and the encryption keys that belong to it
  all go with it. Until now the app deleted the account's settings file and left
  the rest behind, where nothing could reach it and nothing would ever clean it
  up — invisible, but not gone, on a phone that might be sold, handed on or
  lost. This applies both to deleting an account properly and to removing one
  from this device when its server can no longer be reached (`APP-20`)
* **Clearing and deleting a chat now actually clears and deletes it.** Both had
  stopped taking effect after an internal rebuild on 2026-08-10: the chat
  vanished from the list and came back with its whole history, at the latest the
  next time the app started. The same applies to removing a group you have left
  or that was dissolved — including the one you founded, which you dissolve
  first and can now remove like anybody else. Pictures go with the history they
  belonged to, as they always should have (`APP-19`)
* **Deleting a chat no longer changes what happens if that person writes
  again.** They can always reach you — the chat simply opens again, with their
  new message as its first line. Nothing about deleting a chat has ever been a
  way to stop somebody contacting you; blocking is, and it is unchanged. This
  had been specified both ways internally and is now settled one way (`APP-19`)
* **Saving and sharing a picture from a chat works again.** Press and hold a
  picture in a conversation or a group and the sheet offers "Save to gallery"
  and "Share picture" as it should — both entries had been missing since an
  internal rebuild on 2026-08-10 moved where pictures are stored, and the sheet
  went on looking in the old place and found nothing. The full-screen view's
  buttons were never affected, so that was the only way to get a picture out in
  the meantime (`APP-20`)
* **A message that arrives while you are looking at the chat now counts as
  read.** The sender was told it had been delivered, never that it had been
  read — so their message sat on "Received" indefinitely, and in a group the
  "read by" count could never reach everyone. Reading a chat has always sent
  that confirmation when you *open* it, and a message landing in a chat you
  already had open was never opened again, so nothing ever sent one. Opening
  it again later did not help either. A chat nobody is looking at still
  confirms nothing
* **New messages appear in an open chat again after the connection drops.**
  If the live connection to your server failed once — a restart at the other
  end is enough — it was never re-established for as long as the app kept
  running. Messages still arrived and still raised notifications, but the chat
  in front of you went on showing the old conversation, which made it look as
  though the notification was for a message that never came. Switching away
  from the app and back was the only cure. The connection now comes back on
  its own, and while it is down the app checks for waiting messages once a
  minute rather than waiting quietly

## [0.22.1] — 2026-08-14 (versionCode 27)

### Fixed

* **A picture you have received no longer takes up room on the server for two
  weeks.** Once it is safely on your device, the copy on the server is released
  — which is how it was always meant to work, and how it did until an internal
  rebuild on 2026-08-10 quietly stopped it. Until now every picture stayed in
  your server storage allowance for the full retention window even after
  everyone in the chat had it. In a group, the picture is released only once
  the last member has it, so nobody loses a picture they have not seen yet
  (`SRV-07`, `APP-04`)
* **Housekeeping problems are reported again after a background wake.** Things
  the app tidies up when it reconnects — topping up the keys that let somebody
  start a conversation while your phone is off, settling group facts,
  re-sending confirmations — were being checked and then silently discarded on
  that one path. For an account that is only ever woken by a notification and
  never opened, that was the only place anything would have said so

## [0.22.0] — 2026-08-14 (versionCode 26)

### Added

* **A statistics page for your own server**, for its admins — the chart icon in
  the top bar of Server Admin. It answers "how busy is my server, and is it
  healthy": how many accounts and devices exist, how many attachments are
  stored and how much space they take, how large the database is, how much room
  is left on the disk, how many messages are waiting to be delivered, and
  whether federation is on. Nobody but an admin of that server can see any of
  it (`SRV-25`, `APP-24`)
* **Growth over time, as charts.** Registered accounts and attachment storage
  are drawn as lines, so it is visible whether either is trending toward a
  problem rather than only what today's number is. Tap or drag along a line to
  read an exact point — the reading stays on screen after you let go — and page
  the shown period with the arrows underneath. The server records these figures
  four times a day and keeps two years of them, so the charts fill in over the
  first days on a newly updated server

## [0.21.0] — 2026-08-12 (versionCode 25)

**Please read before updating.** The app no longer carries its own copy of the
Freizone protocol; it now runs the same one the server project maintains
(`SRV-23`), which is why group chats work properly in this release for the
first time. Your accounts, contacts and settings come across untouched — but
**existing chat history and secure sessions do not**. Your conversations will
open empty, and the first message to each contact quietly re-establishes
encryption with them. Nothing is lost that was ever on a server: history only
ever existed on the devices holding it, so a message you want to keep should be
saved before updating.

### Added

* **Group messages now say when they were said.** A time under each message,
  the same day dividers a one-to-one chat has, and — for your own messages —
  whether they arrived
* **Delivery detail for a group message.** The footer counts how many members
  received or read it; tapping the count opens a list naming each member and
  what happened to their copy, with a reason for any that did not arrive
  ("Their server could not be reached."). If some failed, one button re-sends
  to exactly those and nobody else
* **Read receipts in groups**, per person: you see who has read a message, not
  just who received it. Confirming somebody's newest message confirms their
  earlier ones too, so nothing is left hanging half-read. The read-receipt
  setting covers groups as well — with it off, neither status is sent
* **The group tells you what happened to it**: who joined, who was invited,
  and — new — when a member's account has ceased to exist, so a member who can
  never receive anything again is not a silent failure

### Changed

* A message now shows **the time its author wrote it**, rather than the moment
  it reached this device. In a group those differ per member: a copy delayed
  by a server outage used to be stamped later for that one person, so the same
  message read differently for everybody holding it
* **A server that cannot be reached is no longer an alarm.** It is the most
  ordinary failure there is — a server can be down, switched off for good, or
  reused for something else — so it is shown as the dimmed account with its
  offline badge, and nothing else. Failures worth reading are still shown, now
  as sentences rather than as technical error text

### Fixed

* **The read-receipts setting did nothing.** Turning it off left both the
  received and read confirmations being sent as before. Existing marks stay as
  they are; from now on the switch decides
* **"Save pictures to the gallery automatically" did nothing** either. It now
  runs where a received picture first becomes a file
* Sending a picture into a group with members on different servers failed
  outright ("recipients for one attachment must share a server"). The picture
  is uploaded once per recipient server now (`SRV-18`)
* After sending a picture to a group you saw only your own blurred preview of
  it, never the full photograph — although everybody else received it
* Arriving pictures could fail with "downloading attachment failed", and a
  group transcript containing one could come up **completely empty**
* "Resend to those it failed for" could sit there doing nothing, and a
  successful resend delivered the message a second time to members who already
  had it — which arrived as a flood of notifications
* Removing a conversation permanently left the secure session with that person
  in place, so a later message from them could arrive against a session the
  chat no longer had

## [0.20.0] — 2026-08-07 (versionCode 24)

### Added

* Pictures you receive can now leave the app (`APP-20`). Open one full-screen
  and the app bar offers **Save to gallery** and **Share**; holding the message
  offers the same two. There is also a setting — off unless you turn it on —
  that saves every picture you receive as it arrives. Worth knowing either way:
  a copy in your gallery is outside Freizone, where other apps can read it and
  a photo backup will normally upload it, which is why nothing is copied there
  until you ask. Pictures you sent yourself are not offered for saving, since
  they came out of your gallery to begin with

### Fixed

* Messages to a contact or group member who reinstalled Freizone (or restored
  their account from its recovery phrase) could fail forever, silently for
  them: the app kept addressing the device their server had since forgotten,
  and never re-checked. Now the first failed send notices, looks the contact's
  current device up again, and delivers — following the stale-device rule the
  server protocol now spells out (freizone-server PROTOCOL §4). Found in a
  live group where one member stopped receiving anything after re-creating
  their account
* Blocking could fall out of sync with itself: deleting a blocked contact's
  chat keeps the block (on purpose), but starting a new chat with them again
  created a conversation that *looked* unblocked — profile said "Block this
  contact", direct messages came through — while their group messages were
  still silently dropped. The block list is now the single authority: new
  conversations inherit it, incoming messages re-sync it, and every screen
  that shows or toggles a block asks it directly

### Changed

* A blocked contact's messages in a **group** no longer vanish without a
  trace. The shared transcript now shows a centered line — "A message from
  … was hidden (blocked contact)." — where their message would have been,
  so other members' replies stop reading as answers to nothing.
  Consecutive hidden messages collapse into one line, and a blocked member
  still can't ring you: no notification, no unread badge, and the group
  doesn't move up the chat list. One-to-one chats are unchanged — there the
  block bar on the chat itself already says everything

## [0.19.0] — 2026-08-06 (versionCode 23)

See when your server is running more accounts than it's licensed for.

### Added

* The Server Admin screen now warns when the number of active accounts
  passes the seat count a server's attestation covers (`APP-23`, `SRV-22`,
  freizone-licensing `LIC-08`) — right beside the existing attestation
  status and its expiry warning. Never shown anywhere else: how many
  accounts a server has stays between the server and its own admins, unlike
  the attestation badge itself

## [0.18.0] — 2026-08-06 (versionCode 22)

Know when a server is run in agreement with the Freizone project.

### Added

* A small checkmark badge marks a server as attested by the Freizone project
  (`APP-22`, `SRV-19`) — never a person. Shown wherever you're deciding
  *about a server*: the setup wizard when adding one, the account switcher
  (once per server, beside its label), a contact's profile (next to their
  server, not their name), your own profile, and — for your own server — the
  admin area, with a warning before it lapses. Tapping it explains what was
  actually checked, until when, and states plainly that it says nothing
  about the security of your messages, which is identical on every Freizone
  server regardless of who runs it

## [0.17.0] — 2026-08-05 (versionCode 21)

Groups say who is talking: the names you have given people, everywhere a group
used to show a five-character address.

### Added

* Names instead of five-character addresses throughout a group (`APP-18`).
  Wherever a group used to label somebody `qk43r`, it now shows the name you have
  given them with that short address in parentheses — above their messages, in
  the quote of a reply, in the member list, in the delivery list of your own
  message, and in the chat list's preview line. Somebody you have not named is
  shown exactly as before, so nothing goes missing while you work through a
  group
* **Name this person** in the long-press menu of a group message. Naming
  somebody from the transcript takes effect immediately, everywhere — every chat
  on this device, on all of your accounts — and it is the same list the Contacts
  area manages, so nothing has to be typed twice
* **Message them directly** in the same menu. It opens your existing one-to-one
  chat with that member, or starts one, always from the account whose group you
  are reading — the one address of yours they have already seen

### Changed

* The member list in a group's info screen shows the same name-and-short-address
  label as the transcript instead of the member's full 21-character address
  (`APP-18`), so the same person reads the same in both. The full address is
  still on their contact and profile screens

### Known limitation

* The grey status lines inside a group ("… joined the group.", "… was removed
  from the group.") keep the short address even for somebody you have named
  (`APP-18`). Those lines are written once, when the change happens, and are
  deliberately never re-worded afterwards — a name you change later must not
  silently rewrite what the transcript said at the time

## [0.16.0] — 2026-08-05 (versionCode 20)

Contacts: the people you know, kept once for the whole app instead of once per
account.

### Added

* A **Contacts** area, behind its own icon at the top of the chat list
  (`APP-19`). It lists everyone you have named, on all your accounts at once, and
  opening one shows which of your accounts already chat with that person —
  including which of them have blocked them, since a block is per account. From
  there you can open one of those chats, or start a new one from another of your
  accounts; an account that could not reach them at all is shown with the reason
  instead of being offered and then failing
* **Remove permanently**, next to "Delete chat" in a chat's long-press menu
  (`APP-19`). It clears everything about that person from this device, including
  the encryption state — for a contact who is actually gone. Freizone checks
  first whether they can still reach you and says what it found; if it could not
  find out, the option stays available but tells you the risk: should they write
  again, their first messages cannot be read until the encryption has been
  rebuilt
* Adding a contact by hand from an address. It is checked against the server
  before it is saved, so a mistyped or shortened address is refused now rather
  than failing later — and if the server simply could not be reached, nothing is
  saved and you are offered another try

### Changed

* Deleting a chat now also forgets that you had accepted that person, so if they
  write again it arrives as a new request you can accept or decline instead of
  the chat quietly reappearing (`APP-19`). Their messages still arrive — the
  encryption is deliberately kept, which is what makes the request possible at
  all
* Names you give people are now kept once for the whole device instead of per
  account (`APP-19`). Name somebody in one account and every account of yours
  that talks to them shows that name; change it once and it changes everywhere.
  Your existing names are moved over automatically on the first start — if two of
  your accounts had called the same address different things, one is kept and you
  will be told which. Nothing about your chats changes, and no name ever leaves
  the device
* The Server Admin account view now looks like the profile screens it sits
  next to (`APP-11`): a large avatar with the role badge, the role and block
  state at a glance, and both addresses copyable with one tap instead of an id
  you had to select by hand. Blocking and deleting are now spelled out and
  behind buttons rather than tappable rows

### Fixed

* The search box in the Server Admin user list moved its text as soon as you
  typed, and sat too high (`APP-10`)

## [0.15.0] — 2026-08-04 (versionCode 19)

The rest of what a group chat needs: replying, and seeing who got what.

### Added

* Tap the "received by 3 of 5" indicator under your own group message to see
  who has it (`APP-16`). Each member is listed with how far their copy got —
  read, received, sent but not confirmed yet, still sending, or not delivered —
  with the ones you can do something about at the top, and a note where somebody
  got the message but not its picture. If a copy failed, one button resends it
  to just those members; nobody who already has the message gets it twice
* Reply to a message in a group chat, the way you already can in a one-to-one
  chat (`APP-17`). The quote above your reply names the person you are
  answering, in their own colour, and tapping it jumps to their message.
  Replies from people on an older version still show their quote — without a
  name where this phone has no way to know whose message it was, rather than
  with a guessed one
* Long-press a message in a group chat to pin it or to delete it for yourself,
  the way you already can in a one-to-one chat (`APP-21`). Pinned group messages
  get the same bar above the transcript, and tapping it jumps to the message.
  Deleting removes the message from this device only — everyone else keeps their
  copy

### Fixed

* A picture received in a group chat stayed a blank bubble until you left the
  chat and opened it again (`APP-16`). It now appears as soon as it has
  downloaded, and shows a blurred preview of itself while it downloads instead of
  nothing at all. If you use several accounts in the same group on one device,
  each of them now downloads its own copy right away instead of waiting for the
  others

## [0.14.0] — 2026-08-04 (versionCode 18)

Pictures in group chats.

### Added

* Send a picture into a group, with or without a caption, and see the ones other
  members send (`APP-16`). One upload serves every member on the same server
  instead of one upload each, so sending into a large group no longer costs a
  copy of the picture per person on your connection (`SRV-18`)
* If a member's server does not store attachments, or will not take a picture
  that size, the message still reaches them as text and the bubble says how many
  members could not receive the picture — instead of the send failing for
  everybody or failing silently

### Changed

* A picture now starts downloading the moment its message arrives, rather than
  when you open the chat, so it is usually already there by the time you look
* Group chats got the same patterned background as one-to-one chats, and open
  scrolled to the newest message instead of somewhere in the middle

### Fixed

* A picture that failed to upload because of a dropped connection was recorded as
  "this member cannot receive pictures" permanently, with no further attempt. Only
  a server that actually refuses is treated that way now; anything else is retried
  and the message then arrives complete
* The loading placeholder on a picture was slightly too large for small bubbles,
  which made it look square

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
