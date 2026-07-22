// Shared deterministic avatar background color -- used by PeerAvatar
// (widgets/peer_avatar.dart), so the same id always gets the same color
// everywhere.
import 'package:flutter/material.dart';

import 'address_format.dart';

// A small curated palette rather than the raw, unfiltered
// Colors.primaries (~17-19 hues, some low-contrast against white text
// like yellow) -- same philosophy as AppSettings.AccentPreset's curated
// theme colors, but a separate, slightly larger list of its own: avatars
// need more spread across many contacts than the 6 theme accents do.
const _avatarPalette = [
  Colors.teal,
  Colors.indigo,
  Colors.purple,
  Colors.deepOrange,
  Colors.pink,
  Colors.green,
  Colors.blue,
  Colors.brown,
];

/// The characters of [id] that actually carry per-account entropy --
/// index 0 is always the version marker (see accountIdPrefixLength's own
/// doc comment: freizone-server's pkg/address.CurrentVersion), never
/// real information, so it's never used for display or hashing here.
String accountEntropy(String id) => id.length > accountIdPrefixLength
    ? id.substring(1, accountIdPrefixLength)
    : (id.length > 1 ? id.substring(1) : id);

Color avatarColorFor(String id) =>
    _avatarPalette[accountEntropy(id).hashCode.abs() % _avatarPalette.length];
