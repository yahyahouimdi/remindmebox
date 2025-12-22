import 'package:cloud_firestore/cloud_firestore.dart';

class Compartment {
  const Compartment({required this.index, this.medicationName = '', this.quantity = 0, this.notes = ''});

  final int index;
  final String medicationName;
  final int quantity;
  final String notes;

  bool get isEmpty => medicationName.isEmpty;

  String get label => medicationName.isEmpty ? 'Compartment $index' : medicationName;

  factory Compartment.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return Compartment(
      index: (d['index'] as num?)?.toInt() ?? int.tryParse(doc.id) ?? 0,
      medicationName: d['medicationName'] as String? ?? '',
      quantity: (d['quantity'] as num?)?.toInt() ?? 0,
      notes: d['notes'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'index': index,
        'medicationName': medicationName,
        'quantity': quantity,
        'notes': notes,
        'updatedAt': FieldValue.serverTimestamp(),
      };
}

/// A recurring dose: at [time] (box-local "HH:mm") on [days] (ISO, 1 = Monday),
/// dispense `count` pills from each compartment in [doses].
class Schedule {
  const Schedule({
    required this.id,
    required this.time,
    required this.days,
    required this.doses,
    this.label = '',
    this.enabled = true,
  });

  final String id;
  final String label;
  final String time;
  final List<int> days;
  final Map<int, int> doses;
  final bool enabled;

  int get hour => int.parse(time.split(':')[0]);
  int get minute => int.parse(time.split(':')[1]);
  int get minutesOfDay => hour * 60 + minute;

  int get pillCount => doses.values.fold(0, (a, b) => a + b);

  factory Schedule.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    final rawDoses = d['doses'] as Map<String, dynamic>? ?? const {};
    return Schedule(
      id: doc.id,
      label: d['label'] as String? ?? '',
      time: d['time'] as String? ?? '08:00',
      days: List<int>.from((d['days'] as List? ?? const []).whereType<num>().map((n) => n.toInt()))..sort(),
      doses: {
        for (final e in rawDoses.entries)
          if (int.tryParse(e.key) != null && e.value is num) int.parse(e.key): (e.value as num).toInt(),
      },
      enabled: d['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toMap() => {
        'label': label,
        'time': time,
        'days': days,
        'doses': {for (final e in doses.entries) '${e.key}': e.value},
        'enabled': enabled,
        'updatedAt': FieldValue.serverTimestamp(),
      };
}

enum DoseStatus { dispensed, taken, missed, failed }

class DoseEvent {
  const DoseEvent({
    required this.id,
    required this.scheduleId,
    required this.date,
    required this.time,
    required this.status,
    required this.fromServer,
    this.scheduledAt,
    this.dispensedAt,
    this.takenAt,
    this.error,
  });

  final String id;
  final String scheduleId;

  /// Box-local date, "yyyy-MM-dd".
  final String date;
  final String time;
  final DoseStatus status;

  /// True when the backend inferred the status because the box never reported.
  final bool fromServer;
  final DateTime? scheduledAt;
  final DateTime? dispensedAt;
  final DateTime? takenAt;
  final String? error;

  factory DoseEvent.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    DateTime? ts(String key) => (d[key] as Timestamp?)?.toDate();
    return DoseEvent(
      id: doc.id,
      scheduleId: d['scheduleId'] as String? ?? '',
      date: d['date'] as String? ?? '',
      time: d['time'] as String? ?? '',
      status: DoseStatus.values.firstWhere((s) => s.name == d['status'], orElse: () => DoseStatus.missed),
      fromServer: d['source'] == 'server',
      scheduledAt: ts('scheduledAt'),
      dispensedAt: ts('dispensedAt'),
      takenAt: ts('takenAt'),
      error: d['error'] as String?,
    );
  }
}
