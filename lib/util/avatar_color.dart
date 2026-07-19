// Shared deterministic avatar background color -- used for account
// switcher avatars (account_shell_screen.dart), the profile screen, and
// conversation avatars (chat_list_screen.dart), so the same id always
// gets the same color everywhere.
import 'package:flutter/material.dart';

Color avatarColorFor(String seed) =>
    Colors.primaries[seed.hashCode.abs() % Colors.primaries.length];
