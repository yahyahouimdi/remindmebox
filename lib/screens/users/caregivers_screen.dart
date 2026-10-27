import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../services/device_repository.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/device_widgets.dart';

/// Owner adds caregivers to the box by email. They get its alerts and can monitor it.
class CaregiversScreen extends StatefulWidget {
  const CaregiversScreen({super.key});

  @override
  State<CaregiversScreen> createState() => _CaregiversScreenState();
}

class _CaregiversScreenState extends State<CaregiversScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _add(Device device) async {
    if (!_formKey.currentState!.validate()) return;
    final email = _email.text.trim();
    String? status;
    final ok = await runGuarded(context, () async {
      status = await context.read<DeviceRepository>().addCaregiver(device.id, email);
    });
    if (!ok || !mounted) return;
    _email.clear();
    showSnack(context, switch (status) {
      'invited' => 'Invitation saved. $email gets access as soon as they create an account.',
      'already_member' => '$email already has access.',
      _ => '$email can now monitor ${device.displayName}.',
    });
  }

  Future<void> _remove(Device device, {DeviceMember? member, String? email}) async {
    final who = member?.name ?? email!;
    final yes = await confirm(context,
        title: 'Remove $who?', message: '$who will stop receiving alerts for this box.', ok: 'Remove');
    if (!yes || !mounted) return;
    await runGuarded(
      context,
      () => context.read<DeviceRepository>().removeCaregiver(device.id, uid: member?.uid, email: email),
    );
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<Session>().device;
    return Scaffold(
      appBar: AppBar(title: const DeviceSwitcherTitle(fallback: 'Add user')),
      body: device == null
          ? const NoDeviceView()
          : ListView(padding: const EdgeInsets.all(16), children: [
              Form(
                key: _formKey,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text(
                    'Caregivers can follow doses, location and alerts for this box. '
                    'Only you can change medications and schedules.',
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Caregiver email', prefixIcon: Icon(Icons.email_outlined)),
                    validator: (v) =>
                        RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v?.trim() ?? '') ? null : 'Enter a valid email',
                  ),
                  const SizedBox(height: 12),
                  BusyButton(label: 'Add', icon: Icons.person_add, onPressed: () => _add(device)),
                ]),
              ),
              const SectionTitle('People with access'),
              for (final m in device.members)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: m.isOwner ? AppColors.primaryDark : AppColors.primary,
                      child: Text(m.name.isEmpty ? '?' : m.name[0].toUpperCase(), style: const TextStyle(color: Colors.white)),
                    ),
                    title: Text(m.name),
                    subtitle: Text(m.email),
                    trailing: m.isOwner
                        ? const Chip(label: Text('Owner'))
                        : IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.person_remove_outlined),
                            onPressed: () => _remove(device, member: m),
                          ),
                  ),
                ),
              if (device.pendingInvites.isNotEmpty) ...[
                const SectionTitle('Waiting for sign-up'),
                for (final email in device.pendingInvites)
                  Card(
                    child: ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.hourglass_empty)),
                      title: Text(email),
                      subtitle: const Text('Will get access when they register'),
                      trailing: IconButton(
                        tooltip: 'Cancel invitation',
                        icon: const Icon(Icons.close),
                        onPressed: () => _remove(device, email: email),
                      ),
                    ),
                  ),
              ],
            ]),
    );
  }
}
