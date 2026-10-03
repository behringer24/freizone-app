// Keeps forms and reading text from stretching across a tablet (APP-03).
//
// The screens were laid out for a phone, where the width is the width. On an
// iPad (or an Android tablet) the same layout runs a text field or a settings
// row across 800-1300 points, which is hard to read and looks unfinished. These
// helpers cap the width and centre what is left; below the cap -- every phone --
// nothing changes.
//
// Deliberately not applied to the chat list or the chats themselves: those are
// lists the user scans, and a later two-pane layout is the right answer for
// them on a large screen, not a narrow column.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Widest a form or a page of settings gets.
const double maxReadableWidth = 600;

/// Widest a single chat bubble gets. Three quarters of a phone is right; three
/// quarters of an iPad in landscape is a line nobody reads in one go.
const double maxBubbleWidth = 520;

/// The width cap for one chat bubble on this screen.
double bubbleMaxWidth(BuildContext context) =>
    math.min(MediaQuery.sizeOf(context).width * 0.75, maxBubbleWidth);

/// Centres [child] horizontally and caps its width at [maxWidth]. A scrollable
/// child keeps scrolling; only its column gets narrower.
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({
    super.key,
    required this.child,
    this.maxWidth = maxReadableWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}
