import 'package:flutter/material.dart';

import '../screens/apps/apps_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/security/security_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/smart/smart_screen.dart';

/// Main application shell: hosts the five top-level sections behind a
/// Material 3 bottom [NavigationBar].
///
/// Tabs are kept alive with an [IndexedStack] so switching never loses
/// scroll positions or in-progress state. Future screens (PIN setup, lock
/// challenge, onboarding) are pushed as full-screen routes on top of this
/// shell — the bottom bar belongs to the top-level sections only.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  /// App-bar title per tab. Index order is the single source of truth for
  /// both the [NavigationBar] destinations and the [IndexedStack] children.
  static const List<String> _titles = <String>[
    'Smart App Lock',
    'Apps',
    'Smart',
    'Security',
    'Settings',
  ];

  late final List<Widget> _screens = <Widget>[
    HomeScreen(onNavigate: _selectTab),
    const AppsScreen(),
    const SmartScreen(),
    const SecurityScreen(),
    const SettingsScreen(),
  ];

  void _selectTab(int index) {
    if (index == _selectedIndex) {
      return;
    }
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_titles[_selectedIndex])),
      body: IndexedStack(index: _selectedIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _selectTab,
        destinations: const <NavigationDestination>[
          NavigationDestination(
            key: Key('nav_home'),
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            key: Key('nav_apps'),
            icon: Icon(Icons.apps_outlined),
            selectedIcon: Icon(Icons.apps),
            label: 'Apps',
          ),
          NavigationDestination(
            key: Key('nav_smart'),
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'Smart',
          ),
          NavigationDestination(
            key: Key('nav_security'),
            icon: Icon(Icons.shield_outlined),
            selectedIcon: Icon(Icons.shield),
            label: 'Security',
          ),
          NavigationDestination(
            key: Key('nav_settings'),
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
