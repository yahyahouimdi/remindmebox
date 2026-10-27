import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../services/device_repository.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

/// Owner settings of a box: names, alert timings, and releasing the box.
class DeviceSettingsScreen extends StatefulWidget {
  const DeviceSettingsScreen({super.key, required this.device});

  final Device device;

  @override
  State<DeviceSettingsScreen> createState() => _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends State<DeviceSettingsScreen> {
  late final _name = TextEditingController(text: widget.device.name);
  late final _patient = TextEditingController(text: widget.device.patientName);
  late double _delay = widget.device.settings.missedDoseDelayMin.toDouble();
  late double _threshold = widget.device.settings.lowStockThreshold.toDouble();

  @override
  void dispose() {
    _name.dispose();
    _patient.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = context.read<DeviceRepository>();
    final ok = await runGuarded(context, () async {
      await repo.updateDetails(widget.device.id, name: _name.text, patientName: _patient.text);
      await repo.updateSettings(
        widget.device.id,
        DeviceSettings(missedDoseDelayMin: _delay.round(), lowStockThreshold: _threshold.round()),
      );
    }, success: 'Settings saved.');
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _release() async {
    final yes = await confirm(
      context,
      title: 'Release this box?',
      message: 'All schedules, history and caregivers of this box will be deleted, '
          'and it can then be connected to another account.',
      ok: 'Release',
    );
    if (!yes || !mounted) return;
    final ok = await runGuarded(context, () => context.read<DeviceRepository>().releaseDevice(widget.device.id));
    if (ok && mounted) Navigator.popUntil(context, (r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    return Scaffold(
      appBar: AppBar(title: const Text('Box settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _patient, decoration: const InputDecoration(labelText: 'Who uses this box?')),
        const SizedBox(height: 12),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Box name')),
        const SectionTitle('Missed dose alert'),
        Text('Alert caregivers if pills stay in the tray for ${_delay.round()} minutes.'),
        Slider(
          value: _delay,
          min: 5,
          max: 120,
          divisions: 23,
          label: '${_delay.round()} min',
          onChanged: (v) => setState(() => _delay = v),
        ),
        const SectionTitle('Low stock alert'),
        Text('Alert when a compartment has ${_threshold.round()} pills or fewer.'),
        Slider(
          value: _threshold,
          min: 0,
          max: 30,
          divisions: 30,
          label: '${_threshold.round()}',
          onChanged: (v) => setState(() => _threshold = v),
        ),
        const SizedBox(height: 16),
        BusyButton(label: 'Save', onPressed: _save),
        const SectionTitle('About this box'),
        Card(
          child: Column(children: [
            ListTile(title: const Text('Device ID'), trailing: SelectableText(d.id)),
            ListTile(title: const Text('Compartments'), trailing: Text('${d.compartmentCount}')),
            ListTile(title: const Text('Firmware'), trailing: Text(d.firmware ?? '—')),
            ListTile(title: const Text('Last report'), trailing: Text(timeAgo(d.lastSeen))),
          ]),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.missed,
            side: const BorderSide(color: AppColors.missed),
          ),
          onPressed: _release,
          icon: const Icon(Icons.link_off),
          label: const Text('Release this box'),
        ),
      ]),
    );
  }
}
