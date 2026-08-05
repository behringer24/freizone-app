# Contributing to Freizone (Android app)

Bug reports and pull requests are welcome. This file covers the practical side,
plus one thing worth stating up front: contributions require a contributor
licence agreement, and the reason for it is spelled out
[below](#contributor-licence-agreement) rather than left to be discovered.

## Before you open a pull request

- **Open an issue first for anything non-trivial**, especially anything that
  changes what goes over the wire. The protocol lives in freizone-server's
  [`docs/PROTOCOL.md`](https://github.com/behringer24/freizone-server/blob/master/docs/PROTOCOL.md)
  and is binding on this client — a client-side change that needs a protocol
  change belongs in that repository first.
- **Crypto is not reimplemented here.** X3DH, the Double Ratchet, address
  derivation and device certificates all come from the shared Go core in
  [`native/`](native), which wraps freizone-server's own packages. A patch that
  reimplements any of that in Dart will not be accepted — the whole point of
  that arrangement is that client and server agree by construction.
- **Set the build up correctly.** This repo must sit next to a
  `freizone-server` checkout (`native/go.mod` references it with a relative
  `replace`), and the native core has to be built once before the first Flutter
  build — see [Getting started](README.md#getting-started). A missing
  `libfreizonecore.so` looks like the app hanging, not like a build error.
- **Firebase.** `android/app/google-services.json` is deliberately not in the
  repository. Building the FCM push path means creating your own Firebase
  project and supplying your own file; the UnifiedPush path needs none of this
  and is the easier one to develop against.
- **Keep it clean:**

  ```sh
  flutter analyze
  flutter test
  ```

  Both should be clean before you push. There is no CI yet, so these are run by
  hand.

- **Match the surrounding code.** Comments here explain *why*, not what. A patch
  that reads like the code around it needs no style discussion.
- **Non-obvious decisions belong in [`docs/design/`](docs/design/)** — one file
  per topic, linked from its roadmap entry.
- **Security.** Please do not open a public issue for a vulnerability in the
  cryptography, key handling or local storage. Report it privately to
  <info@behringer24.de> first.

## Contributor licence agreement

Every non-trivial contribution to this repository requires that you accept the
agreement below. It is short, and it does one thing the GPL alone does not: it
lets the copyright in the codebase stay undivided, so the licence can still be
changed later without having to track down and ask every person who ever
contributed.

### Why this project asks for it

The app is GPL-3.0 and is meant to stay free software that anyone can read,
build, audit and install — that is not in question, and there is no intention
to restrict who may use or download it. Anyone connecting to any Freizone
server, including the staff of a company running its own, should be able to
install this app without asking anyone's permission.

The concrete reason for the agreement is a licence problem that already exists:
**GPLv3 and Apple's App Store terms are not compatible.** Apple's terms impose
usage restrictions that GPLv3 forbids adding, which is why GPLv3 apps get
removed from the store (the VLC case being the well-known one). Shipping an iOS
client — the gateway already has the APNs side sketched out for it — would most
likely mean moving this app to a more permissive free licence such as MPL-2.0
or Apache-2.0.

That move is only possible while the rights in the codebase are held in one
place. Accept a single contribution without this agreement, and an iOS client
becomes blocked on getting written permission from that person, individually,
possibly years later.

### What you keep

You keep the copyright in your own work, and an unrestricted right to use it
however you like, including in other projects and under other licences. This
agreement takes nothing away from you; it adds a permission for the maintainer.

### The agreement

By submitting a contribution to this repository, you agree to the following,
for that contribution and for any future contribution you make here:

1. **Grant of rights.** You grant Andreas Behringer an exclusive, worldwide,
   perpetual, irrevocable, transferable and sublicensable right to use,
   reproduce, modify, adapt, translate, publish, distribute, and otherwise
   exploit your contribution, in whole or in part, alone or combined with other
   work, in any form and by any means whether known today or developed later,
   and to license it to third parties under any terms — including terms
   differing from the licence this project uses at the time you contribute.
   Where the applicable law does not permit copyright itself to be transferred
   (as under German law, § 29 UrhG), this is a grant of exclusive rights of use
   to the fullest extent that law permits.
2. **Licence back to you.** You retain a non-exclusive, worldwide, perpetual,
   irrevocable right to use, publish and license your own contribution for any
   purpose, under any terms, without restriction and without needing anyone's
   permission.
3. **You are entitled to grant this.** You confirm that the contribution is
   your own work, that you have the right to grant the rights above, and that
   it does not knowingly infringe anyone else's rights. If you wrote it in the
   course of employment or under a contract that might assign rights to someone
   else, you confirm that your employer or client has agreed to this, or that
   the contribution falls unambiguously outside that scope. (Under German law,
   rights in software written by an employee in the course of their duties pass
   to the employer automatically — § 69b UrhG — so this matters more often than
   people expect.)
4. **Patents.** To the extent your contribution is covered by a patent you own
   or control, you grant a perpetual, worldwide, non-exclusive, royalty-free
   licence to that patent, as far as is necessary to use, distribute and
   sublicense your contribution as part of this project.
5. **No warranty.** Your contribution is provided as-is. Except where the law
   provides otherwise, you give no warranty and accept no liability for it.

### Small changes

Fixing a typo, rewording a comment, correcting a broken link, adjusting a
translation string or reformatting existing code does not need this. There is
no original creative content in such a change, so there is nothing to license.

### How to accept it

Include this line in the description of your pull request:

> I have read CONTRIBUTING.md and I accept the Contributor Licence Agreement in
> it, for this and all my future contributions to this repository.

Your GitHub account and the pull request itself are the record. If a signing
bot is set up later, it will replace this step; anything accepted this way
stays valid.

If you are contributing on behalf of a company, or anything above does not fit
your situation, get in touch before you start — open an issue, or write to
<info@behringer24.de>. It is far easier to sort out beforehand.
