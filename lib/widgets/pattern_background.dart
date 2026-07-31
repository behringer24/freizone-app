// Shared decorative background: a transparent line-art pattern
// (gfx/chat_background_pattern.png -- chat bubbles, servers, cranes,
// hearts, network nodes) tinted at runtime and laid over a solid base
// color, instead of two separate pre-baked full-color images. Dark mode
// lightens the pattern, light mode darkens it, and the tint itself is
// derived from the app's own teal accent -- so the background always
// reads as "this app's colors", not a fixed neutral tone baked into a
// PNG. Used behind the chat message list (chat_screen.dart) and inside
// the QR invite card (qr_invite_card.dart, which brings its own base
// tone -- see [PatternBackground.standalone]).
import 'package:flutter/material.dart';

class PatternBackground extends StatelessWidget {
  const PatternBackground({
    super.key,
    required this.child,
    this.standalone = false,
  });

  final Widget child;

  /// True for the QR invite card, which brings its own base tone instead of
  /// taking the scaffold's: that card is a self-contained visual, captured
  /// via RepaintBoundary and shared as an image, so it shouldn't inherit
  /// whatever surface happens to sit behind it on screen.
  ///
  /// It still follows the theme's *brightness*, though. This used to force
  /// the card light in both themes, which broke dark mode: the card's text
  /// is drawn in the theme's own colors, so light-on-light left the address
  /// and invite code unreadable. The QR block itself is unaffected either
  /// way -- it sets its own white fill explicitly, since a scannable code
  /// needs light-background/dark-modules regardless of theme.
  final bool standalone;

  static const _pattern = AssetImage('gfx/chat_background_pattern.png');

  // The old chat_background_light.png's own dominant tone (sampled), kept
  // here so a standalone card in light mode looks exactly as it always has.
  static const _standaloneLightBase = Color(0xFFEEECEA);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final Color baseColor;
    if (standalone) {
      // The dark counterpart comes from the palette rather than a second
      // sampled constant, so the card sits in the app's own dark tones (and
      // follows the accent color the user picked) instead of a fixed grey.
      baseColor = isDark
          ? colorScheme.surfaceContainerHigh
          : _standaloneLightBase;
    } else {
      baseColor = theme.scaffoldBackgroundColor;
    }

    final patternColor =
        (isDark
                ? Color.lerp(colorScheme.primary, Colors.white, 0.7)!
                : Color.lerp(colorScheme.primary, Colors.black, 0.6)!)
            .withValues(alpha: isDark ? 0.10 : 0.06);

    // Positioned.fill (rather than Stack(fit: StackFit.expand)) so the
    // background layers stretch to match `child`'s own size instead of
    // demanding to fill the incoming constraints outright -- the chat
    // screen's usage sits inside an Expanded (bounded, so either
    // approach would work), but the QR card's usage sizes itself from
    // its content inside a scrolling Column (unbounded height), which
    // StackFit.expand can't lay out at all.
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: baseColor)),
        // The pattern is purely decorative -- IgnorePointer keeps it
        // from ever intercepting touches meant for `child` on top,
        // which the old DecorationImage approach never risked (a
        // decoration never takes part in hit-testing at all).
        Positioned.fill(
          child: IgnorePointer(
            child: Image(
              image: _pattern,
              repeat: ImageRepeat.repeat,
              color: patternColor,
              colorBlendMode: BlendMode.srcIn,
              filterQuality: FilterQuality.low,
            ),
          ),
        ),
        child,
      ],
    );
  }
}
