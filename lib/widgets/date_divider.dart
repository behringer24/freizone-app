import 'package:flutter/material.dart';

/// The pill between two days of a transcript.
///
/// Shared by the one-to-one and group screens so the two cannot drift apart --
/// see util/chat_time.dart, which supplies the label.
class DateDivider extends StatelessWidget {
  const DateDivider({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }
}
