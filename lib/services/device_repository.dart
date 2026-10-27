import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:latlong2/latlong.dart';

import '../config/env.dart';
import '../models/alert.dart';
import '../models/device.dart';
import '../models/medication.dart';

/// All reads and writes for boxes. Owner-only writes are enforced again by
/// Firestore rules; claiming and caregiver management run in Cloud Functions.
class DeviceRepository {
  DeviceRepository({FirebaseFirestore? db, FirebaseFunctions? fn})
      : _db = db ?? FirebaseFirestore.instance,
        _fn = fn ?? functions();

  final FirebaseFirestore _db;
  final FirebaseFunctions _fn;

  DocumentReference<Map<String, dynamic>> _device(String id) => _db.doc('devices/$id');

  Stream<List<Device>> devicesFor(String uid) => _db
      .collection('devices')
      .where('memberUids', arrayContains: uid)
      .snapshots()
      .map((s) => s.docs.map(Device.fromDoc).toList()..sort((a, b) => a.name.compareTo(b.name)));

  // ---- Compartments ------------------------------------------------------

  Stream<List<Compartment>> compartments(String deviceId) => _device(deviceId)
      .collection('compartments')
      .snapshots()
      .map((s) => s.docs.map(Compartment.fromDoc).toList()..sort((a, b) => a.index.compareTo(b.index)));

  Future<void> saveCompartments(String deviceId, List<Compartment> compartments) {
    final batch = _db.batch();
    for (final c in compartments) {
      batch.set(_device(deviceId).collection('compartments').doc('${c.index}'), c.toMap());
    }
    return batch.commit();
  }

  // ---- Schedules ---------------------------------------------------------

  Stream<List<Schedule>> schedules(String deviceId) => _device(deviceId)
      .collection('schedules')
      .snapshots()
      .map((s) => s.docs.map(Schedule.fromDoc).toList()..sort((a, b) => a.minutesOfDay.compareTo(b.minutesOfDay)));

  Future<void> saveSchedule(String deviceId, Schedule schedule) {
    final col = _device(deviceId).collection('schedules');
    if (schedule.id.isEmpty) {
      return col.add({...schedule.toMap(), 'createdAt': FieldValue.serverTimestamp()});
    }
    return col.doc(schedule.id).update(schedule.toMap());
  }

  Future<void> setScheduleEnabled(String deviceId, String scheduleId, bool enabled) => _device(deviceId)
      .collection('schedules')
      .doc(scheduleId)
      .update({'enabled': enabled, 'updatedAt': FieldValue.serverTimestamp()});

  Future<void> deleteSchedule(String deviceId, String scheduleId) =>
      _device(deviceId).collection('schedules').doc(scheduleId).delete();

  // ---- History, alerts, locations ---------------------------------------

  Stream<List<DoseEvent>> doseEvents(String deviceId, {required DateTime since}) => _device(deviceId)
      .collection('doseEvents')
      .where('scheduledAt', isGreaterThanOrEqualTo: Timestamp.fromDate(since))
      .orderBy('scheduledAt', descending: true)
      .snapshots()
      .map((s) => s.docs.map(DoseEvent.fromDoc).toList());

  Stream<List<DeviceAlert>> alerts(String deviceId, {int limit = 50}) => _device(deviceId)
      .collection('alerts')
      .orderBy('createdAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((s) => s.docs.map(DeviceAlert.fromDoc).toList());

  Future<void> acknowledgeAlert(String deviceId, String alertId, String uid) =>
      _device(deviceId).collection('alerts').doc(alertId).update({
        'acknowledged': true,
        'acknowledgedBy': uid,
        'acknowledgedAt': FieldValue.serverTimestamp(),
      });

  Stream<List<LatLng>> locationTrail(String deviceId, {int limit = 60}) => _device(deviceId)
      .collection('locations')
      .orderBy('at', descending: true)
      .limit(limit)
      .snapshots()
      .map((s) => s.docs
          .map((d) => LatLng((d['lat'] as num).toDouble(), (d['lng'] as num).toDouble()))
          .toList()
          .reversed
          .toList());

  // ---- Box settings (owner) ----------------------------------------------

  Future<void> updateDetails(String deviceId, {required String name, required String patientName}) =>
      _device(deviceId).update({'name': name.trim(), 'patientName': patientName.trim()});

  Future<void> updateSettings(String deviceId, DeviceSettings settings) =>
      _device(deviceId).update({'settings': settings.toMap()});

  Future<void> updateGeofence(String deviceId, Geofence geofence) =>
      _device(deviceId).update({'geofence': geofence.toMap()});

  // ---- Cloud Functions ---------------------------------------------------

  Future<void> claimDevice({
    required String deviceId,
    required String pairingCode,
    String? name,
    String? patientName,
  }) =>
      _fn.httpsCallable('claimDevice').call({
        'deviceId': deviceId.trim(),
        'pairingCode': pairingCode.trim(),
        'name': name,
        'patientName': patientName,
      });

  Future<void> releaseDevice(String deviceId) => _fn.httpsCallable('releaseDevice').call({'deviceId': deviceId});

  /// Returns 'added', 'invited' or 'already_member'.
  Future<String> addCaregiver(String deviceId, String email) async {
    final result = await _fn.httpsCallable('addCaregiver').call({'deviceId': deviceId, 'email': email.trim()});
    return (result.data as Map)['status'] as String? ?? 'added';
  }

  Future<void> removeCaregiver(String deviceId, {String? uid, String? email}) =>
      _fn.httpsCallable('removeCaregiver').call({'deviceId': deviceId, 'uid': uid, 'email': email});
}
