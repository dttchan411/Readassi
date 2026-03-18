import 'package:flutter/material.dart';

import 'home_screen.dart';
import 'select_book_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [HomeScreen(), SelectBookScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFFFDFBF7),
        selectedIndex: _currentIndex,
        indicatorColor: const Color(0xFFFFE8C7),
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories_rounded),
            label: '분석 기록',
          ),
        ],
      ),
    );
  }
}
