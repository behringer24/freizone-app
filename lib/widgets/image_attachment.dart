// Renders one image attachment inside a chat bubble (APP-04).
//
// The picture arrives in two stages: a tiny preview thumbnail comes inside
// the message itself, while the full image is a separate encrypted blob
// fetched afterwards. This widget shows whatever is available and upgrades
// itself when the download lands, without the transcript ever jumping --
// the sender's pixel dimensions let it reserve the right aspect ratio from
// the very first frame.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../screens/image_view_screen.dart';
import '../state/conversation.dart';
import '../state/media_store.dart';
import '../state/app_session.dart';

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
  MediaStore? _media;
  File? _file;
  File? _thumb;
  bool _resolving = true;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void dispose() {
    _media?.removeListener(_onFetchStateChanged);
    super.dispose();
  }

  /// A download this widget did not start has finished, failed, or begun --
  /// most often the prefetch AppSession fires when a picture arrives, which
  /// means [AppSession.ensureAttachmentDownloaded] answers our own call with
  /// null because an attempt is already in flight. Without listening, the
  /// spinner would then spin until the bubble was rebuilt from scratch.
  ///
  /// Deliberately does not start a download of its own, so this can never
  /// loop: [_resolve] marks the fetch and would notify us straight back.
  void _onFetchStateChanged() {
    final media = _media;
    if (!mounted || media == null || _file != null) return;
    if (media.stateFor(widget.message.id) == MediaFetchState.downloading) {
      // Nothing to adopt yet; rebuild so the spinner replaces a retry overlay
      // if that is what was showing.
      setState(() {});
      return;
    }
    unawaited(_adoptDownloadedFile());
  }

  /// Re-reads the disk after somebody else's download settled.
  Future<void> _adoptDownloadedFile() async {
    final media = _media;
    if (media == null) return;
    final full = media.fileFor(
      accountId: widget.session.state.accountId,
      chatId: widget.chatId,
      messageId: widget.message.id,
    );
    final exists = await full.exists();
    if (!mounted) return;
    setState(() {
      if (exists) _file = full;
    });
  }

  /// Looks for the already-downloaded file, falls back to the thumbnail, and
  /// starts a download if neither the full file nor an in-flight attempt
  /// exists yet.
  Future<void> _resolve({bool force = false}) async {
    final media = await MediaStore.instance();
    if (!mounted) return;
    // Attached before anything is awaited below, so a download that finishes
    // while we are still stat-ing files is not missed.
    if (_media != media) {
      _media?.removeListener(_onFetchStateChanged);
      media.addListener(_onFetchStateChanged);
    }

    final full = media.fileFor(
      accountId: widget.session.state.accountId,
      chatId: widget.chatId,
      messageId: widget.message.id,
    );
    final thumb = media.thumbFor(
      accountId: widget.session.state.accountId,
      chatId: widget.chatId,
      messageId: widget.message.id,
    );
    final haveFull = await full.exists();
    final haveThumb = await thumb.exists();
    if (!mounted) return;

    setState(() {
      _media = media;
      _file = haveFull ? full : null;
      _thumb = haveThumb ? thumb : null;
      _resolving = false;
    });

    if (haveFull) return;
    // Our own sent picture with no local file left: the blob belongs to the
    // recipient's device, so there is nothing we could fetch back. Retrying
    // would only ever 404, so don't offer it.
    if (widget.message.mine) return;
    // A previous failure isn't retried on its own -- the user taps to retry,
    // so a dead server can't turn into a silent loop.
    if (!force && media.stateFor(widget.message.id) == MediaFetchState.failed) {
      return;
    }
    final downloaded = await widget.session.ensureAttachmentDownloaded(
      chatId: widget.chatId,
      message: widget.message,
    );
    if (!mounted || downloaded == null) return;
    setState(() => _file = downloaded);
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
            builder: (_) => ImageViewScreen(file: file, heroTag: widget.message.id),
          ),
        ),
        child: Hero(
          tag: widget.message.id,
          child: Image.file(file, fit: BoxFit.cover),
        ),
      );
    }

    final media = _media;
    final failed =
        media != null && media.stateFor(widget.message.id) == MediaFetchState.failed;

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
        if (widget.message.mine)
          // Nothing to fetch back (see ensureAttachmentDownloaded), so say
          // so instead of spinning or offering a retry that cannot work.
          const _GoneOverlay()
        else if (failed)
          _RetryOverlay(onTap: () => _resolve(force: true))
        else if (!_resolving)
          // Sized against the bubble rather than fixed: at 28px a short or
          // narrow picture's placeholder was almost entirely spinner, which
          // filled the rounded clip and read as a square.
          LayoutBuilder(
            builder: (context, constraints) {
              final shortest = constraints.biggest.shortestSide;
              final diameter = (shortest * 0.35).clamp(14.0, 28.0);
              return Center(
                child: SizedBox(
                  width: diameter,
                  height: diameter,
                  child: CircularProgressIndicator(
                    strokeWidth: diameter / 11,
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// A picture we sent whose local copy is gone. Not recoverable: the blob is
/// owned by the recipient's device.
class _GoneOverlay extends StatelessWidget {
  const _GoneOverlay();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.45),
      child: const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'Picture no longer on this device',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
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
