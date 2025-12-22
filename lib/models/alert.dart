import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

class DeviceAlert {
  const DeviceAlert({
    required this.id,
    required this.type,
    required this.title,
    required this.message,
    required this.severity,
    required this.acknowledged,
    this.createdAt,
    this.data = const {},
  });

  final String id;

  /// missed_dose, low_stock, geofence_breach, geofence_return, sos, device_error, device_offline, low_battery
  final String type;
  final String title;
  final String message;

  /// info, warning or critical
  final String severity;
  final bool acknowledged;
  final DateTime? createdAt;
  final Map<String, dynamic> data;

  IconData get icon => switch (type) {
        'missed_dose' => Icons.medication_outlined,
        'low_stock' => Icons.inventory_2_outlined,
        'geofence_breach' => Icons.wrong_location_outlined,
        'geofence_return' => Icons.where_to_vote_outlined,
        'sos' => Icons.sos,
        'device_offline' => Icons.wifi_off,
        'low_battery' => Icons.battery_alert,
        _ => Icons.report_problem_outlined,
      };

  Color get color => switch (severity) {
        'critical' => AppColors.missed,
        'warning' => AppColors.pending,
        _ => AppColors.primaryDark,
      };

  factory DeviceAlert.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return DeviceAlert(
      id: doc.id,
      type: d['type'] as String? ?? '',
      title: d['title'] as String? ?? '',
      message: d['message'] as String? ?? '',
      severity: d['severity'] as String? ?? 'info',
      acknowledged: d['acknowledged'] as bool? ?? false,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      data: d['data'] as Map<String, dynamic>? ?? const {},
    );
  }
}
