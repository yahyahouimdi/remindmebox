import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

const weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String formatDays(List<int> days) {
  final sorted = [...days]..sort();
  if (sorted.length == 7) return 'Every day';
  if (sorted.length == 5 && sorted.every((d) => d <= 5)) return 'Weekdays';
  if (sorted.length == 2 && sorted.first == 6 && sorted.last == 7) return 'Weekends';
  return sorted.map((d) => weekdayShort[d - 1]).join(', ');
}

String timeAgo(DateTime? t) {
  if (t == null) return 'never';
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays < 7) return '${diff.inDays} d ago';
  return DateFormat.yMMMd().format(t);
}

String formatClock(DateTime t) => DateFormat.Hm().format(t.toLocal());

String formatDateTime(DateTime t) => DateFormat('d MMM, HH:mm').format(t.toLocal());

String formatDistance(double meters) =>
    meters < 1000 ? '${meters.round()} m' : '${(meters / 1000).toStringAsFixed(meters < 10000 ? 1 : 0)} km';

final _distance = const Distance();

double distanceMeters(LatLng a, LatLng b) => _distance.as(LengthUnit.Meter, a, b);

/// Zoom level that fits a circle of [radiusM] on a typical phone screen.
double zoomForRadius(double radiusM) => (16 - math.log(radiusM / 150) / math.ln2).clamp(3, 18).toDouble();
