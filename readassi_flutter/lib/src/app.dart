import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/home_shell.dart';
import 'theme.dart';

class ReadAssiApp extends StatefulWidget {
  const ReadAssiApp({super.key});

  @override
  State<ReadAssiApp> createState() => _ReadAssiAppState();
}

class _ReadAssiAppState extends State<ReadAssiApp> {
  late final AppState _appState;

  @override
  void initState() {
    super.initState();
    _appState = AppState();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      notifier: _appState,
      child: MaterialApp(
        title: 'ReadAssi',
        debugShowCheckedModeBanner: false,
        theme: buildReadAssiTheme(),
        home: const HomeShell(),
      ),
    );
  }
}
