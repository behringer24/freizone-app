// App-wide preferences (not tied to any one account) -- theme, accent
// color, the default for "copy my address", and notification sound/
// vibration. See lib/state/app_settings.dart for persistence.
import 'package:flutter/material.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../state/account_manager.dart';
import '../state/app_settings.dart';
import '../util/share_shortcuts.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.manager,
  });

  final AppSettings settings;

  /// Needed only to re-trigger push registration on every live account
  /// immediately after the user changes [PushPreference] below, rather
  /// than waiting for the next app start.
  final AccountManager manager;

  Future<void> _setPushPreference(PushPreference value) async {
    await settings.setPushPreference(value);
    for (final session in manager.sessions) {
      await session.reregisterPush();
    }
  }

  /// Acts on the flag immediately rather than waiting for the next resume:
  /// turning this off is a privacy decision, so the already-published names
  /// have to go away now, not eventually (APP-15).
  Future<void> _setDirectShareEnabled(bool value) async {
    await settings.setDirectShareEnabled(value);
    await syncShareShortcuts(manager, settings);
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          return ListView(
            children: [
              _sectionTitle(context, 'Appearance'),
              RadioGroup<ThemeMode>(
                groupValue: settings.themeMode,
                onChanged: (mode) {
                  if (mode != null) settings.setThemeMode(mode);
                },
                child: Column(
                  children: const [
                    RadioListTile<ThemeMode>(
                      value: ThemeMode.system,
                      title: Text('Follow system'),
                    ),
                    RadioListTile<ThemeMode>(
                      value: ThemeMode.light,
                      title: Text('Light'),
                    ),
                    RadioListTile<ThemeMode>(
                      value: ThemeMode.dark,
                      title: Text('Dark'),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('Accent color'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final preset in AccentPreset.values)
                      _AccentSwatch(
                        preset: preset,
                        selected: settings.accentPreset == preset,
                        onTap: () => settings.setAccentPreset(preset),
                      ),
                  ],
                ),
              ),
              const Divider(height: 32),
              _sectionTitle(context, 'Addresses'),
              SwitchListTile(
                title: const Text('Copy short address by default'),
                subtitle: const Text(
                  'Use the 5-character id prefix instead of the full id for "Copy my address"',
                ),
                value: settings.copyIdShort,
                onChanged: settings.setCopyIdShort,
              ),
              const Divider(height: 32),
              _sectionTitle(context, 'Push delivery'),
              RadioGroup<PushPreference>(
                groupValue: settings.pushPreference,
                onChanged: (pref) {
                  if (pref != null) _setPushPreference(pref);
                },
                child: Column(
                  children: [
                    for (final pref in PushPreference.values)
                      RadioListTile<PushPreference>(
                        value: pref,
                        title: Text(pref.label),
                      ),
                  ],
                ),
              ),
              // The distributor only matters when UnifiedPush is in play --
              // hidden when FCM is forced, since it wouldn't be used then.
              if (settings.pushPreference != PushPreference.forceFcm)
                _PushDistributorTile(manager: manager),
              const Divider(height: 32),
              _sectionTitle(context, 'Notifications'),
              SwitchListTile(
                title: const Text('Sound'),
                value: settings.notificationSound,
                onChanged: settings.setNotificationSound,
              ),
              SwitchListTile(
                title: const Text('Vibration'),
                value: settings.notificationVibration,
                onChanged: settings.setNotificationVibration,
              ),
              const Divider(height: 32),
              _sectionTitle(context, 'Privacy'),
              SwitchListTile(
                title: const Text('Read receipts'),
                subtitle: const Text(
                  'Reciprocal: turning this off also stops you from seeing '
                  'whether the people you message have read theirs',
                ),
                value: settings.readReceiptsEnabled,
                onChanged: settings.setReadReceiptsEnabled,
              ),
              const Divider(height: 32),
              _sectionTitle(context, 'Chat'),
              SwitchListTile(
                title: const Text('Send with Enter'),
                subtitle: const Text(
                  'When on, Enter sends the message. With an external '
                  'keyboard, Shift+Enter still inserts a line break. When '
                  'off, Enter inserts a line break and you send with the '
                  'button.',
                ),
                value: settings.enterSendsMessage,
                onChanged: settings.setEnterSendsMessage,
              ),
              SwitchListTile(
                title: const Text('Offer chats when sharing'),
                subtitle: const Text(
                  'Off by default. Turn this on to let other apps share '
                  'straight into a specific chat, so your recent contacts '
                  'appear in the system share sheet itself. Their names and '
                  'avatars have to be handed to Android for that — the one '
                  'place Freizone passes contact details outside the app. '
                  'Switching it back off removes them again. Sharing into '
                  'Freizone works either way; without this you pick the chat '
                  'afterwards.',
                ),
                value: settings.directShareEnabled,
                onChanged: _setDirectShareEnabled,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final AccentPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: preset.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: preset.color,
            border: selected
                ? Border.all(
                    color: Theme.of(context).colorScheme.onSurface,
                    width: 3,
                  )
                : null,
          ),
          child: selected ? const Icon(Icons.check, color: Colors.white) : null,
        ),
      ),
    );
  }
}

/// Lets the user pick which installed UnifiedPush distributor delivers push
/// for this device. Shown only while UnifiedPush is in play (see
/// SettingsScreen.build). The selection is persisted by the plugin
/// (`saveDistributor`); changing it re-registers every live account so each
/// account's server learns the new endpoint (the distributor is device-wide,
/// but the server-side registration is per account).
class _PushDistributorTile extends StatefulWidget {
  const _PushDistributorTile({required this.manager});

  final AccountManager manager;

  @override
  State<_PushDistributorTile> createState() => _PushDistributorTileState();
}

class _PushDistributorTileState extends State<_PushDistributorTile> {
  List<String>? _available;
  String? _current;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final available = await UnifiedPush.getDistributors();
    final current = await UnifiedPush.getDistributor();
    if (!mounted) return;
    setState(() {
      _available = available;
      _current = current;
      _loading = false;
    });
  }

  Future<void> _choose(String distributor) async {
    await UnifiedPush.saveDistributor(distributor);
    // Re-register every account so each server gets the new push endpoint --
    // same "all sessions" rule as a push-preference change.
    for (final session in widget.manager.sessions) {
      await session.reregisterPush();
    }
    if (!mounted) return;
    setState(() => _current = distributor);
  }

  // A friendly name for the common distributors; falls back to the package
  // id for anything else (resolving the real app label would need a
  // PackageManager round-trip we don't otherwise take).
  String _label(String pkg) => switch (pkg) {
    'io.heckel.ntfy' => 'ntfy',
    'org.unifiedpush.distributor.nextpush' => 'NextPush',
    'org.unifiedpush.distributor.fcm' => 'Embedded (FCM-backed)',
    _ => pkg,
  };

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ListTile(
        title: Text('Push distributor'),
        subtitle: Text('Checking installed apps…'),
      );
    }
    final available = _available ?? const <String>[];
    if (available.isEmpty) {
      return const ListTile(
        title: Text('Push distributor'),
        subtitle: Text(
          'No UnifiedPush app installed. Install one (e.g. ntfy), or use '
          'Firebase (FCM) above.',
        ),
      );
    }
    final current = _current;
    return ListTile(
      title: const Text('Push distributor'),
      subtitle: Text(
        current == null || current.isEmpty ? 'None selected' : _label(current),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showPicker(available),
    );
  }

  Future<void> _showPicker(List<String> available) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Choose push distributor'),
        children: [
          for (final d in available)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, d),
              child: Row(
                children: [
                  Expanded(child: Text(_label(d))),
                  if (d == _current) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen != null && chosen != _current) await _choose(chosen);
  }
}
