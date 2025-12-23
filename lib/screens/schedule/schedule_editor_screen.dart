import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../models/medication.dart';
import '../../services/device_repository.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

/// Create or edit one dose time: when, which days, and how many pills from each compartment.
class ScheduleEditorScreen extends StatefulWidget {
  const ScheduleEditorScreen({super.key, required this.device, this.schedule});

  final Device device;
  final Schedule? schedule;

  @override
  State<ScheduleEditorScreen> createState() => _ScheduleEditorScreenState();
}

class _ScheduleEditorScreenState extends State<ScheduleEditorScreen> {
  late final _label = TextEditingController(text: widget.schedule?.label ?? '');
  late TimeOfDay _time = widget.schedule == null
      ? const TimeOfDay(hour: 8, minute: 0)
      : TimeOfDay(hour: widget.schedule!.hour, minute: widget.schedule!.minute);
  late final Set<int> _days = {...?widget.schedule?.days};
  late final Map<int, int> _doses = {...?widget.schedule?.doses};
  late final Stream<List<Compartment>> _compartments =
      context.read<DeviceRepository>().compartments(widget.device.id);

  bool get _isNew => widget.schedule == null;

  @override
  void initState() {
    super.initState();
    if (_isNew) _days.addAll([1, 2, 3, 4, 5, 6, 7]);
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  String get _timeText => '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    final doses = {for (final e in _doses.entries) if (e.value > 0) e.key: e.value};
    if (doses.isEmpty) return showSnack(context, 'Choose at least one pill to dispense.', error: true);
    if (_days.isEmpty) return showSnack(context, 'Choose at least one day.', error: true);
    final schedule = Schedule(
      id: widget.schedule?.id ?? '',
      label: _label.text.trim(),
      time: _timeText,
      days: _days.toList()..sort(),
      doses: doses,
      enabled: widget.schedule?.enabled ?? true,
    );
    final ok = await runGuarded(
      context,
      () => context.read<DeviceRepository>().saveSchedule(widget.device.id, schedule),
      success: 'Schedule saved. The box will sync within a minute.',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final yes = await confirm(context,
        title: 'Delete this dose?', message: 'The box will stop dispensing it.', ok: 'Delete');
    if (!yes || !mounted) return;
    final ok = await runGuarded(
        context, () => context.read<DeviceRepository>().deleteSchedule(widget.device.id, widget.schedule!.id));
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add dose' : 'Edit dose'),
        actions: [if (!_isNew) IconButton(onPressed: _delete, icon: const Icon(Icons.delete_outline))],
      ),
      body: StreamBuilder<List<Compartment>>(
        stream: _compartments,
        builder: (context, snap) {
          final compartments = snap.data ?? const [];
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.access_time, color: AppColors.primaryDark),
                title: Text(_timeText, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                subtitle: const Text("Box time · tap to change"),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: _time,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
                      child: child!,
                    ),
                  );
                  if (picked != null) setState(() => _time = picked);
                },
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Label (optional)', hintText: 'e.g. After breakfast'),
            ),
            const SectionTitle('Days'),
            Wrap(spacing: 6, children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(weekdayShort[d - 1]),
                  selected: _days.contains(d),
                  onSelected: (on) => setState(() => on ? _days.add(d) : _days.remove(d)),
                ),
            ]),
            const SectionTitle('Pills to dispense'),
            if (snap.connectionState == ConnectionState.waiting) const LinearProgressIndicator(),
            for (final c in compartments)
              Card(
                child: ListTile(
                  leading: CircleAvatar(backgroundColor: AppColors.primaryLight, child: Text('${c.index}')),
                  title: Text(c.label),
                  subtitle: Text(c.isEmpty ? 'Empty compartment' : '${c.quantity} in stock'),
                  enabled: !c.isEmpty || (_doses[c.index] ?? 0) > 0,
                  trailing: _Counter(
                    value: _doses[c.index] ?? 0,
                    onChanged: (v) => setState(() => _doses[c.index] = v),
                  ),
                ),
              ),
            const SizedBox(height: 24),
            BusyButton(label: 'Save', onPressed: _save),
          ]);
        },
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        onPressed: value > 0 ? () => onChanged(value - 1) : null,
        icon: const Icon(Icons.remove_circle_outline),
      ),
      SizedBox(
        width: 24,
        child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ),
      IconButton(
        onPressed: value < 10 ? () => onChanged(value + 1) : null,
        icon: const Icon(Icons.add_circle_outline),
      ),
    ]);
  }
}
