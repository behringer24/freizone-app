# Design: Save a picture from a transcript to the device gallery

Status: **done** · Roadmap: [APP-20](../ROADMAP.md) · Part of: APP-04

A picture in a transcript could be looked at and nothing else. The full-screen
view (`ImageViewScreen`, reached by tapping the bubble in a one-to-one chat and
in a group alike, since both render through `ImageAttachment`) had an app bar
holding only the back button, and the long-press sheet offered reply, pin and
"delete for me" — so a picture somebody sent could not leave the app at all.

Everything below except the last section was decided on 2026-08-04, before any
of it was built.

## A gallery copy leaves the app's protection

This is the fact the whole design hangs on. Everything the app stores today
sits in its own private directory, unreadable by any other app on the device. A
picture in the gallery is readable by every app holding media permission and,
on most phones, uploaded to the user's cloud photo library within minutes.

That is the entire *point* of the feature, and also the one property an
end-to-end-encrypted messenger must not hand over by accident. Hence:

- **The manual save is an act each time** and needs no framing beyond a short
  line saying where the copy ends up.
- **The automatic variant is opt-in, off by default**, and its setting has to
  *state what it does* rather than read as a tidy convenience toggle. An
  install that predates the setting has no such key stored and therefore reads
  as off — an update never starts copying pictures out of the sandbox on its
  own. (`test/app_settings_gallery_test.dart` exists for exactly that, not for
  the toggle's mechanics.)

## Share as well as save, not instead of it

Different destinations, so both are offered: saving files a copy in the
gallery, sharing hands the bytes straight to another app without one ever
landing there. `share_plus` was already a dependency, so this half cost
nothing.

Sharing is *not* limited to received pictures the way saving is — picking a
different destination each time is the whole of what it does, and there is no
duplicate-copy problem to avoid.

## Only received pictures may be saved

One this account sent came out of this device's own gallery in the first place
(`image_picker`), so saving it would file a second copy of something already
there.

Worth revisiting when APP-04's **camera capture** lands: `image_picker`'s
camera source writes to the app's cache directory, not the gallery, so a
self-taken picture would then be one that exists nowhere else — at which point
"only received" stops being the obvious rule. The predicate lives in one place
(`maySavePicture`) so that revisit is a one-line change.

## The storage permission is requested, not designed around

Saving means an insert into Android's own `MediaStore.Images`, with a
`RELATIVE_PATH` of `Pictures/Freizone` so the copies are grouped — not to be
confused with this app's `MediaStore` (`lib/state/media_store.dart`), the local
media cache. On API 29+ that insert needs no permission at all; `minSdk` is
Flutter's default **24**, so API 24–28 devices are in scope and there the write
needs `WRITE_EXTERNAL_STORAGE`.

The manifest gets it with `android:maxSdkVersion="28"` and the platform side
asks for it at runtime, rather than the cheaper alternative of hiding the
action below API 29. Following APP-15 and `secure_screen.dart` this belongs on
our own `MethodChannel` in `MainActivity` rather than a dependency — and it is
the first runtime permission the app asks for *itself* (`CAMERA` and
`POST_NOTIFICATIONS` are requested by `image_picker` and
`flutter_local_notifications`), so `MainActivity` needed `requestPermissions`
plus an `onRequestPermissionsResult` resolving the pending channel result. A
refusal leaves the picture where it is, says so, and is re-askable later.

## What the file's absence means

The on-disk file is already plaintext, so a save copies bytes and decrypts
nothing. But a picture whose download has not finished has no file yet — and
the file's presence is the only record of that. So the actions are resolved
from disk before the sheet is built, and are **absent** rather than present
and failing.

**Fixed 2026-08-15 (`1a99d16`).** This section originally named
`MediaStore.fileFor` as the lookup behind `attachedPictureFile` — that broke
silently on 2026-08-10 (SRV-23's cut moved where pictures are stored, and
`MediaStore.fileFor` went on looking in the old place), which is what took
"Save to gallery" and "Share picture" out of the long-press sheet for five
days without anyone changing this section. The lookup is now
`session.coreAccount.attachmentPath(chatId, message.id, localOnly: true)` —
the core is asked rather than the old Dart-side media tree, and the rest of
this document's reasoning is unaffected.

## What was decided while building it, 2026-08-07

- **`unsupported` is a distinct outcome from `failed`**, and is detected by the
  channel answering `MissingPluginException` rather than by asking `Platform`.
  The automatic save runs from `ensureAttachmentDownloaded`, which also runs in
  the background isolate — an Android device whose isolate never registered the
  handler would answer `Platform.isAndroid` correctly and still have nowhere to
  save. Making the channel the authority collapses "iOS", "unit test" and "no
  handler in this isolate" into the one case they actually are, and keeps a
  background save quiet where a manual one still reports something.
- **An automatic save never prompts** (`mayPrompt: false`). A picture arrives
  on its own schedule; a permission dialog with no user action behind it is
  unexplainable. The permission is instead requested when the *setting* is
  switched on, which is the moment the user is looking at the text explaining
  it — and the switch stays off if the request is refused, rather than reading
  as on while silently saving nothing.
- **The pre-API-29 and API-29+ saves are written as two separate operations**,
  not one compat wrapper. They genuinely differ: on 29+ the resolver owns the
  file and `IS_PENDING` hides a half-written one from other apps; below that we
  write the file into `Pictures/Freizone` ourselves and only tell `MediaStore`
  where it is. A failed write deletes its own row either way, so a broken
  entry never lingers in the gallery.
- **The automatic save is global, not per conversation.** The original sketch
  said "of a chosen conversation (or of all of them)"; only the second shipped.
  Per-chat scoping needs a place to persist a per-chat flag, and the setting
  that matters — pictures leave the sandbox at all — is the global one. Left
  open deliberately; see the roadmap's log.
