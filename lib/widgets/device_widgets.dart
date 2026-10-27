import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../screens/alerts/alerts_screen.dart';
import '../screens/device/connect_device_screen.dart';
import '../services/device_repository.dart';
import '../state/session.dart';
import '../theme.dart';
import '../utils/format.dart';
import 'common.dart';

/// App-bar title that shows the selected box and lets the user switch boxes.
class DeviceSwitcherTitle extends StatelessWidget {
  const DeviceSwitcherTitle({super.key, required this.fallback});

  final String fallback;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final device = session.device;
    if (device == null) return Text(fallback);
    if (session.devices.length == 1) return Text(device.displayName);
    return PopupMenuButton<String>(
      tooltip: 'Switch box',
      onSelected: session.selectDevice,
      itemBuilder: (_) => [
        for (final d in session.devices)
          CheckedPopupMenuItem(value: d.id, checked: d.id == device.id, child: Text(d.displayName)),
      ],
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(device.displayName, overflow: TextOverflow.ellipsis)),
        const Icon(Icons.arrow_drop_down),
      ]),
    );
  }
}

/// Bell icon with the number of unacknowledged alerts.
class AlertsButton extends StatelessWidget {
  const AlertsButton({super.key, required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: context.read<DeviceRepository>().alerts(device.id, limit: 30),
      builder: (context, snap) {
        final unread = (snap.data ?? const []).where((a) => !a.acknowledged).length;
        return IconButton(
          tooltip: 'Alerts',
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlertsScreen(device: device))),
          icon: Badge(
            isLabelVisible: unread > 0,
            label: Text(unread > 9 ? '9+' : '$unread'),
            child: const Icon(Icons.notifications_outlined),
          ),
        );
      },
    );
  }
}

/// Online state, battery and last report of the box.
class DeviceStatusBar extends StatelessWidget {
  const DeviceStatusBar({super.key, required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    final online = device.isOnline;
    final battery = device.battery;
    return Wrap(spacing: 8, runSpacing: 4, children: [
      Chip(
        avatar: Icon(Icons.circle, size: 12, color: online ? AppColors.taken : AppColors.muted),
        label: Text(online ? 'Online' : 'Offline · ${timeAgo(device.lastSeen)}'),
        visualDensity: VisualDensity.compact,
      ),
      if (battery != null)
        Chip(
          avatar: Icon(
            battery <= 15 ? Icons.battery_alert : Icons.battery_std,
            size: 18,
            color: battery <= 15 ? AppColors.missed : AppColors.primaryDark,
          ),
          label: Text('$battery%'),
          visualDensity: VisualDensity.compact,
        ),
      if (device.geofence.enabled && device.geofenceInside == false)
        const Chip(
          avatar: Icon(Icons.wrong_location, size: 18, color: AppColors.missed),
          label: Text('Outside safe zone'),
          visualDensity: VisualDensity.compact,
        ),
    ]);
  }
}

/// Shown on every tab that needs a box when the user has none yet.
class NoDeviceView extends StatelessWidget {
  const NoDeviceView({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    if (!session.devicesLoaded) return const Center(child: CircularProgressIndicator());
    final profile = session.profile!;
    if (profile.isSuperUser) {
      return EmptyState(
        icon: Icons.devices_other,
        title: 'Connect your RemindMeBox',
        message: 'Set up the box WiFi over Bluetooth, then enter the ID and pairing code shown on its screen.',
        action: ElevatedButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectDeviceScreen())),
          icon: const Icon(Icons.add_link),
          label: const Text('Connect a box'),
        ),
      );
    }
    return EmptyState(
      icon: Icons.group_outlined,
      title: 'No box shared with you yet',
      message: 'Ask the box owner to add you as a caregiver with your email:\n${profile.email}',
    );
  }
}
