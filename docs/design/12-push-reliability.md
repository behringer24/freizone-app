# Design: Push reliability: FCM token refresh while the app is closed

Status: **done** · Roadmap: [APP-12](../ROADMAP.md)


**Shipped 2026-08-01.** `FreizonePushService` (Kotlin) subclasses
firebase_messaging's own service, calls `super.onNewToken` so the foreground
stream is untouched, and starts a throwaway `FlutterEngine` on
`pushTokenRefreshEntrypoint`, which calls `reregisterAllProfiles()`. The engine
is torn down when Dart reports back over `freizone/push_token_refresh`, with a
60s timeout as backstop.

Both flagged traps were real and are handled:

- **The manifest conflict.** Verified in the *merged* manifest, not just in
  source: firebase_messaging's `FlutterFirebaseMessagingService` is gone
  (`tools:node="remove"`), ours carries the `MESSAGING_EVENT` filter at default
  priority, and the SDK's own fallback `FirebaseMessagingService` sits at
  `priority="-500"` — so ours wins deterministically, which is the documented
  Firebase mechanism rather than luck.
- **A missing compile dependency, found by the build.** Subclassing the
  plugin's service needs `FirebaseMessagingService` on *this* module's compile
  classpath; through the plugin it is only a transitive runtime dependency,
  enough to run but not to extend. Added via the Firebase BOM so the version
  can't drift from what the plugin ships.

Also done: the device-wide mechanism resolution is hoisted into
`resolvePushMechanism()` and passed down, so `registerForPush` and
`_onFcmTokenRefresh` no longer re-ask the same question inside a per-account
loop. `AppState` gained a persisted `pushRegisteredAt`/`pushMechanism`, and the
Settings info line plus `PushStatusScreen` are in place.

**Still to verify on a device** (not reproducible on an emulator without
forcing a token rotation): that a real rotation with the app closed actually
reaches the server. `adb shell am broadcast` cannot fake it, since only the FCM
SDK can invoke `onNewToken` — the practical test is to clear Play Services'
FCM state or reinstall, watch logcat for
`[freizone/push] background token-refresh engine started`, then check the push
status screen's timestamp.

Push registration only happens inside `AppSession.init()`
(`_registerPush()` → `registerForPush()` in `push/push_manager.dart`), which
runs when the app's Dart UI creates a session — i.e. when a user opens the
app. `initPush()` (`main.dart`) runs on every process start, including
UnifiedPush's background relaunch, but only wires up callbacks; it registers
nothing.

**Audit done, and it splits cleanly in two.** Verified against the plugin
sources, not assumed:

- **UnifiedPush is fine.** `unifiedpush_android` merges its own
  `UnifiedPushService` (a `PushService` subclass) into the manifest, reacting
  to `PUSH_EVENT` broadcasts, and starts its *own* `FlutterEngine` with
  `listOf("--unifiedpush-bg")`. So `onNewEndpoint`/`onUnregistered` reach Dart
  even with the app fully dead, and `push_manager.dart`'s header comments
  about this are accurate.
- **FCM token refresh is lost while the app is closed.**
  `FlutterFirebaseMessagingService.onNewToken` does exactly one thing:
  `FlutterFirebaseTokenLiveData.getInstance().postToken(token)` — an
  **in-process LiveData**. With no live Flutter engine observing it, the new
  token goes nowhere and is **not persisted**. `firebase_messaging` offers no
  background hook for tokens either: `onBackgroundMessage` exists, an
  equivalent for `onTokenRefresh` does not.

**What that actually costs, stated precisely** — because it is smaller than it
first looks and that shapes the fix. On the next app start, `_registerFcm`
calls `getToken()`, which returns the *current* token and re-registers it. A
missed refresh therefore breaks nothing permanently. The damage is confined to
**the window while the app stays closed**, and that window is the originally
reported symptom: the token rotates, the server keeps the stale one, the
gateway's send comes back `UNREGISTERED`, freizone-server clears the push
target (`dropDeadPushTarget`), and no wake arrives again until the app is
opened by hand — which the user has no reason to do, precisely because nothing
is notifying them.

#### The fix: re-register from a background engine on `onNewToken`
Mirrors the pattern `UnifiedPushService` already proves in this app:

- A Kotlin `FirebaseMessagingService` subclass whose `onNewToken` calls
  `super` (so the foreground `onTokenRefresh` stream keeps working unchanged)
  and then starts a `FlutterEngine` on a dedicated Dart entrypoint.
- **Manifest care needed:** only one service may claim
  `com.google.firebase.MESSAGING_EVENT`. The plugin already declares
  `FlutterFirebaseMessagingService` for it, so ours has to *replace* that
  declaration (`tools:node="remove"` on theirs, or `tools:node="replace"`),
  not sit beside it — two services claiming the same event is undefined and
  exactly the kind of subtle break that would look like "push works on my
  device". Worth verifying in the merged manifest, not just in source.
- Dart side needs almost nothing new: `_onFcmTokenRefresh(newToken)` already
  iterates every stored profile and honours `pushPreference`. The new
  `@pragma('vm:entry-point')` entrypoint can call straight into it.
- Engine lifecycle is the fiddly part: it must stay alive until the Dart work
  finishes and then be torn down, so a small completion channel back to Kotlin
  is needed rather than fire-and-forget.

#### Also in scope: making the push state visible in Settings
Chosen deliberately after this took three attempts to pin down: the next "I
get no notifications" report should be checkable without logcat.

**What is app-wide and what is per-account** — worth stating, because an
earlier draft of this entry got it wrong and over-modelled the UI as a result:

- **The mechanism is app-wide.** `pushPreference` lives in `AppSettings`, not
  in the profile (`AppState` has no push field at all), and in `automatic`
  mode the resolution is device-wide too: `_registerUnifiedPush` decides from
  the installed distributors, and the chosen distributor is persisted by the
  plugin for the whole app. All accounts therefore land on the same mechanism
  in practice. The **FCM token is one per install**, which is exactly why
  `_onFcmTokenRefresh` pushes the *same* token to every account's server.
- **The registration is per-account.** `setPushTarget`/`setPushEndpoint` are
  signed requests against *that* account's own server, and UnifiedPush issues
  a separate endpoint per `instance`. So one account can be registered fine
  while another failed (server unreachable), and that is the part that
  genuinely varies.

So the UI splits along that line rather than repeating everything per account:

- **One info line under the existing radio buttons.** The radios already say
  what the user *chose*, and `_PushDistributorTile` already shows and picks the
  distributor — so the line's job is only to add what neither conveys: for
  `automatic`, which of the two it actually resolved to, plus whether anything
  is registered at all. It carries a `>` into the detail screen.
- **A sub-screen for the per-account registrations**, since "did account B's
  server accept my push endpoint" is a specialist question that does not belong
  in the main Settings flow. One row per account: registered or not, and when
  it last succeeded. Plus a "Re-register now" action, app-wide over all
  sessions — the same "all sessions" rule `_setPushPreference` and the
  distributor tile already follow.

Needs a little persistence: `AppSession.pushRegistration` is in-memory only
today, so the per-account outcome and its timestamp have to live on the
profile to survive a restart.

Worth folding in while here: `automatic` currently re-checks distributor
availability *inside* the per-account loop (in `registerForPush` and again in
`_onFcmTokenRefresh`). Harmless, since the answer is device-wide and identical
every time — but it is precisely what obscures the app-wide/per-account split
above, so hoisting it out is a small clarity win.

#### Considered and rejected: a `BOOT_COMPLETED` receiver
An earlier draft of this entry listed one as work item 2. On inspection its
value does not justify the surface: a reboot does not rotate an FCM token, and
Play Services and the UnifiedPush distributor re-establish their own
connections regardless — so it would only cover a token that rotated *during*
the off period. On top of that a `BroadcastReceiver` gets roughly ten seconds,
which is not a comfortable place to spin up a Flutter engine, so doing it
properly would mean pulling in `androidx.work` as another native dependency.
The `onNewToken` path above covers the realistic case on its own.

#### Confirmed already correct
freizone-gateway sends FCM with `AndroidConfig{Priority: "high"}`
(`freizone-gateway/internal/push/fcm.go`) — the documented way to stay exempt
from Doze and App-Standby-Bucket throttling for apps the user hasn't engaged
with recently. Not a gap.

#### Out of scope
OEM battery and autostart managers (Xiaomi/Huawei/Samsung) killing Play
Services' or the distributor's own background connection, regardless of what
this app does. Mitigable only by user-facing guidance (a Settings hint to
exempt the app from battery optimisation), never by app code — and the status
panel above is what would make such a case visible in the first place.

