// Full-screen invite QR: shown to whoever can currently invite people
// (admin/moderator on an "invite" server, anyone on an "open" server --
// gated by the caller, see chat_list_screen.dart). Encodes a
// freizone://join URI (lib/util/invite_uri.dart) so the setup wizard's
// scanner can turn this screen straight into a filled-in address (and
// invite code, if present) on another device.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../state/app_session.dart';
import '../util/errors.dart';
import '../util/invite_uri.dart';
import '../widgets/qr_invite_card.dart';

class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  final _captureKey = GlobalKey();

  bool _loading = true;
  String? _error;
  String? _code;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // registrationPolicy is only fetched once at app startup
      // (AppSession.init()) -- refresh it here so an admin switching
      // open -> invite (or vice versa) without restarting the app is
      // picked up before deciding whether to mint a code.
      await widget.session.refreshRegistrationPolicy();
      if (widget.session.registrationPolicy == 'invite') {
        final invite = await widget.session.createInvite();
        _code = invite.code;
      }
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _error = describeError(e);
        _loading = false;
      });
    }
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
      final file = File('${dir.path}/freizone-invite.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());

      final server = widget.session.state.server;
      final text = _code == null
          ? 'Join me on Freizone: $server'
          : 'Join me on Freizone: $server (invite code: $_code)';

      await SharePlus.instance.share(
        ShareParams(text: text, files: [XFile(file.path)]),
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
    final server = widget.session.state.server;

    return Scaffold(
      appBar: AppBar(title: const Text('Invite')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  QrInviteCard(
                    captureKey: _captureKey,
                    title: 'Freizone Invite',
                    subtitle:
                        'Scan this with the Freizone app to join automatically.',
                    qrData: buildInviteUri(
                      server: server,
                      code: _code,
                    ).toString(),
                    addressLines: [
                      SelectableText(server, textAlign: TextAlign.center),
                      if (_code != null) ...[
                        const SizedBox(height: 4),
                        SelectableText(
                          'Invite code: $_code',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),
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
            ),
    );
  }
}
