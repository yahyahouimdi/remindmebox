import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../config/env.dart';

/// Registers this phone for push alerts (missed dose, SOS, low stock, ...).
/// The backend sends them to the Firebase Installation IDs stored in
/// `users/{uid}.pushIds`; while the app is open they are shown in-app.
class NotificationService {
  NotificationService({FirebaseMessaging? messaging, FirebaseFirestore? db})
      : _messaging = messaging ?? FirebaseMessaging.instance,
        _db = db ?? FirebaseFirestore.instance;

  final FirebaseMessaging _messaging;
  final FirebaseFirestore _db;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  String? _uid;
  String? _pushId;

  /// Push requires a real Firebase project (and a VAPID key on the web).
  bool get _supported => !kIsWeb && !Env.useEmulator;

  Future<void> start(String uid, {required void Function(RemoteMessage) onForegroundMessage}) async {
    await stop();
    _uid = uid;
    _subscriptions.add(FirebaseMessaging.onMessage.listen(onForegroundMessage));
    if (!_supported) return;
    try {
      final settings = await _messaging.requestPermission(alert: true, badge: true, sound: true);
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      // Fires after register() and again whenever the installation ID changes.
      _subscriptions.add(_messaging.onRegistered.listen((id) {
        _pushId = id;
        _update(FieldValue.arrayUnion([id]));
      }));
      await _messaging.register();
    } catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }

  Future<void> _update(FieldValue change) async {
    final uid = _uid;
    if (uid == null) return;
    await _db.doc('users/$uid').update({'pushIds': change, 'updatedAt': FieldValue.serverTimestamp()});
  }

  /// Called before sign-out so this phone stops receiving the user's alerts.
  Future<void> unregister() async {
    final id = _pushId;
    if (id != null) {
      try {
        await _update(FieldValue.arrayRemove([id]));
      } catch (e) {
        debugPrint('Could not remove push id: $e');
      }
    }
    await stop();
  }

  Future<void> stop() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    _uid = null;
    _pushId = null;
  }
}
