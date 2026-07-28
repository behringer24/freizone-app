# Freizone Roadmap — freizone-app

Planned changes whose **essential** work lands in this repo (the Android/Flutter
client). Cross-repo and protocol-level items live in freizone-server's
`docs/ROADMAP.md` (the project core).

Each item has a short **reference code**; the prefix names the owning repo:

- `SRV-` — freizone-server (core)
- `APP-` — freizone-app (this file)
- `GAW-`  — freizone-gateway

A change spanning several repos is listed **once**, in the repo where the
essential work happens; its entry names the other repos it touches.

Status values: `planned` · `in progress` · `done` · `deferred`.

## Planned

### APP-01 — Recovery seed phrase
Status: done · Depends on: SRV-06 · Also affects: shared Go core, freizone-server
Back up the identity **root key** as a recovery seed phrase (~24 words), so
losing the phone without a second device no longer means permanent identity
loss. Because `account_id == hash(root_pubkey)`, restoring the same root key
restores the **same account id and short id** (and the same `id*server`
address) — recovery keeps the user's existing identity, it does not mint a new
one. (A fresh re-registration without the seed would, by contrast, produce a
new id.)

Scope decision: the seed carries the **root key only** (not the per-device
key). Recovery therefore generates a *new* device keypair, signs its device
cert with the restored root key, and registers it — which needs a
root-key-authenticated recovery endpoint on the server (**SRV-06**), since
today adding a device requires an *existing* active device's signature and
re-registering an existing account is rejected (`409 account_exists`). So this
is **not** purely client-side.

The user also needs their **home-server address** (the account id doesn't
encode it), and must understand that **chat history is not recovered** — the
server keeps no plaintext/history by design (history is separate: APP-05 backup
/ APP-02 transfer). After recovery, existing conversations re-establish their
ratchet sessions via SRV-03 (each peer's old session still points at the lost
device until it re-keys).

**Shipped 2026-07-26** (server companion SRV-06 also shipped): BIP-39 24-word
phrase, encoded/decoded in the shared Go core (`pkg/mnemonic`, embedded 2048-word
English list) so the 32-byte seed never crosses into Dart. Two new FFI exports
(`RevealRecoveryPhrase`, `RestoreIdentityFromSeed`, plus `RecoveryWordlist` for
offline validation). Backup UI: a "Recovery phrase" entry in the profile screen
→ a warned, `FLAG_SECURE` backup screen with a numbered 24-word grid, copy
(clipboard auto-clears after 60s), QR (`qr_flutter`), and share (`share_plus`);
plus a one-time post-setup nudge on the chat list (dismissible, tracked by an
`AppState.recoveryBackupDone` flag). Restore UI: a "Recover an existing account"
branch in the setup wizard (server + QR-scan or manual 24-word entry) that calls
the SRV-06 endpoint via `ApiClient.recoverAccount` (root-key-signed request).
**Verified end-to-end 2026-07-27** (emulator and real device): create → back
up → wipe/lose the device → restore with the phrase → same account id/short
id, old device revoked server-side, account role (admin/moderator) intact,
messaging heals via SRV-03.

### APP-02 — Multi-device history transfer
Status: planned · Also affects: shared Go core · Depends on: SRV-02
Move existing local chat history onto a newly linked device. Depends on the
multi-device linking channel (SRV-02).

### APP-03 — iOS client
Status: planned · Also affects: freizone-gateway (GW-01)
No `ios/` directory yet; only Android is built/tested. iOS push delivery needs
the gateway's APNs path (GW-01).

### APP-04 — Multimedia messaging
Status: planned · Also affects: possibly freizone-server (blob transport)
Send media, in priority order: (1) images from the gallery, (2) video,
(3) audio, (4) later possibly voice messages. Large blobs may need a companion
server-side transport — if so, that gets its own `SRV-` entry.

### APP-05 — Backup
Status: planned
Versioned local data backup, optionally synced per device to iCloud (iOS) /
Google Drive (Android).

### APP-06 — Chat text export
Status: planned
Export a single chat as a `.txt` file (no media): timestamp, name, short
address in parentheses, and the text — shareable via the OS share sheet into
other apps.

### APP-07 — Biometric app lock
Status: planned
Require a biometric unlock when opening the app.
