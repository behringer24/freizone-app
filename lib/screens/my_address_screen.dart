// Full-screen "my address" QR: the sharing side of the chat-invite
// feature. Encodes a freizone://chat URI (lib/util/invite_uri.dart) --
// unlike invite_screen.dart's join invite, this always uses the full
// account id (never the short prefix), since a scanned QR needs no
// typing convenience and the point is an address that resolves
// unambiguously without relying on prefix uniqueness. The optional name
// field is a local, ephemeral suggestion for the recipient's new-chat
// display name -- nothing here persists it.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../state/app_session.dart';
import '../util/errors.dart';
import '../util/freizone_address.dart';
import '../util/invite_uri.dart';
import '../widgets/qr_invite_card.dart';

class MyAddressScreen extends StatefulWidget {
  const MyAddressScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<MyAddressScreen> createState() => _MyAddressScreenState();
}

class _MyAddressScreenState extends State<MyAddressScreen> {
  final _captureKey = GlobalKey();
  final _nameController = TextEditingController();
  bool _sharing = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String get _address => buildFreizoneAddress(
    id: widget.session.state.accountId,
    server: widget.session.state.server,
  );

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _address));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Address copied to clipboard')));
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      final boundary =
          _captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/freizone-chat-invite.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());

      await SharePlus.instance.share(
        ShareParams(
          text: 'Chat with me on Freizone: $_address',
          files: [XFile(file.path)],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: ${describeError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Invite to chat')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            QrInviteCard(
              captureKey: _captureKey,
              title: 'My Freizone Address',
              subtitle: 'Scan this with the Freizone app to start a chat with me.',
              qrData: buildChatInviteUri(
                id: widget.session.state.accountId,
                server: widget.session.state.server,
                name: _nameController.text,
              ).toString(),
              addressLines: [
                SelectableText(_address, textAlign: TextAlign.center),
              ],
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Suggest a name (optional)',
                helperText:
                    'Shown as the default chat name for whoever scans this',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
                const SizedBox(width: 16),
                FilledButton.icon(
                  onPressed: _sharing ? null : _share,
                  icon: _sharing
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.share),
                  label: const Text('Share'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
