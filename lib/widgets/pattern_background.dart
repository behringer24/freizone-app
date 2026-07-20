// Shared decorative background: a transparent line-art pattern
// (gfx/chat_background_pattern.png -- chat bubbles, servers, cranes,
// hearts, network nodes) tinted at runtime and laid over a solid base
// color, instead of two separate pre-baked full-color images. Dark mode
// lightens the pattern, light mode darkens it, and the tint itself is
// derived from the app's own teal accent -- so the background always
// reads as "this app's colors", not a fixed neutral tone baked into a
// PNG. Used behind the chat message list (chat_screen.dart, follows the
// current theme) and inside the QR invite card (qr_invite_card.dart,
// forced to always look light regardless of theme -- that card is its
// own self-contained visual, see its own header comment).
import 'package:flutter/material.dart';

class PatternBackground extends StatelessWidget {
  const PatternBackground({
    super.key,
    required this.child,
    this.forceLight = false,
  });

  final Widget child;

  /// True for the QR invite card -- it should always look light
  /// regardless of the app's current theme, rather than following
  /// Theme.of(context).brightness like the chat background does.
  final bool forceLight;

  static const _pattern = AssetImage('gfx/chat_background_pattern.png');

  // The old chat_background_light.png's own dominant tone (sampled),
  // kept here so the QR card's forced-light look stays visually
  // consistent with what it already looked like.
  static const _forcedLightBase = Color(0xFFEEECEA);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark =
        !forceLight && Theme.of(context).brightness == Brightness.dark;

    final baseColor = forceLight
        ? _forcedLightBase
        : Theme.of(context).scaffoldBackgroundColor;

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
