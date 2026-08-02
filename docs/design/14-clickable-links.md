# Design: Clickable links in messages

Status: **done** · Roadmap: [APP-14](../ROADMAP.md)

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

