import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_user.dart';
import '../../services/auth_service.dart';
import '../../state/session.dart';
import '../../widgets/common.dart';
import 'register_screen.dart';

/// Shown when an account exists without a profile (e.g. registration was interrupted).
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: context.read<Session>().user?.displayName ?? '');
  UserRole _role = UserRole.superUser;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(children: [
          const BrandHeader(compact: true, subtitle: 'Finish setting up your account'),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(session.user?.email ?? '', style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
                ),
                const SizedBox(height: 16),
                RoleSelector(value: _role, onChanged: (r) => setState(() => _role = r)),
                const SizedBox(height: 24),
                BusyButton(
                  label: 'Continue',
                  onPressed: () async {
                    if (!_formKey.currentState!.validate()) return;
                    await runGuarded(
                      context,
                      () => context
                          .read<AuthService>()
                          .createProfile(user: session.user!, name: _name.text, role: _role),
                    );
                  },
                ),
                TextButton(onPressed: session.signOut, child: const Text('Sign out')),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
