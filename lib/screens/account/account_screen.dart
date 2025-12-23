import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../device/connect_device_screen.dart';
import '../device/device_settings_screen.dart';

class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  Future<void> _editName(BuildContext context, Session session) async {
    final controller = TextEditingController(text: session.profile!.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    await runGuarded(context, () => context.read<AuthService>().updateName(session.uid, name));
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final profile = session.profile!;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const SizedBox(height: 8),
        Center(
          child: CircleAvatar(
            radius: 48,
            backgroundColor: AppColors.primary,
            child: Text(profile.name.isEmpty ? '?' : profile.name[0].toUpperCase(),
                style: const TextStyle(fontSize: 40, color: Colors.white)),
          ),
        ),
        const SizedBox(height: 12),
        Center(child: Text(profile.name, style: Theme.of(context).textTheme.headlineSmall)),
        Center(child: Text(profile.email, style: const TextStyle(color: Colors.black54))),
        const SizedBox(height: 8),
        Center(child: Chip(label: Text(profile.role.label))),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit name'),
            onTap: () => _editName(context, session),
          ),
        ),
        SectionTitle(
          'My boxes',
          trailing: profile.isSuperUser
              ? TextButton.icon(
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectDeviceScreen())),
                  icon: const Icon(Icons.add),
                  label: const Text('Connect'),
                )
              : null,
        ),
        if (session.devices.isEmpty) const Text('No box yet.', style: TextStyle(color: Colors.black54)),
        for (final d in session.devices)
          Card(
            child: ListTile(
              leading: Icon(Icons.inventory_2_outlined, color: d.isOnline ? AppColors.taken : AppColors.muted),
              title: Text(d.displayName),
              subtitle: Text('${d.id} · ${d.isOwner(session.uid) ? 'Owner' : 'Caregiver'}'),
              selected: d.id == session.device?.id,
              onTap: () => session.selectDevice(d.id),
              trailing: d.isOwner(session.uid)
                  ? IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () =>
                          Navigator.push(context, MaterialPageRoute(builder: (_) => DeviceSettingsScreen(device: d))),
                    )
                  : null,
            ),
          ),
        const SizedBox(height: 32),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.missed),
          onPressed: () async {
            if (await confirm(context, title: 'Log out?', message: 'You will stop receiving alerts on this phone.', ok: 'Log out')) {
              await session.signOut();
            }
          },
          icon: const Icon(Icons.logout),
          label: const Text('Logout'),
        ),
      ]),
    );
  }
}
