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
import '../ffi/freizone_core_exception.dart';
import '../ffi/models.dart';
import '../net/api_client.dart';
import '../state/local_state.dart';
import '../util/errors.dart';
import '../util/invite_uri.dart';
import '../util/server_url.dart';
import '../widgets/qr_scan_button.dart';
import 'qr_scan_screen.dart';

enum _WizardStep { address, bootstrap, invite, openRegister, closed, recover }

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
  final _seedController = TextEditingController();

  _WizardStep _step = _WizardStep.address;

  /// The post-connect step recovery was launched from, so backing out of the
  /// recovery step returns there (keeping the verified server) rather than all
  /// the way to the address entry.
  _WizardStep _recoverReturnStep = _WizardStep.address;
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
    _seedController.dispose();
    super.dispose();
  }

  void _goToAddressStep() {
    setState(() {
      _step = _WizardStep.address;
      _error = null;
      _scannedCode = null;
      _tokenController.clear();
      _seedController.clear();
    });
  }

  /// Switches to the recovery step (APP-01) from the post-connect step: the
  /// server has already been verified by _checkServer and stored in _server,
  /// so recovery is just one more option alongside register/bootstrap. Works
  /// regardless of the server's registration policy (open/invite/closed) --
  /// recovery reattaches to an account that already exists, and the server's
  /// recovery endpoint (SRV-06) doesn't gate on the policy, so it's offered
  /// even on a server with registration blocked.
  void _startRecover() {
    if (_server == null) return;
    setState(() {
      _recoverReturnStep = _step;
      _error = null;
      _step = _WizardStep.recover;
    });
  }

  /// Back navigation: from the recovery step, return to the post-connect step
  /// it was launched from (keeping the verified server); otherwise reset to
  /// the address entry.
  void _handleBack() {
    if (_step == _WizardStep.recover) {
      setState(() {
        _step = _recoverReturnStep;
        _error = null;
        _seedController.clear();
      });
      return;
    }
    _goToAddressStep();
  }

  /// Fills the seed field from a scanned recovery-phrase QR (as produced by
  /// the backup screen -- the raw QR content is just the space-joined words).
  Future<void> _scanSeedQr() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw == null || !mounted) return;
    setState(() {
      _seedController.text = raw.trim();
      _error = null;
    });
  }

  Future<void> _submitRecover() async {
    final phrase = _seedController.text.trim();
    if (phrase.isEmpty) {
      setState(() => _error = 'Enter your recovery phrase');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final core = FreizoneCore();
    final api = ApiClient(baseUrl: _server!, core: core);
    try {
      final words = phrase
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();

      final Identity identity;
      try {
        identity = core.restoreIdentityFromSeed(words);
      } on FreizoneCoreException catch (e) {
        setState(() {
          _error = 'That recovery phrase is not valid (${e.message}).';
          _submitting = false;
        });
        return;
      }

      final cert = core.signDeviceCertificate(
        accountId: identity.accountId,
        deviceId: identity.deviceId,
        devicePub: identity.devicePub,
        issuedAt: DateTime.now().toUtc(),
        rootPriv: identity.rootPriv,
      );
      await api.recoverAccount(identity: identity, cert: cert);

      final state = AppState(
        server: _server!,
        accountId: identity.accountId,
        rootPub: identity.rootPub,
        rootPriv: identity.rootPriv,
        deviceId: identity.deviceId,
        devicePub: identity.devicePub,
        devicePriv: identity.devicePriv,
        // The user just restored from the phrase, so they already have it --
        // no post-setup backup nudge for a recovered account.
        recoveryBackupDone: true,
      );
      await LocalStateStore.saveProfile(state);
      await widget.onRegistered(state);

      if (!mounted) return;
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() {
        // A 404 from the recovery endpoint means no account for this phrase
        // exists on this server -- recovery only re-attaches a device to an
        // account that still exists, so a deleted account can't be restored.
        _error = e.statusCode == 404
            ? 'No account for this recovery phrase exists on this server. '
                  'If the account was deleted it cannot be restored. If you '
                  'are recovering after losing a device, check that the server '
                  'address is correct.'
            : describeError(e);
        _submitting = false;
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
            case _WizardStep.recover:
              return;
          }
          identity = candidateIdentity;
          break;
        } on ApiException catch (e) {
          if (e.code == 'id_prefix_taken' && attempt < maxIdentityAttempts) {
            continue;
          }
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
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: _serverController,
                decoration: const InputDecoration(
                  labelText: 'Server address',
                  hintText: 'chat.example.org',
                ),
                enabled: !_submitting,
                onSubmitted: (_) => _checkServer(),
              ),
            ),
            const SizedBox(width: 12),
            QrScanButton(onPressed: _submitting ? null : _scanQr),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'No https:// or port needed if the server uses the standard ones',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
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
      ],
    );
  }

  Widget _buildRecoverStep() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Restore an account you already have on this server using its '
          '24-word recovery phrase. This keeps your existing address; it does '
          'not create a new account.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Your other devices for this account will be signed out. Chat history '
          'is not restored -- only your identity.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _seedController,
          decoration: const InputDecoration(
            labelText: 'Recovery phrase',
            hintText: '24 words separated by spaces',
            border: OutlineInputBorder(),
          ),
          enabled: !_submitting,
          minLines: 3,
          maxLines: 5,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _submitting ? null : _scanSeedQr,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR instead'),
          ),
        ),
        const SizedBox(height: 16),
        if (_error != null) ...[
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 16),
        ],
        ElevatedButton(
          onPressed: _submitting ? null : _submitRecover,
          child: _submitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Recover account'),
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
      case _WizardStep.recover:
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
        // Recovery is offered here regardless of registration policy -- even a
        // server with registration blocked can still recover an existing
        // account (the server's recovery endpoint doesn't gate on the policy).
        const SizedBox(height: 8),
        TextButton(
          onPressed: _submitting ? null : _startRecover,
          child: const Text('Recover an existing account'),
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
        if (!didPop) _handleBack();
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
                  onPressed: _handleBack,
                ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: switch (_step) {
            _WizardStep.address => _buildAddressStep(),
            _WizardStep.recover => _buildRecoverStep(),
            _ => _buildFinalStep(),
          },
        ),
      ),
    );
  }
}
