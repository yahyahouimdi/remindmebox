import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';

DateTime? _date(Object? v) => v is Timestamp ? v.toDate() : null;
double? _double(Object? v) => v is num ? v.toDouble() : null;

class DeviceMember {
  const DeviceMember({required this.uid, required this.name, required this.email, required this.role});

  final String uid;
  final String name;
  final String email;

  /// 'owner' or 'caregiver'
  final String role;

  bool get isOwner => role == 'owner';
}

class DeviceSettings {
  const DeviceSettings({this.missedDoseDelayMin = 30, this.lowStockThreshold = 5});

  final int missedDoseDelayMin;
  final int lowStockThreshold;

  factory DeviceSettings.fromMap(Map<String, dynamic>? m) => DeviceSettings(
        missedDoseDelayMin: (m?['missedDoseDelayMin'] as num?)?.toInt() ?? 30,
        lowStockThreshold: (m?['lowStockThreshold'] as num?)?.toInt() ?? 5,
      );

  Map<String, dynamic> toMap() => {
        'missedDoseDelayMin': missedDoseDelayMin,
        'lowStockThreshold': lowStockThreshold,
      };
}

class Geofence {
  const Geofence({this.enabled = false, this.lat = 0, this.lng = 0, this.radiusM = 500});

  final bool enabled;
  final double lat;
  final double lng;
  final double radiusM;

  LatLng get center => LatLng(lat, lng);
  bool get hasCenter => !(lat == 0 && lng == 0);

  factory Geofence.fromMap(Map<String, dynamic>? m) => Geofence(
        enabled: m?['enabled'] as bool? ?? false,
        lat: _double(m?['lat']) ?? 0,
        lng: _double(m?['lng']) ?? 0,
        radiusM: _double(m?['radiusM']) ?? 500,
      );

  Map<String, dynamic> toMap() => {'enabled': enabled, 'lat': lat, 'lng': lng, 'radiusM': radiusM};
}

class DeviceLocation {
  const DeviceLocation({required this.position, this.accuracy, this.updatedAt});

  final LatLng position;
  final double? accuracy;
  final DateTime? updatedAt;

  static DeviceLocation? fromMap(Map<String, dynamic>? m) {
    final lat = _double(m?['lat']);
    final lng = _double(m?['lng']);
    if (lat == null || lng == null) return null;
    return DeviceLocation(
      position: LatLng(lat, lng),
      accuracy: _double(m?['accuracy']),
      updatedAt: _date(m?['updatedAt']),
    );
  }
}

class Device {
  const Device({
    required this.id,
    required this.name,
    required this.patientName,
    required this.ownerUid,
    required this.memberUids,
    required this.members,
    required this.pendingInvites,
    required this.compartmentCount,
    required this.settings,
    required this.geofence,
    required this.utcOffsetMinutes,
    this.location,
    this.lastSeen,
    this.battery,
    this.firmware,
    this.geofenceInside,
  });

  final String id;
  final String name;
  final String patientName;
  final String? ownerUid;
  final List<String> memberUids;
  final List<DeviceMember> members;
  final List<String> pendingInvites;
  final int compartmentCount;
  final DeviceSettings settings;
  final Geofence geofence;

  /// Box-local time offset, maintained by the backend from the box's time zone.
  final int utcOffsetMinutes;
  final DeviceLocation? location;
  final DateTime? lastSeen;
  final int? battery;
  final String? firmware;
  final bool? geofenceInside;

  String get displayName => patientName.isNotEmpty ? patientName : name;

  bool isOwner(String uid) => ownerUid == uid;

  /// The box sends a heartbeat every minute.
  bool get isOnline => lastSeen != null && DateTime.now().difference(lastSeen!) < const Duration(minutes: 3);

  factory Device.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    final status = d['status'] as Map<String, dynamic>? ?? const {};
    final membersMap = d['members'] as Map<String, dynamic>? ?? const {};
    final members = membersMap.entries.map((e) {
      final m = e.value as Map<String, dynamic>? ?? const {};
      return DeviceMember(
        uid: e.key,
        name: m['name'] as String? ?? '',
        email: m['email'] as String? ?? '',
        role: m['role'] as String? ?? 'caregiver',
      );
    }).toList()
      ..sort((a, b) => a.isOwner == b.isOwner ? a.name.compareTo(b.name) : (a.isOwner ? -1 : 1));

    return Device(
      id: doc.id,
      name: d['name'] as String? ?? doc.id,
      patientName: d['patientName'] as String? ?? '',
      ownerUid: d['ownerUid'] as String?,
      memberUids: List<String>.from(d['memberUids'] as List? ?? const []),
      members: members,
      pendingInvites: List<String>.from(d['pendingInvites'] as List? ?? const []),
      compartmentCount: (d['compartmentCount'] as num?)?.toInt() ?? 0,
      settings: DeviceSettings.fromMap(d['settings'] as Map<String, dynamic>?),
      geofence: Geofence.fromMap(d['geofence'] as Map<String, dynamic>?),
      utcOffsetMinutes: (d['utcOffsetMinutes'] as num?)?.toInt() ?? 60,
      location: DeviceLocation.fromMap(d['location'] as Map<String, dynamic>?),
      lastSeen: _date(status['lastSeen']),
      battery: (status['battery'] as num?)?.toInt(),
      firmware: status['firmware'] as String?,
      geofenceInside: status['geofenceInside'] as bool?,
    );
  }
}
