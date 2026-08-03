// Shared admin/moderator badge icon -- used by admin_screen.dart's user
// list, the account switcher strip (account_shell_screen.dart) and a
// group's member list, so a role reads as the same glyph everywhere.
// Null for "user"/"member" (no badge) or an unknown/not-yet-loaded role.
import 'package:flutter/material.dart';

IconData? roleBadgeIcon(String? role) => switch (role) {
  // A group's founder outranks its admins and is not the same thing as a
  // server admin, so it gets its own glyph rather than borrowing one.
  'founder' => Icons.workspace_premium,
  'admin' => Icons.engineering,
  'moderator' => Icons.person,
  _ => null,
};
