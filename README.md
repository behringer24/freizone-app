# Freizone (Android app)

The Android client for [Freizone](https://github.com/behringer24/freizone-server) — a self-hostable, federated, end-to-end encrypted chat server. No central provider: this app talks directly to whichever Freizone server you (or someone you trust) runs, and every message is encrypted on-device before it ever reaches that server.

**Status:** identity, multi-account support, X3DH + Double Ratchet end-to-end encrypted 1:1 messaging, invite QR codes, push notifications (via [UnifiedPush](https://unifiedpush.org/) or Firebase Cloud Messaging, see [Push notifications](#push-notifications) below), and a server admin area are implemented. Android only for now; groups/broadcast and federation are future work, tracked alongside the [server](https://github.com/behringer24/freizone-server)'s own roadmap.

## Features

- **End-to-end encryption** via X3DH + Double Ratchet, run by a shared Go crypto core (see [Architecture](#architecture) below) — the server only ever sees ciphertext.
- **Self-certifying addresses**: your account id is derived from your device's own key, not assigned by the server, so no server can silently swap in a different key without it being detectable.
- **Multi-account**: connect to several servers (or several identities on the same server) at once, all staying live in the background, with a quick account-switcher strip.
- **Invite QR codes**: generate a scannable QR for your server (± an invite code, depending on its registration policy); the setup wizard can scan one to fill in the whole join flow instead of typing an address by hand.
- **Push notifications** while the app is closed, via UnifiedPush (no Google dependency, works with any compatible distributor, e.g. [ntfy](https://ntfy.sh/)) or, as a fallback for devices without a distributor, Firebase Cloud Messaging relayed through a [freizone-gateway](https://github.com/behringer24/freizone-gateway) instance — a Settings toggle picks between them, see [Push notifications](#push-notifications) below. Either way, the payload itself carries no content or metadata; it's purely a "go sync" wake-up.
- **Server admin area** (for admin/moderator accounts): registration policy, invite codes, and the user list (roles, block/unblock, delete).
- **Short address alias**: an account can also be looked up by just the first 5 characters of its id (unique per server), instead of always typing the full 21-character form.

## Architecture

The end-to-end crypto and wire-protocol logic (X3DH, Double Ratchet, address derivation, device certificates) is **not reimplemented in Dart**. It's shared, compiled-once Go code — [`freizone-server`](https://github.com/behringer24/freizone-server)'s own `pkg/{ratchet,devicecert,address,wire}` packages, wrapped by a thin cgo shim in [`native/`](native) and cross-compiled to a JNI-loadable `.so`. The Flutter side ([`lib/ffi/`](lib/ffi)) calls into it over FFI. This means the client and server always agree on the exact same protocol implementation, by construction, not by convention.

```
lib/
  ffi/      FFI bindings + typed wrapper around the native core
  net/      REST client (ApiClient) + the SSE live-message stream
  push/     UnifiedPush + Firebase Cloud Messaging wiring, local "new message" notifications
  state/    AppSession (one per connected account), AccountManager, local JSON persistence
  screens/  UI
  util/     small, dependency-free helpers (id formatting, error messages, ...)
native/     the shared Go crypto core, built with -buildmode=c-shared
```

Every account's local state (its keys, conversation history, ratchet sessions) is persisted as one JSON file per account under the app's private storage — never on the server, which stores nothing but ciphertext in transit and public key material.

## Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) (stable channel).
- Android SDK + NDK (via Android Studio, or the command-line tools) — needed to build the native core for `arm64-v8a`.
- A Go toolchain, matching the version in [`native/go.mod`](native/go.mod) — only needed to build the native core, not for ordinary Flutter development once it's built.
- A running [`freizone-server`](https://github.com/behringer24/freizone-server) instance to connect to (see that repo's README for a local trial run or a real deployment).

## Getting started

1. Clone this repo **next to** `freizone-server` — `native/go.mod` references it via a relative `replace` directive (`../../freizone-server`), so both repos need to share a parent directory:
   ```
   sources/
     freizone-server/
     freizone-app/
   ```
2. Build the native core (Windows; adjust the `clang` path in the script if your NDK lives elsewhere):
   ```powershell
   ./native/build_android.ps1
   ```
   This cross-compiles `native/` to `libfreizonecore.so` and drops it directly into `android/app/src/main/jniLibs/arm64-v8a/` (generated — don't edit it by hand), where Gradle picks it up automatically. Re-run it whenever `native/*.go` changes; ordinary Dart changes don't need it.
3. Fetch Dart dependencies and run:
   ```sh
   flutter pub get
   flutter run
   ```
4. On first launch, the setup wizard asks for a server address (no `https://` or port needed for a normally-deployed server) and walks through whatever that server actually needs — bootstrap, open registration, or an invite code — including scanning an invite QR code instead of typing.

## Push notifications

Two independent, non-interfering delivery mechanisms exist; a device uses exactly one at a time per account:

- **UnifiedPush** (default when available): no Google dependency, works with any compatible distributor installed on the device (e.g. [ntfy](https://ntfy.sh/)). Nothing to configure here.
- **Firebase Cloud Messaging (FCM)**: the fallback for devices without a UnifiedPush distributor, relayed through a [freizone-gateway](https://github.com/behringer24/freizone-gateway) instance the connected server points at. Requires a Firebase project with an Android app registered under this app's package name (`de.behringer24.freizone`) — download that app's `google-services.json` from the Firebase console and place it at `android/app/google-services.json` (gitignored, operator-specific, not committed).

**Settings → Push delivery** lets you override which one this app registers, regardless of what's installed/available:
- *Automatic* (default) — prefers UnifiedPush if a distributor is installed, falls back to FCM only if none is found.
- *Always use Firebase (FCM)* / *Always use UnifiedPush* — pin to one explicitly, e.g. to test the FCM path without uninstalling a UnifiedPush distributor. UnifiedPush and FCM don't interfere with each other on the device; this setting only controls which one *this app* asks the server to use.

Because FCM issues one token per app install rather than one per account (unlike UnifiedPush's per-account distributor registration), an FCM wake can't say which account it's for — it shows a generic "New message(s)" notification rather than naming a specific account, and tapping it opens the app, which resyncs every connected account normally.

## Development

```sh
flutter analyze
flutter test
```

Both should be clean before committing. There's no CI configured yet — these are run manually.

## A note on trust

This client independently verifies the full self-certifying chain for every peer it talks to (`hash(root_pubkey) == account_id`, then verifies each device certificate's signature) rather than trusting the server's word for who owns which key or device. The server can misbehave (drop messages, go offline, get compromised) without being able to silently impersonate anyone or read your messages.
