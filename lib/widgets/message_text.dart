// A message's text with its links made tappable (APP-14).
//
// Falls back to a plain [Text] when there is nothing to link, which is the
// common case -- so the overwhelming majority of bubbles keep exactly the
// widget they had before.
//
// Taps are claimed by the individual link spans; a long-press anywhere,
// including on a link, still reaches the bubble's own GestureDetector and
// opens the message actions sheet. That split is deliberate: the actions
// sheet must stay reachable from every part of a message.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../util/link_detection.dart';

class MessageText extends StatefulWidget {
  const MessageText({
    super.key,
    required this.text,
    required this.style,
    required this.onOpenLink,
    required this.onOpenAddress,
  });

  final String text;

  /// The bubble's own text style, so linkified text keeps the size and colour
  /// the plain [Text] would have had.
  final TextStyle style;

  /// Called for a web or email link -- expected to confirm before opening
  /// (see confirmAndOpenLink).
  final void Function(LinkSpan span) onOpenLink;

  /// Called for a Freizone `id*server` address. Handled in-app; must not
  /// touch the network on its own (APP-14).
  final void Function(LinkSpan span) onOpenAddress;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  List<LinkSpan> _spans = const [];

  /// Recognizers own native resources, so they are built once per detected
  /// span and disposed with the widget rather than recreated on every build.
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    _detect();
  }

  @override
  void didUpdateWidget(MessageText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _detect();
  }

  void _detect() {
    _disposeRecognizers();
    _spans = detectLinks(widget.text);
    for (final span in _spans) {
      _recognizers.add(
        TapGestureRecognizer()
          ..onTap = () => span.kind == LinkKind.freizoneAddress
              ? widget.onOpenAddress(span)
              : widget.onOpenLink(span),
      );
    }
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_spans.isEmpty) {
      return Text(widget.text, style: widget.style);
    }

    // Underlined as well as coloured, not coloured alone: an own message sits
    // on colorScheme.primary and a peer's on surfaceContainerHighest, so no
    // single accent carries on both -- and an underline is the more
    // accessible signal regardless of contrast.
    final linkStyle = widget.style.copyWith(
      decoration: TextDecoration.underline,
      decorationColor: widget.style.color,
      fontWeight: FontWeight.bold,
    );

    final children = <InlineSpan>[];
    var cursor = 0;
    for (var i = 0; i < _spans.length; i++) {
      final span = _spans[i];
      if (span.start > cursor) {
        children.add(
          TextSpan(text: widget.text.substring(cursor, span.start)),
        );
      }
      children.add(
        TextSpan(
          text: span.text,
          style: linkStyle,
          recognizer: _recognizers[i],
        ),
      );
      cursor = span.end;
    }
    if (cursor < widget.text.length) {
      children.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return Text.rich(TextSpan(style: widget.style, children: children));
  }
}
