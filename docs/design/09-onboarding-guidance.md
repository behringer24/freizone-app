# Design: New-user onboarding guidance

Status: **planned** · Roadmap: [APP-09](../ROADMAP.md)

Two distinct empty states a new user hits, neither currently explained:

1. **No account on this device.** `main.dart` already routes here (no
   account → `SetupScreen` instead of the chat list), so the routing itself
   isn't the gap — but `SetupScreen`'s address step (`setup_screen.dart`)
   drops the user straight into a server-address form with no framing of
   what they're about to do. Add a short lead-in explaining that this
   creates (or connects to) an account on a chat server, before the form.
2. **Account exists, zero conversations.** `chat_list_screen.dart`'s empty
   state (`conversations.isEmpty`, ~line 381) already shows "No
   conversations yet / Tap the button below to start one", but doesn't
   point at anything concrete. Make it reference the actual "+" FAB
   (`Icons.chat`, bottom-right, ~line 629) explicitly, e.g. with an arrow
   or by naming its position, so the hint maps to a real control instead of
   a vague "the button below."

