// First-run (or "+ add another account") screen -- a short wizard:
// 1. Server address only.
// 2. Whatever that server actually needs, discovered via GET
//    /v1/server-status (no identity required for that call): if nobody
//    has bootstrapped it yet, a one-time setup token; otherwise an invite
//    code, nothing at all, or a "registration is closed" dead end,
//    depending on the server's registration policy. Most users will
//    never see the bootstrap step -- that's for whoever stands up a
//    fresh server, which is rare by design.
// See docs/PROTOCOL.md in freizone-server, §4, for the underlying calls.
// On success the resulting AppState is persisted and handed to
// onRegistered, which owns turning it into a live session
// (AccountManager.addProfile) -- this screen doesn't know or care whether
// it's the very first account on this device or an additional one.
import 'package:flutter/material.dart';

import '../ffi/freizone_core.dart';
import '../ffi/models.dart';
import '../net/api_client.dart';
import '../state/local_state.dart';
import '../util/errors.dart';
import '../util/invite_uri.dart';
import '../util/server_url.dart';
import 'qr_scan_screen.dart';

enum _WizardStep { address, bootstrap, invite, openRegister, closed }

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.onRegistered,
    this.existingServers = const [],
    this.isAddingAccount = false,
  });

  /// Called with the newly persisted profile once registration succeeds.
  final Future<void> Function(AppState state) onRegistered;

  /// Server URLs of accounts already connected on this device -- used to
  /// warn (not block) if the address just entered matches one of them,
  /// since every registration is a brand-new, separate identity (fresh
  /// root key), never a reconnect to an existing account. Having several
  /// accounts on the same server is a legitimate, intentional setup
  /// (e.g. a personal + a work identity), so this is just a heads-up.
  final List<String> existingServers;

  /// True when pushed from the "+" button in AccountShellScreen to add
  /// another account on this device, rather than this being the very
  /// first (only) account -- just changes the title bar's wording.
  final bool isAddingAccount;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _serverController = TextEditingController();
  final _tokenController = TextEditingController();

  _WizardStep _step = _WizardStep.address;
  String? _server;
  bool _submitting = false;
  String? _error;

  /// An invite code carried by a scanned QR (lib/util/invite_uri.dart),
  /// pre-filled into the token field once _checkServer lands on the
  /// invite step. Null for a manually-typed address, an open/closed
  /// server, or a scanned code-less (open-server) QR.
  String? _scannedCode;

  @override
  void dispose() {
    _serverController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  void _goToAddressStep() {
    setState(() {
      _step = _WizardStep.address;
      _error = null;
      _scannedCode = null;
      _tokenController.clear();
    });
  }

  /// Pushes the QR scanner and, on a recognizable freizone://join result
  /// (lib/util/invite_uri.dart), fills the address field and runs the
  /// same _checkServer the "Continue" button does -- so scanning gets
  /// you to the next step without an extra tap. A QR for an unclaimed
  /// server has no meaningful code to carry (there's no setup token in
  /// this wire format), so that case just lands on the ordinary bootstrap
  /// step with the address pre-filled -- no special-casing needed.
  Future<void> _scanQr() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw == null || !mounted) return;

    final invite = parseInviteUri(raw);
    if (invite == null) {
      setState(() => _error = 'That QR code is not a Freizone invite');
      return;
    }

    _serverController.text = invite.server;
    _scannedCode = invite.code;
    await _checkServer();
  }

  Future<bool> _confirmDuplicateServer() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Account already exists here'),
        content: const Text(
          'You already have at least one account on this server. Continuing creates a new, '
          'separate account -- it does not reconnect to the existing one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue anyway'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  Future<void> _checkServer() async {
    final input = _serverController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Server address is required');
      return;
    }

    final server = normalizeServerUrl(input);
    if (widget.existingServers.any((s) => sameServer(s, server))) {
      if (!await _confirmDuplicateServer()) return;
      if (!mounted) return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final api = ApiClient(baseUrl: server, core: FreizoneCore());
    try {
      final status = await api.getServerStatus();
      setState(() {
        _server = server;
        _submitting = false;
        if (!status.claimed) {
          _step = _WizardStep.bootstrap;
        } else {
          _step = switch (status.registrationPolicy) {
            'open' => _WizardStep.openRegister,
            'invite' => _WizardStep.invite,
            _ => _WizardStep.closed,
          };
          if (_step == _WizardStep.invite && _scannedCode != null) {
            _tokenController.text = _scannedCode!;
          }
        }
      });
    } catch (e) {
      setState(() {
        _error = describeError(e);
        _submitting = false;
      });
    } finally {
      api.close();
    }
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });

    final core = FreizoneCore();
    final api = ApiClient(baseUrl: _server!, core: core);
    try {
      // The server enforces each account id's first 5 characters unique
      // per server (docs/PROTOCOL.md §1's id-prefix uniqueness note) -- a
      // fresh identity always fixes this (a new root key derives a new
      // id), so retry a few times with a new one rather than surfacing
      // what would otherwise look like an inexplicable failure. A real
      // collision is rare (up to ~1M possible prefixes per server); this
      // cap is just a defensive backstop, never expected to be hit.
      const maxIdentityAttempts = 8;
      late final Identity identity;
      var attempt = 0;
      while (true) {
        attempt++;
        final candidateIdentity = core.generateIdentity();
        final issuedAt = DateTime.now().toUtc();
        final candidateCert = core.signDeviceCertificate(
          accountId: candidateIdentity.accountId,
          deviceId: candidateIdentity.deviceId,
          devicePub: candidateIdentity.devicePub,
          issuedAt: issuedAt,
          rootPriv: candidateIdentity.rootPriv,
        );

        try {
          switch (_step) {
            case _WizardStep.bootstrap:
              await api.bootstrapClaim(
                setupToken: _tokenController.text.trim(),
                identity: candidateIdentity,
                cert: candidateCert,
              );
            case _WizardStep.invite:
              await api.registerAccount(
                identity: candidateIdentity,
                cert: candidateCert,
                inviteCode: _tokenController.text.trim(),
              );
            case _WizardStep.openRegister:
              await api.registerAccount(
                identity: candidateIdentity,
                cert: candidateCert,
              );
            case _WizardStep.address:
            case _WizardStep.closed:
              return;
          }
          identity = candidateIdentity;
          break;
        } on ApiException catch (e) {
          if (e.code == 'id_prefix_taken' && attempt < maxIdentityAttempts)
            continue;
          rethrow;
        }
      }

      final state = AppState(
        server: _server!,
        accountId: identity.accountId,
        rootPub: identity.rootPub,
        rootPriv: identity.rootPriv,
        deviceId: identity.deviceId,
        devicePub: identity.devicePub,
        devicePriv: identity.devicePriv,
      );
      await LocalStateStore.saveProfile(state);
      await widget.onRegistered(state);

      if (!mounted) return;
      // Pushed via Navigator when adding an additional account ("+" in
      // AccountShellScreen) -- pop back to it. When this is the very
      // first account on the device, this screen is the app's initial
      // route (no push happened), so there's nothing to pop; the parent
      // rebuilds away from it once onRegistered's setState runs instead.
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _error = describeError(e);
        _submitting = false;
      });
    } finally {
      api.close();
    }
  }

  Widget _buildAddressStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _serverController,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'chat.example.org',
            helperText:
                'No https:// or port needed if the server uses the standard ones',
          ),
          enabled: !_submitting,
          onSubmitted: (_) => _checkServer(),
        ),
        const SizedBox(height: 24),
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 16),
        ],
        ElevatedButton(
          onPressed: _submitting ? null : _checkServer,
          child: _submitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Continue'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _submitting ? null : _scanQr,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan QR code'),
        ),
      ],
    );
  }

  Widget _buildFinalStep() {
    final String description;
    final String? tokenLabel;
    final String buttonLabel;
    switch (_step) {
      case _WizardStep.bootstrap:
        description =
            'Nobody has set this server up yet. Enter the one-time setup token '
            'printed in its logs to become its first admin.';
        tokenLabel = 'Setup token';
        buttonLabel = 'Bootstrap';
      case _WizardStep.invite:
        description = 'This server requires an invite code to register.';
        tokenLabel = 'Invite code';
        buttonLabel = 'Register';
      case _WizardStep.openRegister:
        description =
            'This server is open for registration -- no invite needed.';
        tokenLabel = null;
        buttonLabel = 'Create account';
      case _WizardStep.closed:
        description =
            'This server has registration blocked -- no new accounts can be created '
            'right now, not even with an invite code. Ask its admin to open registration, or try '
            'a different server.';
        tokenLabel = null;
        buttonLabel = '';
      case _WizardStep.address:
        return const SizedBox();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(description),
        if (tokenLabel != null) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _tokenController,
            decoration: InputDecoration(labelText: tokenLabel),
            enabled: !_submitting,
            onSubmitted: (_) => _submit(),
          ),
        ],
        const SizedBox(height: 24),
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 16),
        ],
        if (_step != _WizardStep.closed)
          ElevatedButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(buttonLabel),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final onAddressStep = _step == _WizardStep.address;
    return PopScope(
      canPop: onAddressStep,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _goToAddressStep();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.isAddingAccount ? 'Add Account' : 'Freizone -- Setup',
          ),
          leading: onAddressStep
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _goToAddressStep,
                ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: onAddressStep ? _buildAddressStep() : _buildFinalStep(),
        ),
      ),
    );
  }
}
