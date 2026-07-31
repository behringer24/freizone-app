// The sheet shown before a link from a message is opened (APP-14).
//
// Why confirm at all, when most messengers don't: in Freizone a stranger can
// send the first message, and the first thing they might send is a link. One
// extra tap is a fair price for showing where it actually goes -- especially
// the host, on its own, since that is the part that decides who you are
// talking to and the part a long URL hides.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../util/link_detection.dart';

/// Confirms and then opens [span]. Shows a SnackBar via [context] if the
/// platform has nothing registered to handle it.
Future<void> confirmAndOpenLink(BuildContext context, LinkSpan span) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _LinkConfirmSheet(span: span),
  );
  if (action == null || !context.mounted) return;

  if (action == 'copy') {
    await Clipboard.setData(ClipboardData(text: span.text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Link copied')));
    return;
  }

  final uri = Uri.tryParse(span.target);
  // Re-checked here rather than trusted from detection: this is the last
  // point before the OS is handed a URI, and the allowlist is the whole
  // defence against javascript:, data:, file:, content: and intent://.
  if (uri == null || !_launchableSchemes.contains(uri.scheme.toLowerCase())) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("That link can't be opened safely")),
    );
    return;
  }

  try {
    // externalApplication, never an in-app webview: the user's own browser
    // has their own protections, and we stay out of the business of being one.
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No app on this device can open that')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Couldn't open that link")));
    }
  }
}

const _launchableSchemes = {'http', 'https', 'mailto'};

class _LinkConfirmSheet extends StatelessWidget {
  const _LinkConfirmSheet({required this.span});

  final LinkSpan span;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final uri = Uri.tryParse(span.target);
    final isEmail = span.kind == LinkKind.email;
    final host = uri?.host ?? '';
    final insecure = uri?.scheme.toLowerCase() == 'http';
    // A host outside plain ASCII may be a genuine internationalised domain --
    // or a lookalike: "аpple.com" with a Cyrillic "а" is pixel-identical to
    // the real thing. We flag it rather than converting to punycode, which
    // would mean a dependency for a warning we can give anyway.
    final confusable = host.runes.any((r) => r > 127);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isEmail ? 'Write to this address?' : 'Open this link?',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            if (!isEmail && host.isNotEmpty) ...[
              Text(
                'Goes to',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              // The host gets its own line and weight: in a long URL it is
              // the one part worth reading, and the one part that is easy to
              // lose track of.
              SelectableText(
                host,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 12),
            ],
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: SelectableText(
                  span.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            if (confusable) ...[
              const SizedBox(height: 12),
              _Warning(
                icon: Icons.warning_amber,
                color: colorScheme.error,
                text:
                    'This address contains characters outside the normal Latin '
                    'set. They can look identical to ordinary letters — check '
                    'carefully that this is the site you expect.',
              ),
            ],
            if (insecure) ...[
              const SizedBox(height: 12),
              _Warning(
                icon: Icons.no_encryption_gmailerrorred,
                color: colorScheme.onSurfaceVariant,
                text:
                    'Unencrypted connection (http). Anyone on the network can '
                    'read and alter what this page sends.',
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pop('copy'),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop('open'),
                  child: Text(isEmail ? 'Write' : 'Open'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
