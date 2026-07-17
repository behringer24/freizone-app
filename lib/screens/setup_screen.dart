// First-run screen: generate a fresh identity and either bootstrap the
// first admin account (one-time setup token, printed to the server's
// log) or self-register a new one (open/invite registration policy) --
// see docs/PROTOCOL.md in freizone-server, §4. On success the resulting
// AppState is persisted and the app moves on to ChatScreen.
import 'package:flutter/material.dart';

import '../ffi/freizone_core.dart';
import '../net/api_client.dart';
import '../state/app_session.dart';
import '../state/local_state.dart';
import '../util/errors.dart';
import 'chat_list_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _serverController = TextEditingController(text: 'http://10.0.2.2:18080');
  final _tokenController = TextEditingController();
  bool _isBootstrap = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _serverController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final server = _serverController.text.trim();
    if (server.isEmpty) {
      setState(() => _error = 'Server URL is required');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final core = FreizoneCore();
    final apiClient = ApiClient(baseUrl: server, core: core);
    try {
      final identity = core.generateIdentity();
      final issuedAt = DateTime.now().toUtc();
      final cert = core.signDeviceCertificate(
        accountId: identity.accountId,
        deviceId: identity.deviceId,
        devicePub: identity.devicePub,
        issuedAt: issuedAt,
        rootPriv: identity.rootPriv,
      );

      if (_isBootstrap) {
        await apiClient.bootstrapClaim(setupToken: _tokenController.text.trim(), identity: identity, cert: cert);
      } else {
        final invite = _tokenController.text.trim();
        await apiClient.registerAccount(identity: identity, cert: cert, inviteCode: invite.isEmpty ? null : invite);
      }

      final state = AppState(
        server: server,
        accountId: identity.accountId,
        rootPub: identity.rootPub,
        rootPriv: identity.rootPriv,
        deviceId: identity.deviceId,
        devicePub: identity.devicePub,
        devicePriv: identity.devicePriv,
      );
      await LocalStateStore.save(state);

      final session = AppSession(state);
      await session.init();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatListScreen(session: session)));
    } catch (e) {
      setState(() {
        _error = describeError(e);
        _submitting = false;
      });
    } finally {
      apiClient.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Freizone -- Setup')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _serverController,
              decoration: const InputDecoration(labelText: 'Server URL', hintText: 'http://host:18080'),
              enabled: !_submitting,
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Bootstrap admin')),
                ButtonSegment(value: false, label: Text('Register account')),
              ],
              selected: {_isBootstrap},
              onSelectionChanged: _submitting ? null : (s) => setState(() => _isBootstrap = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: _isBootstrap ? 'Setup token' : 'Invite code (optional)',
              ),
              enabled: !_submitting,
            ),
            const SizedBox(height: 24),
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 16),
            ],
            ElevatedButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_isBootstrap ? 'Bootstrap' : 'Register'),
            ),
          ],
        ),
      ),
    );
  }
}
