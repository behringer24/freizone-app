// Shared admin/moderator badge icon -- used both in admin_screen.dart's
// user list and the account switcher strip (account_shell_screen.dart),
// so a role reads as the same glyph everywhere. Null for "user" (no
// badge) or an unknown/not-yet-loaded role.
import 'package:flutter/material.dart';

IconData? roleBadgeIcon(String? role) => switch (role) {
  'admin' => Icons.engineering,
  'moderator' => Icons.person,
  _ => null,
};
