import 'package:flutter/material.dart';

import 'push/push_manager.dart';
import 'screens/account_shell_screen.dart';
import 'screens/setup_screen.dart';
import 'state/account_manager.dart';

/// UnifiedPush may relaunch this entrypoint in a background isolate,
/// passing `--unifiedpush-bg`, purely to deliver a wake without ever
/// showing UI -- initPush() must still run in that case (its callbacks
/// are what handles the wake), but runApp() must not.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initPush();
  if (!args.contains('--unifiedpush-bg')) {
    runApp(const FreizoneApp());
  }
}

class FreizoneApp extends StatelessWidget {
  const FreizoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Freizone',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.light)),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark)),
      themeMode: ThemeMode.system,
      home: const AppRoot(),
    );
  }
}

/// Loads every locally connected account on startup (see AccountManager)
/// and routes to SetupScreen (no account on this device yet) or the
/// account switcher + chat list otherwise.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

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
    final manager = await AccountManager.load();
    if (!mounted) return;
    setState(() {
      _manager = manager;
      _loading = false;
    });
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
    return AccountShellScreen(manager: manager);
  }
}
