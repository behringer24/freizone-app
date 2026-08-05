# Design: Verified-operator badge

Status: **planned** · Roadmap: [APP-22](../ROADMAP.md) · Server side: freizone-server
[SRV-19](https://github.com/behringer24/freizone-server/blob/master/docs/ROADMAP.md)

SRV-19 gives a server a signed attestation and this client the means to verify
it. Everything left is placement — which sounds like the easy half and is not,
because **the attestation is about a server and users will read it as being
about a person.** That single mismatch decides every question below.

Verification runs in the shared native core, like everything else touching
signatures, so the rule cannot drift from the server's. It costs no extra
request: `getServerStatus` is already fetched for a peer's server during
federation (`AppSession`, around line 958) for capability discovery, and the
attestation arrives with it. The verified result is cached against its own
expiry rather than re-checked per chat, so an offline client keeps showing what
it last confirmed until that date passes.

**Where it belongs**

- **Setup wizard, when adding a server.** The one moment a user makes a decision
  *about a server*, so the one moment the information is decision-relevant. The
  wizard already calls server-status here, so there is nothing new to fetch.
- **Account switcher**, in the avatar's existing bottom-right slot (radius 12,
  icon 16). The strip's layout is not to be restructured for this; the slot is
  there and this is what it is for.
- **Peer profile**, on its own line attached to the *server* half of the
  address — `Server: example.org ✓ …` — and never beside the person's name. The
  profile screen is where an address is already broken into its parts, which
  makes it the one place the distinction reads naturally.
- **Admin area**, for one's own server: current state plus a warning before the
  attestation lapses. Without it the first sign of expiry is a badge that
  silently stopped appearing, discovered by a user rather than the operator.

**Where it does not belong: the chat header, the chat list, contacts.** A tick
beside a person's name means "this person is verified" to anyone who has seen
one anywhere else, and this attestation says nothing whatsoever about the
person. In the list views it would additionally be noise on every row for
information nobody is acting on while scrolling.

**Two rules the UI has to hold to.**

The badge is **tappable** and opens an explanation: what was attested, until
when, and — stated, not implied — that it says nothing about the security of
messages, which is identical on every Freizone server because encryption does
not depend on who runs it. The explanation is part of the feature, not a
tooltip: a badge that lets a user infer "safer" has done harm that its accuracy
does not undo.

The **absence of a badge is never rendered as a warning.** No grey counterpart,
no "unverified", no exclamation mark, no muted styling. Families, clubs and
self-hosters will never carry an attestation and that is the normal case, not a
deficiency — treating it as one would devalue the ecosystem this app exists to
serve and push everyone towards a central programme, which is the opposite of
the point. Additive only.

**Wording.** "Verified" carries the meaning it acquired elsewhere: a person's
identity. The label should say what was actually checked and about whom —
"registered operator", "licensed operator" — so the noun in the badge is the
operator, not the user being talked to.

Considered and not done:

- **The badge in the chat header.** The most requested-looking place and the
  most misleading one. If it ever goes there, it can only hang off an address
  shown in full, never off a display name.
- **A tier-coloured badge.** Distinguishing tiers by colour asks users to learn
  a legend for a distinction that does not affect them; the tier belongs in the
  explanation sheet, not in the mark.
- **Verifying in Dart.** Would put a second implementation of a signature rule
  in the codebase, which is the thing the native core exists to prevent.
