# Design: A real thumbnail in the reply quote

Status: **planned** · Roadmap: [APP-13](../ROADMAP.md)

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

