import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../utils/format.dart';

class Hospital {
  const Hospital({
    required this.name,
    required this.position,
    required this.kind,
    required this.distanceM,
    this.phone,
    this.address,
    this.emergency = false,
  });

  final String name;
  final LatLng position;

  /// hospital, clinic or doctors
  final String kind;
  final double distanceM;
  final String? phone;
  final String? address;
  final bool emergency;
}

/// Nearby hospitals and clinics from OpenStreetMap, via the Overpass API.
class HospitalService {
  HospitalService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  Future<List<Hospital>> nearby(LatLng center, {int radiusM = 8000}) async {
    final lat = center.latitude;
    final lng = center.longitude;
    final query = '''
[out:json][timeout:25];
(
  nwr["amenity"~"^(hospital|clinic)\$"](around:$radiusM,$lat,$lng);
  nwr["healthcare"~"^(hospital|clinic)\$"](around:$radiusM,$lat,$lng);
);
out center tags 80;
''';
    Object? lastError;
    for (final endpoint in _endpoints) {
      try {
        final response = await _client
            .post(
              Uri.parse(endpoint),
              headers: {'User-Agent': 'RemindMeBox/1.0 (medication safety app)'},
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          lastError = 'Overpass returned ${response.statusCode}';
          continue;
        }
        return parse(utf8.decode(response.bodyBytes), center);
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('Could not load hospitals: $lastError');
  }

  static List<Hospital> parse(String body, LatLng center) {
    final elements = (jsonDecode(body) as Map<String, dynamic>)['elements'] as List? ?? const [];
    final seen = <String>{};
    final result = <Hospital>[];
    for (final raw in elements.cast<Map<String, dynamic>>()) {
      final tags = (raw['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
      final c = raw['center'] as Map<String, dynamic>?;
      final lat = (raw['lat'] ?? c?['lat']) as num?;
      final lng = (raw['lon'] ?? c?['lon']) as num?;
      if (lat == null || lng == null) continue;
      final name = (tags['name:fr'] ?? tags['name'] ?? tags['name:ar'] ?? tags['name:en']) as String?;
      if (name == null || !seen.add(name)) continue;
      final position = LatLng(lat.toDouble(), lng.toDouble());
      final street = [tags['addr:housenumber'], tags['addr:street'], tags['addr:city']].whereType<String>().join(' ');
      result.add(Hospital(
        name: name,
        position: position,
        kind: (tags['amenity'] ?? tags['healthcare'] ?? 'clinic') as String,
        distanceM: distanceMeters(center, position),
        phone: (tags['phone'] ?? tags['contact:phone']) as String?,
        address: street.isEmpty ? null : street,
        emergency: tags['emergency'] == 'yes',
      ));
    }
    result.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return result;
  }
}
