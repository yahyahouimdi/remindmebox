import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/session.dart';
import 'account/account_screen.dart';
import 'chat/chat_screen.dart';
import 'map/hospital_map_screen.dart';
import 'schedule/schedule_screen.dart';
import 'track/track_screen.dart';
import 'users/caregivers_screen.dart';

class _Tab {
  const _Tab(this.id, this.label, this.icon, this.selectedIcon, this.builder);

  final String id;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() builder;
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  String _current = 'schedule';
  final Set<String> _visited = {'schedule'};

  @override
  Widget build(BuildContext context) {
    final owner = context.select<Session, bool>((s) => s.ownsSelectedDevice);
    final tabs = [
      _Tab('schedule', 'Schedule', Icons.medication_outlined, Icons.medication, ScheduleScreen.new),
      _Tab('track', 'Track', Icons.location_on_outlined, Icons.location_on, TrackScreen.new),
      _Tab('map', 'Hospitals', Icons.local_hospital_outlined, Icons.local_hospital, HospitalMapScreen.new),
      _Tab('chat', 'Dr. AI', Icons.chat_bubble_outline, Icons.chat_bubble, ChatScreen.new),
      if (owner) _Tab('users', 'Users', Icons.group_add_outlined, Icons.group_add, CaregiversScreen.new),
      _Tab('account', 'Account', Icons.person_outline, Icons.person, AccountScreen.new),
    ];
    var index = tabs.indexWhere((t) => t.id == _current);
    if (index < 0) index = 0;

    return Scaffold(
      // Tabs are built on first visit and then kept alive (maps, chat scroll, ...).
      body: IndexedStack(
        index: index,
        children: [
          for (final t in tabs)
            _visited.contains(t.id) ? KeyedSubtree(key: ValueKey(t.id), child: t.builder()) : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) => setState(() {
          _current = tabs[i].id;
          _visited.add(_current);
        }),
        destinations: [
          for (final t in tabs)
            NavigationDestination(icon: Icon(t.icon), selectedIcon: Icon(t.selectedIcon), label: t.label),
        ],
      ),
    );
  }
}
