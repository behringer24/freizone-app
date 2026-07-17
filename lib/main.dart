import 'package:flutter/material.dart';

import 'screens/chat_list_screen.dart';
import 'screens/setup_screen.dart';
import 'state/app_session.dart';
import 'state/local_state.dart';

void main() {
  runApp(const FreizoneApp());
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

/// Loads any persisted identity on startup and routes to SetupScreen (no
/// account on this device yet) or, once its AppSession has uploaded
/// prekeys and opened the live message stream, straight to ChatListScreen.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  AppSession? _session;
  bool _loading = true;
  bool _needsSetup = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    AppState? state;
    try {
      state = await LocalStateStore.load();
    } catch (_) {
      state = null;
    }

    if (state == null) {
      if (!mounted) return;
      setState(() {
        _needsSetup = true;
        _loading = false;
      });
      return;
    }

    final session = AppSession(state);
    await session.init();
    if (!mounted) return;
    setState(() {
      _session = session;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_needsSetup) {
      return const SetupScreen();
    }
    return ChatListScreen(session: _session!);
  }
}
