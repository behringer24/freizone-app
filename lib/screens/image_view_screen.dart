// Full-screen view of a received/sent picture (APP-04): tapped from a chat
// bubble, dismissed with back. Built entirely from Flutter's own widgets --
// Hero for the transition from the bubble, InteractiveViewer for
// pinch-zoom and pan -- so viewing an image needs no extra dependency.
import 'dart:io';

import 'package:flutter/material.dart';

class ImageViewScreen extends StatelessWidget {
  const ImageViewScreen({super.key, required this.file, required this.heroTag});

  final File file;

  /// Matches the bubble's Hero tag (the message id), so the picture appears
  /// to grow out of the conversation rather than replacing it abruptly.
  final String heroTag;

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
