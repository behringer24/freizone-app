// Shared "scan a Freizone QR code" entry point -- a single teal, square
// button used everywhere a text field can alternatively be filled in by
// scanning (the setup wizard's server-address step, the new-chat sheet's
// peer-address field), instead of each screen inventing its own
// placement/size/color for the same action. Sized to match a standard
// Material text field's own box height (56dp) -- level with the
// label-plus-input it sits beside, not taller than it.
import 'package:flutter/material.dart';

class QrScanButton extends StatelessWidget {
  const QrScanButton({
    super.key,
    required this.onPressed,
    this.tooltip = 'Scan a Freizone QR code',
  });

  final VoidCallback? onPressed;
  final String tooltip;

  static const double size = 56;

  @override
  Widget build(BuildContext context) {
    final teal = Theme.of(context).colorScheme.primary;
    final disabled = onPressed == null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: disabled ? teal.withValues(alpha: 0.4) : teal,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              Icons.qr_code_scanner,
              color: Theme.of(context).colorScheme.onPrimary,
              size: 26,
            ),
          ),
        ),
      ),
    );
  }
}
