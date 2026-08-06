// Verified-operator badge (SRV-19 / APP-22): marks a *server* as attested by
// the Freizone project, never a person -- see
// docs/design/22-verified-badge.md for the placement and wording rules this
// file exists to satisfy. The shape is painted rather than loaded from an
// asset: gfx/verified_badge.svg (the canonical design, shared with the
// server's landing page) uses a <style>/@media dark-mode switch that
// flutter_svg does not reliably honour, so this reproduces the same 8-lobe
// seal + checkmark geometry directly with a CustomPainter, keyed off
// Theme.of(context).brightness instead. Keep the coordinates below in sync
// with that SVG if the shape ever changes.
import 'package:flutter/material.dart';

import '../ffi/models.dart';

// Fixed brand colors, matching gfx/verified_badge.svg and the server's own
// landing page (internal/api/web/index.html in freizone-server) exactly --
// deliberately NOT tied to the user's chosen AccentPreset (app_settings.dart).
// This is a trust mark, not themed UI: it must look the same regardless of
// which accent someone has picked, the same way it looks the same to every
// visitor of the web page regardless of that page's own accent.
const _fillLight = Color(0xFF0C8577);
const _fillDark = Color(0xFF3FBFAD);
const _checkOnLight = Colors.white;
const _checkOnDark = Color(0xFF06201C);

class _VerifiedBadgePainter extends CustomPainter {
  const _VerifiedBadgePainter({
    required this.fillColor,
    required this.checkColor,
  });

  final Color fillColor;
  final Color checkColor;

  // Same eight points and radii as gfx/verified_badge.svg's 40x40 viewBox,
  // scaled to whatever size this paints at.
  static const _petalCenters = [
    Offset(32, 20),
    Offset(28.485, 28.485),
    Offset(20, 32),
    Offset(11.515, 28.485),
    Offset(8, 20),
    Offset(11.515, 11.515),
    Offset(20, 8),
    Offset(28.485, 11.515),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 40;
    final fillPaint = Paint()..color = fillColor;
    for (final center in _petalCenters) {
      canvas.drawCircle(center * scale, 7.5 * scale, fillPaint);
    }
    canvas.drawCircle(const Offset(20, 20) * scale, 13 * scale, fillPaint);

    final checkPaint = Paint()
      ..color = checkColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final check = Path()
      ..moveTo(13 * scale, 21 * scale)
      ..lineTo(18 * scale, 26 * scale)
      ..lineTo(28 * scale, 13 * scale);
    canvas.drawPath(check, checkPaint);
  }

  @override
  bool shouldRepaint(covariant _VerifiedBadgePainter oldDelegate) =>
      oldDelegate.fillColor != fillColor ||
      oldDelegate.checkColor != checkColor;
}

/// The checkmark glyph alone, with no tap behavior. Most call sites want
/// [VerifiedBadge] instead -- reach for this bare glyph only where a tap
/// target for the same information already exists on an ancestor (or would
/// be redundant, as in the explanation sheet's own header).
class VerifiedBadgeGlyph extends StatelessWidget {
  const VerifiedBadgeGlyph({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      size: Size.square(size),
      painter: _VerifiedBadgePainter(
        fillColor: dark ? _fillDark : _fillLight,
        checkColor: dark ? _checkOnDark : _checkOnLight,
      ),
    );
  }
}

/// A small, tappable checkmark marking [server] as attested by the Freizone
/// project. Tapping it opens [showAttestationExplanationSheet] -- the badge
/// is never shown without that explanation reachable from it (see the
/// design doc's "two rules the UI has to hold to"). Default size 16 matches
/// the account switcher's existing role/offline badge glyphs.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({
    super.key,
    required this.info,
    required this.server,
    this.size = 16,
  });

  final AttestationInfo info;
  final String server;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Registered operator -- tap for details',
    child: GestureDetector(
      onTap: () =>
          showAttestationExplanationSheet(context, info: info, server: server),
      child: VerifiedBadgeGlyph(size: size),
    ),
  );
}

/// Explanatory copy per tier -- the mark itself never varies by tier (see
/// the design doc's "considered and not done: a tier-coloured badge"), but
/// the sheet it opens (and the admin area's own status section) does. An
/// unrecognised tier (a server on a newer protocol revision than this build
/// knows about) gets the neutral fallback rather than nothing, so this app
/// never contradicts a server it just doesn't have a specific label for yet
/// -- the same SRV-10 forward-compatibility rule the server's own landing
/// page follows.
String attestationTierDescription(String tier) => switch (tier) {
  'community' =>
    'This is a community server -- non-commercial, run in agreement with '
        'the Freizone project.',
  'commercial' =>
    'This server holds a commercial licence from the Freizone project.',
  _ => 'This server is attested by the Freizone project.',
};

String formatAttestationDate(DateTime utc) {
  final d = utc.toLocal();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Opens the badge's explanation: what was actually checked, until when,
/// and -- stated outright, not implied -- that it says nothing about
/// message security. This sheet is part of the feature, not an optional
/// tooltip: a badge a user could read as "safer" without it would cause
/// harm its accuracy doesn't undo. Shared by every placement so the wording
/// never drifts between the setup wizard, the account switcher, a peer's
/// profile, and the admin area.
Future<void> showAttestationExplanationSheet(
  BuildContext context, {
  required AttestationInfo info,
  required String server,
}) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const VerifiedBadgeGlyph(size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Registered operator',
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(attestationTierDescription(info.tier)),
            if (info.subject.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Operated by: ${info.subject}'),
            ],
            const SizedBox(height: 8),
            Text('Server: $server'),
            const SizedBox(height: 8),
            Text('Valid until ${formatAttestationDate(info.expiresAt)}'),
            const SizedBox(height: 16),
            Text(
              // Stated, never implied -- see this function's own doc comment.
              'This says nothing about the security of your messages: '
              'end-to-end encryption is identical on every Freizone server, '
              'regardless of who runs it.',
              style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
