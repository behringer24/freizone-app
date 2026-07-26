// Shows an account's 24-word recovery phrase (APP-01) so the user can back it
// up. The phrase encodes the identity root key: with it, the account can be
// restored on any device from the setup screen's "Recover an existing account"
// flow -- and anyone else who has it can take the account over, so this screen
// warns loudly, blocks screenshots (FLAG_SECURE), and auto-clears the
// clipboard after a copy.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../ffi/freizone_core.dart';
import '../util/errors.dart';
import '../util/secure_screen.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.rootPriv});

  /// The account's 64-byte Ed25519 root private key (AppState.rootPriv). Its
  /// 32-byte seed is what the phrase encodes.
  final Uint8List rootPriv;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  List<String>? _words;
  String? _error;
  bool _revealed = false;
  bool _showQr = false;
  Timer? _clipboardTimer;

  static const _clipboardClearDelay = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    enableSecureScreen();
    try {
      _words = FreizoneCore().revealRecoveryPhrase(widget.rootPriv);
    } catch (e) {
      _error = describeError(e);
    }
  }

  @override
  void dispose() {
    _clipboardTimer?.cancel();
    disableSecureScreen();
    super.dispose();
  }

  String get _phrase => _words!.join(' ');

  Future<void> _copy() async {
    final phrase = _phrase;
    await Clipboard.setData(ClipboardData(text: phrase));
    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(_clipboardClearDelay, () async {
      // Only wipe it if it's still our phrase -- don't clobber whatever the
      // user copied in the meantime.
      final current = await Clipboard.getData('text/plain');
      if (current?.text == phrase) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Recovery phrase copied. Clipboard clears in 60 seconds.'),
      ),
    );
  }

  Future<void> _share() async {
    try {
      await SharePlus.instance.share(ShareParams(text: _phrase));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: ${describeError(e)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery phrase')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: theme.colorScheme.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Anyone with these 24 words can restore and take over your '
                      'account. Write them down and keep them somewhere safe and '
                      'offline. Nobody -- not even your server -- can recover them '
                      'for you if you lose them.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Text(_error!, style: TextStyle(color: theme.colorScheme.error))
          else if (!_revealed)
            ElevatedButton.icon(
              onPressed: () => setState(() => _revealed = true),
              icon: const Icon(Icons.visibility),
              label: const Text('Show recovery phrase'),
            )
          else ...[
            _buildWordGrid(theme),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _showQr = !_showQr),
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(_showQr ? 'Hide QR' : 'Show QR'),
                ),
                OutlinedButton.icon(
                  onPressed: _share,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share'),
                ),
              ],
            ),
            if (_showQr) ...[
              const SizedBox(height: 24),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.white,
                  child: QrImageView(
                    data: _phrase,
                    size: 240,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Scanning this QR reveals your full recovery phrase -- treat it '
                'like the words themselves.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildWordGrid(ThemeData theme) {
    final words = _words!;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: words.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 4.5,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemBuilder: (context, i) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '${i + 1}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  words[i],
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
