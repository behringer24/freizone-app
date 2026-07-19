// Shared branded presentation for both of Freizone's QR-invite screens
// (invite_screen.dart's server-join invite, my_address_screen.dart's
// chat invite): a teal-framed card with the QR code -- itself teal-eyed
// and framed, with the Freizone app icon embedded in its center -- plus
// a title/subtitle and whatever address text the caller wants shown
// underneath. Exposes [captureKey] so the caller's own share action can
// screenshot exactly this widget via RepaintBoundary, meaning the shared
// image looks the same as the screen itself.
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class QrInviteCard extends StatelessWidget {
  const QrInviteCard({
    super.key,
    required this.captureKey,
    required this.title,
    required this.subtitle,
    required this.qrData,
    required this.addressLines,
  });

  final GlobalKey captureKey;
  final String title;
  final String subtitle;
  final String qrData;
  final List<Widget> addressLines;

  static const _qrBoxSize = 240.0;
  // Matches QrImageView's own default `padding` -- needed to work out
  // how big one QR module actually renders at, in logical pixels.
  static const _qrPadding = 10.0;
  static const _iconDiameter = 48.0;

  @override
  Widget build(BuildContext context) {
    final teal = Theme.of(context).colorScheme.primary;

    // Same auto-versioning QrImageView uses internally (see qr_flutter's
    // own QrValidator) -- computing it here too is the only way to know
    // how wide one module renders at, since that depends on the data
    // length and isn't otherwise exposed by the widget.
    final qrCode = QrCode.fromData(
      data: qrData,
      errorCorrectLevel: QrErrorCorrectLevel.H,
    );
    final moduleSize = (_qrBoxSize - _qrPadding * 2) / qrCode.moduleCount;

    return RepaintBoundary(
      key: captureKey,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: teal, width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: teal,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(subtitle, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: teal, width: 3),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  QrImageView(
                    data: qrData,
                    size: _qrBoxSize,
                    backgroundColor: Colors.white,
                    // H-level correction is needed once the center icon
                    // covers part of the code -- the default L level
                    // can't reliably recover the obscured modules.
                    errorCorrectionLevel: QrErrorCorrectLevel.H,
                    eyeStyle: QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: teal,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black87,
                    ),
                  ),
                  _QrCenterIcon(
                    diameter: _iconDiameter,
                    ringWidth: moduleSize,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            ...addressLines,
          ],
        ),
      ),
    );
  }
}

/// The Freizone icon as it sits at the center of a QR code: circularly
/// cropped like the round app icon -- composed from the same
/// background+foreground layers the adaptive icon itself uses, so the
/// foreground artwork is cropped no more aggressively than the real app
/// icon already crops it -- ringed by a white border about one QR
/// module wide, so the icon reads as separate from the code around it
/// rather than colliding with the modules it overlaps.
class _QrCenterIcon extends StatelessWidget {
  const _QrCenterIcon({required this.diameter, required this.ringWidth});

  final double diameter;
  final double ringWidth;

  static const _background = AssetImage('gfx/origami_chat_background.png');
  static const _foreground = AssetImage(
    'gfx/origami_chat_foreground_android_adaptive.png',
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter + ringWidth * 2,
      height: diameter + ringWidth * 2,
      padding: EdgeInsets.all(ringWidth),
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: const ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image(image: _background, fit: BoxFit.cover),
            Image(image: _foreground, fit: BoxFit.cover),
          ],
        ),
      ),
    );
  }
}
