import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../models/medication.dart';
import '../../services/device_repository.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../utils/dose_planner.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../../widgets/device_widgets.dart';
import '../device/connect_device_screen.dart';
import '../device/device_settings_screen.dart';
import 'compartments_screen.dart';
import 'schedule_editor_screen.dart';

String describeDoses(Map<int, int> doses, Map<int, Compartment> compartments) {
  final keys = doses.keys.toList()..sort();
  return keys.map((c) => '${compartments[c]?.label ?? 'Compartment $c'} ×${doses[c]}').join(', ');
}

class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final device = session.device;
    final owner = session.ownsSelectedDevice;

    return Scaffold(
      appBar: AppBar(
        title: const DeviceSwitcherTitle(fallback: 'Pill Schedule'),
        actions: [
          if (device != null) AlertsButton(device: device),
          if (device != null && owner)
            PopupMenuButton<String>(
              onSelected: (value) {
                final page = switch (value) {
                  'meds' => CompartmentsScreen(device: device),
                  'settings' => DeviceSettingsScreen(device: device),
                  _ => const ConnectDeviceScreen(),
                };
                Navigator.push(context, MaterialPageRoute(builder: (_) => page));
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'meds', child: Text('Edit medications')),
                PopupMenuItem(value: 'settings', child: Text('Box settings')),
                PopupMenuItem(value: 'connect', child: Text('Connect another box')),
              ],
            ),
        ],
      ),
      floatingActionButton: device != null && owner
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => ScheduleEditorScreen(device: device))),
              icon: const Icon(Icons.add_alarm),
              label: const Text('Add dose'),
            )
          : null,
      body: device == null ? const NoDeviceView() : _ScheduleBody(key: ValueKey(device.id), device: device, owner: owner),
    );
  }
}

class _ScheduleBody extends StatefulWidget {
  const _ScheduleBody({super.key, required this.device, required this.owner});

  final Device device;
  final bool owner;

  @override
  State<_ScheduleBody> createState() => _ScheduleBodyState();
}

class _ScheduleBodyState extends State<_ScheduleBody> {
  late final Stream<List<Schedule>> _schedules;
  late final Stream<List<Compartment>> _compartments;
  late final Stream<List<DoseEvent>> _events;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    final repo = context.read<DeviceRepository>();
    _schedules = repo.schedules(widget.device.id);
    _compartments = repo.compartments(widget.device.id);
    _events = repo.doseEvents(widget.device.id, since: DateTime.now().subtract(const Duration(days: 8)));
    // "Upcoming" becomes "due" as time passes, even without new data.
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Schedule>>(
      stream: _schedules,
      builder: (context, schedulesSnap) => StreamBuilder<List<Compartment>>(
        stream: _compartments,
        builder: (context, compartmentsSnap) => StreamBuilder<List<DoseEvent>>(
          stream: _events,
          builder: (context, eventsSnap) {
            if (!schedulesSnap.hasData || !compartmentsSnap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return _content(schedulesSnap.data!, compartmentsSnap.data!, eventsSnap.data ?? const []);
          },
        ),
      ),
    );
  }

  Widget _content(List<Schedule> schedules, List<Compartment> compartments, List<DoseEvent> events) {
    final device = widget.device;
    final byIndex = {for (final c in compartments) c.index: c};
    final today = planDay(
      schedules: schedules,
      eventsById: {for (final e in events) e.id: e},
      nowUtc: DateTime.now().toUtc(),
      utcOffsetMinutes: device.utcOffsetMinutes,
      missedDoseDelayMin: device.settings.missedDoseDelayMin,
    );
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    final stats = adherence(events.where((e) => e.scheduledAt?.isAfter(weekAgo) ?? false));
    final medsSet = compartments.any((c) => !c.isEmpty);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        DeviceStatusBar(device: device),
        if (stats.ratio != null) _AdherenceCard(stats: stats),
        if (!medsSet && widget.owner)
          Card(
            color: const Color(0xFFFFF3E0),
            child: ListTile(
              leading: const Icon(Icons.info_outline, color: AppColors.pending),
              title: const Text('Tell the box what is in each compartment'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => CompartmentsScreen(device: device))),
            ),
          ),
        const SectionTitle('Today'),
        if (today.isEmpty)
          const Card(child: ListTile(leading: Icon(Icons.event_available), title: Text('No doses today')))
        else
          for (final dose in today) _PlannedDoseTile(dose: dose, compartments: byIndex),
        SectionTitle(
          'Medications',
          trailing: widget.owner
              ? TextButton.icon(
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => CompartmentsScreen(device: device))),
                  icon: const Icon(Icons.edit, size: 18),
                  label: const Text('Edit'),
                )
              : null,
        ),
        for (final c in compartments.where((c) => !c.isEmpty))
          _CompartmentTile(compartment: c, threshold: device.settings.lowStockThreshold),
        if (!medsSet) const Text('No medication registered yet.', style: TextStyle(color: Colors.black54)),
        const SectionTitle('Dose schedule'),
        if (schedules.isEmpty)
          Text(widget.owner ? 'Tap "Add dose" to create the first reminder.' : 'No dose scheduled yet.',
              style: const TextStyle(color: Colors.black54)),
        for (final s in schedules) _ScheduleTile(device: device, schedule: s, compartments: byIndex, owner: widget.owner),
        if (events.isNotEmpty) ...[
          const SectionTitle('Recent history'),
          for (final e in events.take(12)) _HistoryTile(event: e, compartments: byIndex),
        ],
      ],
    );
  }
}

class _AdherenceCard extends StatelessWidget {
  const _AdherenceCard({required this.stats});

  final Adherence stats;

  @override
  Widget build(BuildContext context) {
    final ratio = stats.ratio!;
    final color = ratio >= .9 ? AppColors.taken : (ratio >= .7 ? AppColors.pending : AppColors.missed);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Adherence · last 7 days', style: TextStyle(fontWeight: FontWeight.w600))),
            Text('${(ratio * 100).round()}%', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: ratio, minHeight: 8, color: color, backgroundColor: color.withValues(alpha: .15)),
          ),
          const SizedBox(height: 6),
          Text('${stats.taken} of ${stats.total} doses taken', style: const TextStyle(color: Colors.black54)),
        ]),
      ),
    );
  }
}

({Color color, IconData icon, String label}) _stateStyle(DoseState state) => switch (state) {
      DoseState.upcoming => (color: AppColors.muted, icon: Icons.schedule, label: 'Upcoming'),
      DoseState.due => (color: AppColors.pending, icon: Icons.alarm, label: 'Due now'),
      DoseState.dispensed => (color: AppColors.pending, icon: Icons.medication, label: 'Waiting in the tray'),
      DoseState.taken => (color: AppColors.taken, icon: Icons.check_circle, label: 'Taken'),
      DoseState.missed => (color: AppColors.missed, icon: Icons.cancel, label: 'Missed'),
      DoseState.failed => (color: AppColors.missed, icon: Icons.error, label: 'Dispensing failed'),
    };

class _PlannedDoseTile extends StatelessWidget {
  const _PlannedDoseTile({required this.dose, required this.compartments});

  final PlannedDose dose;
  final Map<int, Compartment> compartments;

  @override
  Widget build(BuildContext context) {
    final style = _stateStyle(dose.state);
    final event = dose.event;
    var detail = style.label;
    if (dose.state == DoseState.taken && event?.takenAt != null) detail = 'Taken at ${formatClock(event!.takenAt!)}';
    if (dose.state == DoseState.missed && event == null) detail = 'Not confirmed by the box';
    if (event?.fromServer == true && dose.state == DoseState.missed) detail = 'Missed (box did not report)';
    return Card(
      child: ListTile(
        leading: CircleAvatar(backgroundColor: style.color, child: Icon(style.icon, color: Colors.white)),
        title: Text('${dose.schedule.time}  ${dose.schedule.label}'.trim(),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${describeDoses(dose.schedule.doses, compartments)}\n$detail'),
        isThreeLine: true,
      ),
    );
  }
}

class _CompartmentTile extends StatelessWidget {
  const _CompartmentTile({required this.compartment, required this.threshold});

  final Compartment compartment;
  final int threshold;

  @override
  Widget build(BuildContext context) {
    final low = compartment.quantity <= threshold;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.primaryLight,
          child: Text('${compartment.index}', style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        title: Text(compartment.medicationName),
        subtitle: compartment.notes.isEmpty ? null : Text(compartment.notes),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${compartment.quantity} left',
              style: TextStyle(fontWeight: FontWeight.bold, color: low ? AppColors.missed : null)),
          if (low) const Text('Refill soon', style: TextStyle(color: AppColors.missed, fontSize: 12)),
        ]),
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({required this.device, required this.schedule, required this.compartments, required this.owner});

  final Device device;
  final Schedule schedule;
  final Map<int, Compartment> compartments;
  final bool owner;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<DeviceRepository>();
    return Card(
      child: ListTile(
        leading: const Icon(Icons.alarm, color: AppColors.primaryDark),
        title: Text('${schedule.time}  ${schedule.label}'.trim(), style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${formatDays(schedule.days)}\n${describeDoses(schedule.doses, compartments)}'),
        isThreeLine: true,
        onTap: owner
            ? () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => ScheduleEditorScreen(device: device, schedule: schedule)))
            : null,
        trailing: owner
            ? Switch(
                value: schedule.enabled,
                onChanged: (v) => runGuarded(context, () => repo.setScheduleEnabled(device.id, schedule.id, v)),
              )
            : (schedule.enabled ? null : const Text('Paused')),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.event, required this.compartments});

  final DoseEvent event;
  final Map<int, Compartment> compartments;

  @override
  Widget build(BuildContext context) {
    final style = _stateStyle(switch (event.status) {
      DoseStatus.dispensed => DoseState.dispensed,
      DoseStatus.taken => DoseState.taken,
      DoseStatus.missed => DoseState.missed,
      DoseStatus.failed => DoseState.failed,
    });
    final when = event.scheduledAt != null ? formatDateTime(event.scheduledAt!) : '${event.date} ${event.time}';
    return ListTile(
      dense: true,
      leading: Icon(style.icon, color: style.color),
      title: Text(when),
      trailing: Text(style.label, style: TextStyle(color: style.color)),
    );
  }
}
