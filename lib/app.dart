import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/auth/login_screen.dart';
import 'screens/auth/profile_setup_screen.dart';
import 'screens/home_shell.dart';
import 'services/auth_service.dart';
import 'services/chat_service.dart';
import 'services/device_repository.dart';
import 'services/hospital_service.dart';
import 'services/notification_service.dart';
import 'services/provisioning_service.dart';
import 'state/session.dart';
import 'theme.dart';

final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// Push alerts received while the app is in the foreground.
void _showPushMessage(RemoteMessage message) {
  final n = message.notification;
  if (n == null) return;
  messengerKey.currentState?.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    backgroundColor: message.data['type'] == 'sos' ? AppColors.missed : AppColors.primaryDark,
    duration: const Duration(seconds: 8),
    content: Text('${n.title ?? ''}\n${n.body ?? ''}'),
  ));
}

class RemindMeBoxApp extends StatelessWidget {
  const RemindMeBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider(create: (_) => AuthService()),
        Provider(create: (_) => DeviceRepository()),
        Provider(create: (_) => ChatService()),
        Provider(create: (_) => HospitalService()),
        Provider(create: (_) => ProvisioningService()),
        ChangeNotifierProvider(
          create: (context) => Session(
            auth: context.read<AuthService>(),
            devicesRepo: context.read<DeviceRepository>(),
            notifications: NotificationService(),
            onPushMessage: _showPushMessage,
          ),
        ),
      ],
      child: MaterialApp(
        title: 'RemindMeBox',
        theme: buildTheme(),
        scaffoldMessengerKey: messengerKey,
        debugShowCheckedModeBanner: false,
        home: const AuthGate(),
      ),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.select<Session, SessionStatus>((s) => s.status);
    return switch (status) {
      SessionStatus.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
      SessionStatus.signedOut => const LoginScreen(),
      SessionStatus.needsProfile => const ProfileSetupScreen(),
      SessionStatus.ready => const HomeShell(),
    };
  }
}
