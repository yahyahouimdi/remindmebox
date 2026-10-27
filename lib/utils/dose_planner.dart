import '../models/medication.dart';

enum DoseState {
  /// Later today.
  upcoming,

  /// Time has come, the box has not reported yet.
  due,

  /// In the tray, waiting to be picked up.
  dispensed,
  taken,
  missed,
  failed,
}

class PlannedDose {
  const PlannedDose({required this.schedule, required this.scheduledAt, required this.state, this.event});

  final Schedule schedule;

  /// The instant of the dose (UTC), shown in the phone's local time.
  final DateTime scheduledAt;
  final DoseState state;
  final DoseEvent? event;
}

String _pad(int n) => n.toString().padLeft(2, '0');

/// "2025-11-20", same format as the firmware and the backend.
String dateKey(DateTime d) => '${d.year}-${_pad(d.month)}-${_pad(d.day)}';

/// Same deterministic id as the backend: `<scheduleId>_<yyyyMMdd>`.
String doseEventId(String scheduleId, DateTime boxDate) => '${scheduleId}_${dateKey(boxDate).replaceAll('-', '')}';

/// The box's wall-clock "now", as a UTC DateTime whose fields read as box-local time.
DateTime boxNow(DateTime nowUtc, int utcOffsetMinutes) => nowUtc.toUtc().add(Duration(minutes: utcOffsetMinutes));

/// All doses of one box-local day, merged with what the box reported.
List<PlannedDose> planDay({
  required List<Schedule> schedules,
  required Map<String, DoseEvent> eventsById,
  required DateTime nowUtc,
  required int utcOffsetMinutes,
  required int missedDoseDelayMin,
  int dayOffset = 0,
}) {
  final local = boxNow(nowUtc, utcOffsetMinutes);
  final day = DateTime.utc(local.year, local.month, local.day + dayOffset);
  final plan = <PlannedDose>[];

  for (final s in schedules) {
    if (!s.enabled || !s.days.contains(day.weekday)) continue;
    final scheduledAt = DateTime.utc(day.year, day.month, day.day, s.hour, s.minute)
        .subtract(Duration(minutes: utcOffsetMinutes));
    final event = eventsById[doseEventId(s.id, day)];
    final DoseState state;
    if (event != null) {
      state = switch (event.status) {
        DoseStatus.dispensed => DoseState.dispensed,
        DoseStatus.taken => DoseState.taken,
        DoseStatus.missed => DoseState.missed,
        DoseStatus.failed => DoseState.failed,
      };
    } else if (nowUtc.isBefore(scheduledAt)) {
      state = DoseState.upcoming;
    } else if (nowUtc.isBefore(scheduledAt.add(Duration(minutes: missedDoseDelayMin)))) {
      state = DoseState.due;
    } else {
      // Past the deadline with no report: the backend monitor will confirm it as missed.
      state = DoseState.missed;
    }
    plan.add(PlannedDose(schedule: s, scheduledAt: scheduledAt, state: state, event: event));
  }
  plan.sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
  return plan;
}

class Adherence {
  const Adherence(this.taken, this.total);

  final int taken;
  final int total;

  double? get ratio => total == 0 ? null : taken / total;
}

/// Share of finished doses that were actually taken.
Adherence adherence(Iterable<DoseEvent> events) {
  var taken = 0;
  var total = 0;
  for (final e in events) {
    if (e.status == DoseStatus.dispensed) continue;
    total++;
    if (e.status == DoseStatus.taken) taken++;
  }
  return Adherence(taken, total);
}
