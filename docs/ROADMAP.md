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
Status: planned · Also affects: shared Go core
Back up the identity root key as a recovery seed phrase, so losing the phone
without a second device no longer means permanent identity loss. Purely
client-side: identities are self-certifying and the server keeps no backup by
design, so there is no server involvement.

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
