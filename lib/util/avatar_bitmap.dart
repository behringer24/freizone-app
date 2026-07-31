// Rendering a contact's avatar to PNG bytes, for places outside Flutter's own
// widget tree -- currently the per-chat sharing shortcuts (APP-15 level 2),
// whose icons are drawn by the Android share sheet, not by us.
//
// Drawn straight onto a canvas rather than rasterising [PeerAvatar]: the widget
// needs a layout pass and a render tree, which is far more machinery than
// "a coloured square with up to four characters on it", and would tie an
// off-screen bitmap to whatever the widget tree happens to be doing.
//
// Deliberately fills the whole bitmap with the avatar colour instead of drawing
// a circle: the share sheet and launcher mask an icon to their own shape
// (circle, squircle, ...) and an adaptive icon has its outer third cropped, so
// a circle drawn here would be clipped into an odd lens. A full bleed survives
// every mask, with the characters kept well inside the safe zone.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'avatar_color.dart';

/// Edge length of the rendered bitmap. 256 is comfortably above what any
/// launcher asks for, and small enough that a handful of them cost nothing.
const _size = 256.0;

/// Fraction of the bitmap that is safe from adaptive-icon cropping. Android
/// crops the outer third, so the text has to live inside this.
const _safeZone = 0.62;

/// Renders [accountId]'s avatar -- the same colour and the same entropy
/// characters the in-app avatar shows -- as PNG bytes, or null if encoding
/// fails (in which case the caller simply publishes no icon).
Future<Uint8List?> renderAvatarPng(String accountId) async {
  try {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawRect(
      const Rect.fromLTWH(0, 0, _size, _size),
      Paint()..color = avatarColorFor(accountId),
    );

    // Same characters as PeerAvatarLabel, and for the same reason: the avatar
    // is a stable mark for the *account*, never the local alias, so renaming a
    // contact must not change their icon.
    final chars = accountEntropy(accountId).toUpperCase().split('');
    final rows = <String>[];
    for (var i = 0; i < chars.length; i += 2) {
      rows.add(chars.skip(i).take(2).join());
    }

    final safe = _size * _safeZone;
    // Two rows stacked, like the in-app 2x2 grid: a mask is widest through the
    // middle, so two short rows read larger than one long one at the same size.
    final rowHeight = safe / (rows.isEmpty ? 1 : rows.length);
    final fontSize = rowHeight * 0.9;

    var y = (_size - safe) / 2;
    for (final row in rows) {
      final painter = TextPainter(
        text: TextSpan(
          text: row,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: fontSize,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset((_size - painter.width) / 2, y));
      y += rowHeight;
    }

    final image = await recorder.endRecording().toImage(
      _size.toInt(),
      _size.toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
