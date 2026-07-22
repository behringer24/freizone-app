// A contact/account's avatar circle: a deterministic background color
// plus the account id's real entropy characters, arranged 2x2 -- the
// single shared implementation for every place that used to build its
// own CircleAvatar with ad-hoc initials-slicing (see avatar_color.dart's
// doc comment for why substring(0,2) of a raw id used to look nearly
// identical across every account).
import 'package:flutter/material.dart';

import '../util/avatar_color.dart';

/// Just the 2x2 grid of entropy characters, with no CircleAvatar/color
/// wrapper of its own -- for call sites that overlay their own
/// decorations (role badge, active indicator) and need this as a plain
/// `child:` inside a `CircleAvatar` they build themselves, so their
/// existing Stack/Positioned geometry (and thus exact prior size and
/// decoration placement) stays untouched. [PeerAvatar] below is the
/// convenience wrapper for every other, undecorated call site.
class PeerAvatarLabel extends StatelessWidget {
  const PeerAvatarLabel({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context) {
    // Always the real entropy characters -- never the contact's display
    // name (that's shown separately as plain text elsewhere). The avatar
    // is meant to be a stable per-account identity mark, independent of
    // whatever local alias is assigned: renaming a contact, or two
    // contacts sharing a similar name, must never change or collide
    // their avatars.
    final chars = accountEntropy(accountId).toUpperCase().split('');
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 2x2 rather than one line of up to 4 characters -- a
            // circle is widest through the middle and narrowest top
            // and bottom, so a single row wastes exactly that space
            // and forces a smaller font just to fit horizontally. Two
            // short rows use both axes and read larger at the same
            // radius.
            for (var i = 0; i < chars.length; i += 2)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in chars.skip(i).take(2))
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Text(
                        c,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          height: 1.0,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class PeerAvatar extends StatelessWidget {
  const PeerAvatar({super.key, required this.accountId, this.radius = 20});

  final String accountId;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: avatarColorFor(accountId),
      child: PeerAvatarLabel(accountId: accountId),
    );
  }
}
