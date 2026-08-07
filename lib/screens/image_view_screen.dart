// Full-screen view of a received/sent picture (APP-04): tapped from a chat
// bubble, dismissed with back. Built entirely from Flutter's own widgets --
// Hero for the transition from the bubble, InteractiveViewer for
// pinch-zoom and pan -- so viewing an image needs no extra dependency.
import 'dart:io';

import 'package:flutter/material.dart';

import '../util/message_actions.dart';

class ImageViewScreen extends StatelessWidget {
  const ImageViewScreen({
    super.key,
    required this.file,
    required this.heroTag,
    this.canSave = false,
  });

  final File file;

  /// Matches the bubble's Hero tag (the message id), so the picture appears
  /// to grow out of the conversation rather than replacing it abruptly.
  final String heroTag;

  /// Whether to offer saving this one to the gallery (APP-20) -- true only for
  /// a received picture, see maySavePicture. Sharing is offered either way:
  /// getting there means the file exists, and a share has no second-copy
  /// problem to avoid.
  final bool canSave;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Black regardless of theme: a photo viewer should show the photo, not
      // a surface colour competing with it.
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        // Where somebody already looking at the picture reaches for it, which
        // is why this is the first of APP-20's two routes and not the sheet.
        actions: [
          if (canSave)
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Save to gallery',
              onPressed: () => savePictureToGallery(context, file),
            ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share',
            onPressed: () => sharePicture(file),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Center(
        child: Hero(
          tag: heroTag,
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Image.file(file, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}
