import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/device.dart';
import '../../services/device_repository.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../../widgets/device_widgets.dart';

const _tunis = LatLng(36.8065, 10.1815);

TileLayer osmTiles() => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.example.remindmebox',
    );

/// Live position of the box (GPS), recent trail and the safe zone.
class TrackScreen extends StatelessWidget {
  const TrackScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final device = session.device;
    return Scaffold(
      appBar: AppBar(
        title: const DeviceSwitcherTitle(fallback: 'Track location'),
        actions: [if (device != null) AlertsButton(device: device)],
      ),
      body: device == null
          ? const NoDeviceView()
          : _TrackBody(key: ValueKey(device.id), device: device, owner: session.ownsSelectedDevice),
    );
  }
}

class _TrackBody extends StatefulWidget {
  const _TrackBody({super.key, required this.device, required this.owner});

  final Device device;
  final bool owner;

  @override
  State<_TrackBody> createState() => _TrackBodyState();
}

class _TrackBodyState extends State<_TrackBody> {
  final _map = MapController();
  late final Stream<List<LatLng>> _trail = context.read<DeviceRepository>().locationTrail(widget.device.id);

  void _recenter() {
    final p = widget.device.location?.position;
    if (p != null) _map.move(p, 16);
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final position = device.location?.position;
    final fence = device.geofence;

    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(initialCenter: position ?? (fence.hasCenter ? fence.center : _tunis), initialZoom: 15),
        children: [
          osmTiles(),
          if (fence.enabled && fence.hasCenter)
            CircleLayer(circles: [
              CircleMarker(
                point: fence.center,
                radius: fence.radiusM,
                useRadiusInMeter: true,
                color: AppColors.primary.withValues(alpha: .15),
                borderColor: AppColors.primaryDark,
                borderStrokeWidth: 2,
              ),
            ]),
          StreamBuilder<List<LatLng>>(
            stream: _trail,
            builder: (context, snap) => PolylineLayer(polylines: [
              if ((snap.data?.length ?? 0) > 1)
                Polyline(points: snap.data!, strokeWidth: 4, color: AppColors.primaryDark.withValues(alpha: .6)),
            ]),
          ),
          if (position != null)
            MarkerLayer(markers: [
              Marker(
                point: position,
                width: 56,
                height: 56,
                child: const Icon(Icons.person_pin_circle, color: AppColors.missed, size: 52),
              ),
            ]),
          const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
        ],
      ),
      Positioned(
        left: 12,
        right: 12,
        top: 12,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(device.displayName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              Text(position == null
                  ? 'No GPS position received yet. The box needs a clear view of the sky.'
                  : 'Last position ${timeAgo(device.location!.updatedAt)}'
                      '${device.location!.accuracy != null ? ' · ±${device.location!.accuracy!.round()} m' : ''}'),
              const SizedBox(height: 6),
              DeviceStatusBar(device: device),
            ]),
          ),
        ),
      ),
      Positioned(
        right: 16,
        bottom: 16,
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (position != null)
            FloatingActionButton.small(
              heroTag: 'recenter',
              onPressed: _recenter,
              child: const Icon(Icons.my_location),
            ),
          if (widget.owner) ...[
            const SizedBox(height: 8),
            FloatingActionButton.extended(
              heroTag: 'geofence',
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => GeofenceSheet(device: device),
              ),
              icon: const Icon(Icons.radar),
              label: Text(fence.enabled ? 'Safe zone: ${formatDistance(fence.radiusM)}' : 'Set safe zone'),
            ),
          ],
        ]),
      ),
    ]);
  }
}

/// The owner sets a circle around home; leaving it alerts every caregiver.
class GeofenceSheet extends StatefulWidget {
  const GeofenceSheet({super.key, required this.device});

  final Device device;

  @override
  State<GeofenceSheet> createState() => _GeofenceSheetState();
}

class _GeofenceSheetState extends State<GeofenceSheet> {
  late bool _enabled = widget.device.geofence.enabled || !widget.device.geofence.hasCenter;
  late double _radius = widget.device.geofence.radiusM.clamp(100, 5000).toDouble();
  late LatLng? _center = widget.device.geofence.hasCenter
      ? widget.device.geofence.center
      : widget.device.location?.position;

  @override
  Widget build(BuildContext context) {
    final center = _center;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.viewInsetsOf(context).bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Safe zone', style: Theme.of(context).textTheme.titleLarge),
        const Text('Caregivers are alerted when the box leaves this area.', style: TextStyle(color: Colors.black54)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Enabled'),
          value: _enabled,
          onChanged: (v) => setState(() => _enabled = v),
        ),
        Text('Radius: ${formatDistance(_radius)}'),
        Slider(value: _radius, min: 100, max: 5000, divisions: 49, onChanged: (v) => setState(() => _radius = v)),
        if (center != null)
          SizedBox(
            height: 200,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: FlutterMap(
                key: ValueKey(_radius),
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: zoomForRadius(_radius),
                  onTap: (_, p) => setState(() => _center = p),
                ),
                children: [
                  osmTiles(),
                  CircleLayer(circles: [
                    CircleMarker(
                      point: center,
                      radius: _radius,
                      useRadiusInMeter: true,
                      color: AppColors.primary.withValues(alpha: .2),
                      borderColor: AppColors.primaryDark,
                      borderStrokeWidth: 2,
                    ),
                  ]),
                ],
              ),
            ),
          )
        else
          const Text('Waiting for the first GPS position of the box to place the zone.',
              style: TextStyle(color: AppColors.pending)),
        if (center != null)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Tap the map to move the centre.', style: TextStyle(color: Colors.black45)),
          ),
        const SizedBox(height: 16),
        BusyButton(
          label: 'Save safe zone',
          onPressed: center == null
              ? null
              : () async {
                  final ok = await runGuarded(
                    context,
                    () => context.read<DeviceRepository>().updateGeofence(
                          widget.device.id,
                          Geofence(enabled: _enabled, lat: center.latitude, lng: center.longitude, radiusM: _radius),
                        ),
                    success: 'Safe zone saved.',
                  );
                  if (ok && context.mounted) Navigator.pop(context);
                },
        ),
      ]),
    );
  }
}
