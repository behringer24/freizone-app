# Design: Multimedia messaging

Status: **in progress** · Roadmap: [APP-04](../ROADMAP.md)

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
(SRV-03). Media files originally lived outside the profile JSON (which was
rewritten on every message) and were removed with their conversation or
account, plus an orphan sweep at startup; since SRV-23's cut (2026-08-10)
attachment storage and cleanup belong to the shared Go core instead, and the
Dart-side orphan sweep is dead code.

**Shipped since:** saving/sharing received pictures (APP-20, 2026-08-07).

**Still open:** (1.5) camera capture, and (2)-(4) video/audio/voice — video
will also want resumable uploads, which SRV-07 does not do yet.

