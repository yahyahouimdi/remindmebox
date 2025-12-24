import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:remindmebox/services/hospital_service.dart';

void main() {
  test('parses Overpass nodes and ways, dedupes and sorts by distance', () {
    final body = jsonEncode({
      'elements': [
        {
          'type': 'way',
          'center': {'lat': 36.8065, 'lon': 10.2000},
          'tags': {'amenity': 'hospital', 'name': 'Hôpital Charles Nicolle', 'emergency': 'yes', 'phone': '+216 71 000 000'},
        },
        {
          'type': 'node',
          'lat': 36.8070,
          'lon': 10.1820,
          'tags': {'amenity': 'clinic', 'name': 'Clinique du Lac'},
        },
        {
          'type': 'node',
          'lat': 36.9,
          'lon': 10.3,
          'tags': {'amenity': 'clinic', 'name': 'Clinique du Lac'},
        },
        {
          'type': 'node',
          'lat': 36.81,
          'lon': 10.19,
          'tags': {'amenity': 'clinic'},
        },
      ],
    });
    final result = HospitalService.parse(body, const LatLng(36.8065, 10.1815));
    expect(result.map((h) => h.name), ['Clinique du Lac', 'Hôpital Charles Nicolle']);
    expect(result.first.distanceM, lessThan(100));
    expect(result.last.emergency, isTrue);
    expect(result.last.kind, 'hospital');
    expect(result.last.phone, '+216 71 000 000');
  });
}
