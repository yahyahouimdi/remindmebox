import 'package:flutter_test/flutter_test.dart';
import 'package:remindmebox/models/medication.dart';
import 'package:remindmebox/utils/dose_planner.dart';

DoseEvent event(String id, DoseStatus status, {bool fromServer = false}) => DoseEvent(
      id: id,
      scheduleId: id.split('_').first,
      date: '',
      time: '',
      status: status,
      fromServer: fromServer,
    );

void main() {
  const morning = Schedule(id: 'am', time: '08:00', days: [1, 2, 3, 4, 5, 6, 7], doses: {1: 1});
  const evening = Schedule(id: 'pm', time: '20:00', days: [1, 2, 3, 4, 5, 6, 7], doses: {2: 2});
  const weekend = Schedule(id: 'we', time: '12:00', days: [6, 7], doses: {3: 1});

  // Thursday 20 Nov 2025, 09:00 in Tunis (UTC+1).
  final now = DateTime.utc(2025, 11, 20, 8, 0);

  test('event ids match the backend format', () {
    expect(doseEventId('am', DateTime.utc(2025, 11, 20)), 'am_20251120');
  });

  test('plans the box-local day and merges reported events', () {
    final plan = planDay(
      schedules: [evening, weekend, morning],
      eventsById: {'am_20251120': event('am_20251120', DoseStatus.taken)},
      nowUtc: now,
      utcOffsetMinutes: 60,
      missedDoseDelayMin: 30,
    );
    expect(plan.map((p) => p.schedule.id), ['am', 'pm']); // no weekend dose on Thursday, sorted by time
    expect(plan[0].state, DoseState.taken);
    expect(plan[0].scheduledAt, DateTime.utc(2025, 11, 20, 7, 0));
    expect(plan[1].state, DoseState.upcoming);
  });

  test('due inside the missed-dose window, missed after it', () {
    List<PlannedDose> at(DateTime t) => planDay(
          schedules: [morning],
          eventsById: const {},
          nowUtc: t,
          utcOffsetMinutes: 60,
          missedDoseDelayMin: 30,
        );
    expect(at(DateTime.utc(2025, 11, 20, 7, 10)).single.state, DoseState.due);
    expect(at(DateTime.utc(2025, 11, 20, 7, 40)).single.state, DoseState.missed);
  });

  test('uses the box date, not the UTC date, near midnight', () {
    // 23:30 UTC on Friday is already Saturday 00:30 in Tunis.
    final plan = planDay(
      schedules: [weekend],
      eventsById: const {},
      nowUtc: DateTime.utc(2025, 11, 21, 23, 30),
      utcOffsetMinutes: 60,
      missedDoseDelayMin: 30,
    );
    expect(plan.single.scheduledAt, DateTime.utc(2025, 11, 22, 11, 0));
  });

  test('paused schedules are skipped', () {
    const paused = Schedule(id: 'x', time: '10:00', days: [4], doses: {1: 1}, enabled: false);
    expect(
      planDay(schedules: [paused], eventsById: const {}, nowUtc: now, utcOffsetMinutes: 60, missedDoseDelayMin: 30),
      isEmpty,
    );
  });

  test('adherence counts finished doses only', () {
    final stats = adherence([
      event('a_1', DoseStatus.taken),
      event('b_1', DoseStatus.taken),
      event('c_1', DoseStatus.missed, fromServer: true),
      event('d_1', DoseStatus.dispensed),
    ]);
    expect(stats.taken, 2);
    expect(stats.total, 3);
    expect(stats.ratio, closeTo(.667, .001));
    expect(adherence(const []).ratio, isNull);
  });
}
