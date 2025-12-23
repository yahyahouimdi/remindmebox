import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../models/medication.dart';
import '../../services/device_repository.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

/// "Fill the form": what is in each compartment and how many pills were loaded.
class CompartmentsScreen extends StatefulWidget {
  const CompartmentsScreen({super.key, required this.device});

  final Device device;

  @override
  State<CompartmentsScreen> createState() => _CompartmentsScreenState();
}

class _Row {
  _Row(Compartment c)
      : index = c.index,
        name = TextEditingController(text: c.medicationName),
        quantity = TextEditingController(text: '${c.quantity}'),
        notes = TextEditingController(text: c.notes);

  final int index;
  final TextEditingController name;
  final TextEditingController quantity;
  final TextEditingController notes;

  Compartment toCompartment() => Compartment(
        index: index,
        medicationName: name.text.trim(),
        quantity: int.tryParse(quantity.text) ?? 0,
        notes: notes.text.trim(),
      );

  void dispose() {
    name.dispose();
    quantity.dispose();
    notes.dispose();
  }
}

class _CompartmentsScreenState extends State<CompartmentsScreen> {
  final _formKey = GlobalKey<FormState>();
  List<_Row>? _rows;

  @override
  void initState() {
    super.initState();
    // Load once: live updates would overwrite what the user is typing.
    context.read<DeviceRepository>().compartments(widget.device.id).first.then((list) {
      final byIndex = {for (final c in list) c.index: c};
      if (!mounted) return;
      setState(() => _rows = [
            for (var i = 1; i <= widget.device.compartmentCount; i++) _Row(byIndex[i] ?? Compartment(index: i)),
          ]);
    });
  }

  @override
  void dispose() {
    for (final r in _rows ?? const <_Row>[]) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final ok = await runGuarded(
      context,
      () => context
          .read<DeviceRepository>()
          .saveCompartments(widget.device.id, _rows!.map((r) => r.toCompartment()).toList()),
      success: 'Medications saved.',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('Medications')),
      body: rows == null
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                const Text(
                  'For each compartment, enter the medication and how many pills you loaded. '
                  'Stock goes down automatically after every dispense.',
                  style: TextStyle(color: Colors.black54),
                ),
                for (final r in rows)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(children: [
                        Row(children: [
                          CircleAvatar(backgroundColor: AppColors.primaryLight, child: Text('${r.index}')),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: r.name,
                              maxLength: 80,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                labelText: 'Compartment ${r.index} medication',
                                counterText: '',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 90,
                            child: TextFormField(
                              controller: r.quantity,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              decoration: const InputDecoration(labelText: 'Pills'),
                              validator: (v) {
                                final n = int.tryParse(v ?? '');
                                return n == null || n > 500 ? '0-500' : null;
                              },
                            ),
                          ),
                        ]),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: r.notes,
                          maxLength: 300,
                          decoration: const InputDecoration(
                            labelText: 'Notes (optional)',
                            hintText: 'e.g. 500 mg, take with food',
                            counterText: '',
                            isDense: true,
                          ),
                        ),
                      ]),
                    ),
                  ),
                const SizedBox(height: 16),
                BusyButton(label: 'Save', onPressed: _save),
              ]),
            ),
    );
  }
}
