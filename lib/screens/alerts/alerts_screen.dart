import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/alert.dart';
import '../../models/device.dart';
import '../../services/device_repository.dart';
import '../../state/session.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key, required this.device});

  final Device device;

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  late final Stream<List<DeviceAlert>> _alerts = context.read<DeviceRepository>().alerts(widget.device.id);

  Future<void> _acknowledgeAll(List<DeviceAlert> alerts) async {
    final repo = context.read<DeviceRepository>();
    final uid = context.read<Session>().uid;
    await runGuarded(context, () async {
      for (final a in alerts.where((a) => !a.acknowledged)) {
        await repo.acknowledgeAlert(widget.device.id, a.id, uid);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<DeviceAlert>>(
      stream: _alerts,
      builder: (context, snap) {
        final alerts = snap.data ?? const [];
        final unread = alerts.where((a) => !a.acknowledged).length;
        return Scaffold(
          appBar: AppBar(
            title: Text('Alerts · ${widget.device.displayName}'),
            actions: [
              if (unread > 0)
                TextButton(
                  onPressed: () => _acknowledgeAll(alerts),
                  child: const Text('Mark all seen', style: TextStyle(color: Colors.white)),
                ),
            ],
          ),
          body: !snap.hasData
              ? const Center(child: CircularProgressIndicator())
              : alerts.isEmpty
                  ? const EmptyState(
                      icon: Icons.notifications_none,
                      title: 'No alerts',
                      message: 'Missed doses, low stock, SOS and safe-zone alerts will appear here.',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: alerts.length,
                      itemBuilder: (context, i) => _AlertTile(device: widget.device, alert: alerts[i]),
                    ),
        );
      },
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.device, required this.alert});

  final Device device;
  final DeviceAlert alert;

  @override
  Widget build(BuildContext context) {
    final seen = alert.acknowledged;
    return Card(
      color: seen ? Colors.white : alert.color.withValues(alpha: .08),
      child: ListTile(
        leading: CircleAvatar(backgroundColor: alert.color, child: Icon(alert.icon, color: Colors.white)),
        title: Text(alert.title, style: TextStyle(fontWeight: seen ? FontWeight.normal : FontWeight.bold)),
        subtitle: Text('${alert.message}\n${alert.createdAt == null ? '' : timeAgo(alert.createdAt)}'),
        isThreeLine: true,
        trailing: seen
            ? const Icon(Icons.done, color: Colors.black26)
            : IconButton(
                tooltip: 'Mark as seen',
                icon: const Icon(Icons.check_circle_outline),
                onPressed: () => runGuarded(
                  context,
                  () => context
                      .read<DeviceRepository>()
                      .acknowledgeAlert(device.id, alert.id, context.read<Session>().uid),
                ),
              ),
      ),
    );
  }
}
