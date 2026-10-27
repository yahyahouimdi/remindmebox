import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/hospital_service.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../track/track_screen.dart';

/// Nearby hospitals and clinics (OpenStreetMap / Overpass), around the box
/// when it has a GPS fix, otherwise around this phone.
class HospitalMapScreen extends StatefulWidget {
  const HospitalMapScreen({super.key});

  @override
  State<HospitalMapScreen> createState() => _HospitalMapScreenState();
}

class _HospitalMapScreenState extends State<HospitalMapScreen> {
  final _map = MapController();
  final _search = TextEditingController();
  LatLng? _center;
  String _centerLabel = '';
  List<Hospital> _hospitals = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<LatLng?> _phonePosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 15)),
      );
      return LatLng(p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load({bool usePhone = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final device = context.read<Session>().device;
    final hospitalService = context.read<HospitalService>();
    LatLng? center;
    String label;
    if (!usePhone && device?.location != null) {
      center = device!.location!.position;
      label = 'Around ${device.displayName}';
    } else {
      center = await _phonePosition();
      label = 'Around you';
    }
    if (center == null) {
      center = const LatLng(36.8065, 10.1815);
      label = 'Around Tunis (location unavailable)';
    }
    try {
      final hospitals = await hospitalService.nearby(center);
      if (!mounted) return;
      setState(() {
        _center = center;
        _centerLabel = label;
        _hospitals = hospitals;
        _loading = false;
      });
      _map.move(center, 13);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _center = center;
        _centerLabel = label;
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  List<Hospital> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return q.isEmpty ? _hospitals : _hospitals.where((h) => h.name.toLowerCase().contains(q)).toList();
  }

  void _showDetails(Hospital h) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(h.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text([
            h.kind == 'hospital' ? 'Hospital' : 'Clinic',
            if (h.emergency) 'Emergency department',
            formatDistance(h.distanceM),
          ].join(' · ')),
          if (h.address != null) Text(h.address!, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => launchUrl(
              Uri.parse('https://www.openstreetmap.org/directions?route=%3B${h.position.latitude}%2C${h.position.longitude}'
                  '${_center == null ? '' : '&from=${_center!.latitude}%2C${_center!.longitude}'}'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.directions),
            label: const Text('Directions'),
          ),
          if (h.phone != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => launchUrl(Uri(scheme: 'tel', path: h.phone!.split(';').first.replaceAll(' ', ''))),
              icon: const Icon(Icons.call),
              label: Text('Call ${h.phone!.split(';').first}'),
            ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hospitals = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby hospitals'),
        actions: [
          IconButton(
            tooltip: 'Call SAMU (190)',
            onPressed: () => launchUrl(Uri(scheme: 'tel', path: '190')),
            icon: const Icon(Icons.emergency),
          ),
          IconButton(tooltip: 'Use my location', onPressed: () => _load(usePhone: true), icon: const Icon(Icons.my_location)),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Search hospitals…',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
          ),
        ),
        if (_centerLabel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_centerLabel, style: const TextStyle(color: Colors.black54)),
            ),
          ),
        Expanded(
          flex: 3,
          child: Stack(children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(initialCenter: _center ?? const LatLng(36.8065, 10.1815), initialZoom: 12),
              children: [
                osmTiles(),
                MarkerLayer(markers: [
                  if (_center != null)
                    Marker(point: _center!, child: const Icon(Icons.person_pin_circle, color: AppColors.primaryDark, size: 40)),
                  for (final h in hospitals)
                    Marker(
                      point: h.position,
                      width: 36,
                      height: 36,
                      child: GestureDetector(
                        onTap: () => _showDetails(h),
                        child: Icon(Icons.local_hospital, color: h.kind == 'hospital' ? AppColors.missed : AppColors.pending, size: 32),
                      ),
                    ),
                ]),
                const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
              ],
            ),
            if (_loading) const Center(child: CircularProgressIndicator()),
          ]),
        ),
        Expanded(
          flex: 2,
          child: _error != null
              ? EmptyState(
                  icon: Icons.cloud_off,
                  title: 'Could not load hospitals',
                  message: _error,
                  action: OutlinedButton(onPressed: _load, child: const Text('Retry')),
                )
              : ListView.builder(
                  itemCount: hospitals.length,
                  itemBuilder: (context, i) {
                    final h = hospitals[i];
                    return ListTile(
                      leading: Icon(Icons.local_hospital, color: h.kind == 'hospital' ? AppColors.missed : AppColors.pending),
                      title: Text(h.name),
                      subtitle: Text('${h.kind == 'hospital' ? 'Hospital' : 'Clinic'}${h.emergency ? ' · Emergency' : ''}'),
                      trailing: Text(formatDistance(h.distanceM)),
                      onTap: () {
                        _map.move(h.position, 15);
                        _showDetails(h);
                      },
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
