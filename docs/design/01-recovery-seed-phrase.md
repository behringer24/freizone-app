# Design: Recovery seed phrase

Status: **done** · Roadmap: [APP-01](../ROADMAP.md)

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

