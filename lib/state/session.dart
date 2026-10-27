import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../models/app_user.dart';
import '../models/device.dart';
import '../services/auth_service.dart';
import '../services/device_repository.dart';
import '../services/notification_service.dart';

enum SessionStatus { loading, signedOut, needsProfile, ready }

/// Who is signed in, their profile, and the boxes they can see.
class Session extends ChangeNotifier {
  Session({
    required this.auth,
    required this.devicesRepo,
    required this.notifications,
    required this.onPushMessage,
  }) {
    _authSub = auth.authStateChanges().listen(_onAuthChanged);
  }

  final AuthService auth;
  final DeviceRepository devicesRepo;
  final NotificationService notifications;
  final void Function(RemoteMessage message) onPushMessage;

  StreamSubscription<User?>? _authSub;
  StreamSubscription<AppUser?>? _profileSub;
  StreamSubscription<List<Device>>? _devicesSub;

  SessionStatus status = SessionStatus.loading;
  User? user;
  AppUser? profile;
  List<Device> devices = const [];
  bool devicesLoaded = false;
  String? _selectedDeviceId;

  String get uid => user!.uid;

  Device? get device {
    if (devices.isEmpty) return null;
    return devices.firstWhere((d) => d.id == _selectedDeviceId, orElse: () => devices.first);
  }

  bool get ownsSelectedDevice => device?.isOwner(uid) ?? false;

  void selectDevice(String id) {
    _selectedDeviceId = id;
    notifyListeners();
  }

  void _onAuthChanged(User? next) {
    _profileSub?.cancel();
    _devicesSub?.cancel();
    user = next;
    profile = null;
    devices = const [];
    devicesLoaded = false;
    if (next == null) {
      status = SessionStatus.signedOut;
      notifyListeners();
      return;
    }
    status = SessionStatus.loading;
    notifyListeners();

    var pushStarted = false;
    _profileSub = auth.profile(next.uid).listen((p) {
      profile = p;
      status = p == null ? SessionStatus.needsProfile : SessionStatus.ready;
      if (p != null && !pushStarted) {
        pushStarted = true;
        notifications.start(next.uid, onForegroundMessage: onPushMessage);
      }
      notifyListeners();
    }, onError: (Object e) => debugPrint('Profile stream error: $e'));

    _devicesSub = devicesRepo.devicesFor(next.uid).listen((list) {
      devices = list;
      devicesLoaded = true;
      notifyListeners();
    }, onError: (Object e) => debugPrint('Devices stream error: $e'));
  }

  Future<void> signOut() async {
    await notifications.unregister();
    await auth.signOut();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _profileSub?.cancel();
    _devicesSub?.cancel();
    notifications.stop();
    super.dispose();
  }
}
