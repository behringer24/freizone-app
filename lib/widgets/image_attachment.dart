// Renders one image attachment inside a chat bubble (APP-04).
//
// The picture arrives in two stages: a tiny preview thumbnail comes inside
// the message itself, while the full image is a separate encrypted blob
// fetched afterwards. This widget shows whatever is available and upgrades
// itself when the download lands, without the transcript ever jumping --
// the sender's pixel dimensions let it reserve the right aspect ratio from
// the very first frame.
//
// Fetching goes entirely through the core now (SRV-23, the cut): a
// StoredMessage built from core_bridge.dart carries no decryption key --
// deliberately, see its own doc comment -- so this widget has nothing to
// decrypt with any more even if it wanted to. CoreAccount.attachmentPath
// answers with a path, downloading first if it has not been downloaded,
// which folds what used to be three separate concerns here (has it arrived,
// where do I write it, how do I open it) into one call.
//
// Traded away deliberately: MediaStore's cross-widget fetch-state broadcast,
// which let two bubbles for the same picture (two accounts in the same
// group, most often) share one in-flight download and notify each other when
// it landed. Each bubble now resolves its own call independently -- simpler,
// and correct either way, just not shared; a second concurrent call for the
// same picture cannot corrupt anything, only cost a redundant round trip.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../screens/image_view_screen.dart';
import '../state/conversation.dart';
import '../state/app_session.dart';
import '../util/message_actions.dart';

class ImageAttachment extends StatefulWidget {
  const ImageAttachment({
    super.key,
    required this.session,
    required this.chatId,
    required this.message,
  });

  final AppSession session;

  /// The chat this picture belongs to -- a peer's account id for a one-to-one
  /// conversation, a group id for a group. It only ever names the directory
  /// the file lives in, so both work unchanged.
  final String chatId;
  final StoredMessage message;

  @override
  State<ImageAttachment> createState() => _ImageAttachmentState();
}

class _ImageAttachmentState extends State<ImageAttachment> {
  File? _file;
  File? _thumb;
  bool _resolving = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  /// Re-resolves when the widget is rebuilt for a *different* message (a
  /// reused list item) rather than the same one settling -- the guard that
  /// used to live here existed only to adopt a MediaStore notification, which
  /// no longer applies now that each widget resolves its own call.
  @override
  void didUpdateWidget(ImageAttachment oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id ||
        oldWidget.chatId != widget.chatId) {
      _file = null;
      _thumb = null;
      _failed = false;
      unawaited(_resolve());
    }
  }

  /// Fetches the thumbnail (a local lookup, always worth trying, see
  /// [CoreAccount.attachmentPath]) and the full picture (which may download),
  /// in that order so the blurred preview can appear before the real file
  /// does. [force] re-tries after a failure the user tapped to retry.
  Future<void> _resolve({bool force = false}) async {
    if (!force && _failed) return;
    if (mounted) {
      setState(() {
        _resolving = true;
        _failed = false;
      });
    }

    try {
      final thumbPath = await widget.session.coreAccount.attachmentPath(
        widget.chatId,
        widget.message.id,
        thumb: true,
      );
      if (mounted && thumbPath.isNotEmpty) {
        setState(() => _thumb = File(thumbPath));
      }
    } catch (_) {
      // A missing thumbnail costs a preview, never the picture.
    }

    try {
      final path = await widget.session.coreAccount.attachmentPath(
        widget.chatId,
        widget.message.id,
      );
      if (!mounted) return;
      setState(() {
        _resolving = false;
        if (path.isNotEmpty) _file = File(path);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.message.attachments.first;
    if (!attachment.isImage) return const _UnsupportedAttachment();

    // Reserve the final shape immediately: without this the bubble would
    // resize when the image lands and shove the transcript around.
    final aspect = attachment.width > 0 && attachment.height > 0
        ? attachment.width / attachment.height
        : 4 / 3;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260, maxHeight: 320),
      child: AspectRatio(
        aspectRatio: aspect,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: _content(context),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final file = _file;
    if (file != null) {
      return GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ImageViewScreen(
              file: file,
              heroTag: widget.message.id,
              canSave: maySavePicture(widget.message),
            ),
          ),
        ),
        child: Hero(
          tag: widget.message.id,
          child: Image.file(file, fit: BoxFit.cover),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_thumb != null)
          // Blurred, so the low-resolution preview reads as a placeholder
          // rather than looking like a broken picture.
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Image.file(_thumb!, fit: BoxFit.cover),
          )
        else
          ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest),
        if (_failed)
          _RetryOverlay(onTap: () => unawaited(_resolve(force: true)))
        else if (!_resolving)
          // Nothing to show yet and nothing failed: an attachment record
          // exists but the blob hasn't reached us yet -- legitimate and
          // brief, resolved by the next poll's refresh rebuilding this
          // widget, not by anything it does itself.
          const SizedBox.shrink()
        else
          // A fixed size, deliberately, where this used to measure itself
          // against the bubble with a LayoutBuilder.
          //
          // LayoutBuilder cannot answer an intrinsic-dimension query at all,
          // and this widget goes inside a bubble that asks one: the group
          // transcript wraps its column in IntrinsicWidth so a bubble hugs its
          // text. The query walks ConstrainedBox -> AspectRatio (which, given
          // unbounded height, delegates to its child) -> Stack -> here, and
          // every message in that transcript stopped being painted -- with no
          // error anywhere, which is what made it expensive to find.
          //
          // The old sizing existed so a small picture's placeholder was not
          // almost entirely spinner. 22px keeps that within a rounded clip of
          // any size this widget is given, which is a fair trade for a
          // placeholder that is on screen for a moment.
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}

class _RetryOverlay extends StatelessWidget {
  const _RetryOverlay({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh, color: Colors.white),
              SizedBox(height: 4),
              Text(
                'Tap to retry',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A kind this build doesn't know how to render (a video or audio clip from
/// a newer app). Shown rather than dropped, so the message doesn't look
/// mysteriously empty.
class _UnsupportedAttachment extends StatelessWidget {
  const _UnsupportedAttachment();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            'Attachment not supported yet',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
