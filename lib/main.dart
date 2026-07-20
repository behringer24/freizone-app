import 'package:flutter/material.dart';

import 'push/notification_navigation.dart';
import 'push/push_manager.dart';
import 'screens/account_shell_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/setup_screen.dart';
import 'state/account_manager.dart';
import 'state/app_settings.dart';

/// UnifiedPush may relaunch this entrypoint in a background isolate,
/// passing `--unifiedpush-bg`, purely to deliver a wake without ever
/// showing UI -- initPush() must still run in that case (its callbacks
/// are what handles the wake), but runApp() must not.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initPush();
  if (!args.contains('--unifiedpush-bg')) {
    final settings = await AppSettings.load();
    runApp(FreizoneApp(settings: settings));
  }
}

class FreizoneApp extends StatelessWidget {
  const FreizoneApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    // Rebuilds the whole MaterialApp (theme + home) whenever a setting
    // changes, so switching theme mode/accent color takes effect
    // immediately without needing an app restart.
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final seed = settings.accentPreset.color;
        return MaterialApp(
          title: 'Freizone',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: seed,
              brightness: Brightness.light,
            ),
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: seed,
              brightness: Brightness.dark,
            ),
          ),
          themeMode: settings.themeMode,
          home: AppRoot(settings: settings),
        );
      },
    );
  }
}

/// Loads every locally connected account on startup (see AccountManager)
/// and routes to SetupScreen (no account on this device yet) or the
/// account switcher + chat list otherwise.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  AccountManager? _manager;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final manager = await AccountManager.load(widget.settings);
    if (!mounted) return;
    setState(() {
      _manager = manager;
      _loading = false;
    });

    // Registered only now that _manager is set -- a tap that raced
    // startup (fired before this point) is a silent no-op there, but is
    // re-delivered by the cold-launch check right below, which only
    // runs once this handler already exists.
    setNotificationTapHandler(_openChatFor);
    handleNotificationPayload(await consumeLaunchNotificationPayload());
  }

  /// Switches to the tapped notification's account and, if it named a
  /// specific peer (see push_manager.dart's showMessageNotification),
  /// pushes straight into that conversation -- otherwise just leaves the
  /// account switched, landing on its chat list.
  void _openChatFor(String accountId, String? peerAccountId) {
    final manager = _manager;
    if (manager == null || !mounted) return;
    final session = manager.sessionFor(accountId);
    if (session == null) return; // account no longer exists on this device

    manager.setActive(accountId);
    if (peerAccountId == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(session: session, peerAccountId: peerAccountId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final manager = _manager!;
    if (manager.sessions.isEmpty) {
      return SetupScreen(
        onRegistered: (state) async {
          await manager.addProfile(state);
          setState(() {});
        },
      );
    }
    return AccountShellScreen(manager: manager, settings: widget.settings);
  }
}
