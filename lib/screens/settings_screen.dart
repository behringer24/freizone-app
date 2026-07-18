// App-wide preferences (not tied to any one account) -- theme, accent
// color, the default for "copy my address", and notification sound/
// vibration. See lib/state/app_settings.dart for persistence.
import 'package:flutter/material.dart';

import '../state/app_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.settings});

  final AppSettings settings;

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text, style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
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
                    RadioListTile<ThemeMode>(value: ThemeMode.system, title: Text('Follow system')),
                    RadioListTile<ThemeMode>(value: ThemeMode.light, title: Text('Light')),
                    RadioListTile<ThemeMode>(value: ThemeMode.dark, title: Text('Dark')),
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
                subtitle: const Text('Use the 5-character id prefix instead of the full id for "Copy my address"'),
                value: settings.copyIdShort,
                onChanged: settings.setCopyIdShort,
              ),
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
            ],
          );
        },
      ),
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({required this.preset, required this.selected, required this.onTap});

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
            border: selected ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 3) : null,
          ),
          child: selected ? const Icon(Icons.check, color: Colors.white) : null,
        ),
      ),
    );
  }
}
