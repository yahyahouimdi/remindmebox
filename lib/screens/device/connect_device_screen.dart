import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../../services/device_repository.dart';
import '../../services/provisioning_service.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../schedule/compartments_screen.dart';

/// Super User onboarding of a box:
///  1. (first time) send the home WiFi to the box over Bluetooth;
///  2. link it to the account with the ID + pairing code shown on its screen.
class ConnectDeviceScreen extends StatefulWidget {
  const ConnectDeviceScreen({super.key});

  @override
  State<ConnectDeviceScreen> createState() => _ConnectDeviceScreenState();
}

class _ConnectDeviceScreenState extends State<ConnectDeviceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _deviceId = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _patient = TextEditingController();

  @override
  void dispose() {
    for (final c in [_deviceId, _code, _name, _patient]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _claim() async {
    if (!_formKey.currentState!.validate()) return;
    final deviceId = _deviceId.text.trim();
    final ok = await runGuarded(
      context,
      () => context.read<DeviceRepository>().claimDevice(
            deviceId: deviceId,
            pairingCode: _code.text,
            name: _name.text.trim().isEmpty ? null : _name.text.trim(),
            patientName: _patient.text.trim().isEmpty ? null : _patient.text.trim(),
          ),
      success: 'Box connected!',
    );
    if (!ok || !mounted) return;
    final session = context.read<Session>();
    session.selectDevice(deviceId);
    // Wait for the box to appear in the live list, then go fill its compartments.
    final device = await Stream.periodic(const Duration(milliseconds: 300))
        .map((_) => session.devices.where((d) => d.id == deviceId).firstOrNull)
        .firstWhere((d) => d != null)
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
    if (!mounted) return;
    if (device == null) {
      Navigator.pop(context);
      return;
    }
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => CompartmentsScreen(device: device)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect device')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (!kIsWeb) ...[
          _BluetoothSetupCard(onProvisioned: (info) => setState(() => _deviceId.text = info.deviceId)),
          const SizedBox(height: 12),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('2. Link the box to your account',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text('The ID and pairing code are shown on the box screen and printed on its label.',
                    style: TextStyle(color: Colors.black54)),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _deviceId,
                  decoration: const InputDecoration(labelText: 'Device ID', prefixIcon: Icon(Icons.perm_device_information)),
                  validator: (v) =>
                      RegExp(r'^[A-Za-z0-9_-]{4,40}$').hasMatch(v?.trim() ?? '') ? null : 'Enter the ID, e.g. RMB-0001',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Pairing code', prefixIcon: Icon(Icons.password)),
                  validator: (v) => (v?.trim().length ?? 0) < 4 ? 'Enter the pairing code' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _patient,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Who uses this box? (optional)',
                    hintText: 'e.g. Grandma Fatma',
                    prefixIcon: Icon(Icons.elderly),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Box name (optional)',
                    hintText: 'e.g. Kitchen box',
                    prefixIcon: Icon(Icons.label_outline),
                  ),
                ),
                const SizedBox(height: 20),
                BusyButton(label: 'Connect', onPressed: _claim),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _BluetoothSetupCard extends StatefulWidget {
  const _BluetoothSetupCard({required this.onProvisioned});

  final ValueChanged<BoxInfo> onProvisioned;

  @override
  State<_BluetoothSetupCard> createState() => _BluetoothSetupCardState();
}

class _BluetoothSetupCardState extends State<_BluetoothSetupCard> {
  late final ProvisioningService _ble = context.read<ProvisioningService>();
  StreamSubscription<List<ScanResult>>? _scanSub;
  List<ScanResult> _results = const [];
  bool _scanning = false;
  String? _progress;

  @override
  void dispose() {
    _scanSub?.cancel();
    _ble.stopScan();
    super.dispose();
  }

  Future<void> _scan() async {
    if (!await _ble.isSupported) {
      if (mounted) showSnack(context, 'Bluetooth is not available on this phone.', error: true);
      return;
    }
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await FlutterBluePlus.turnOn().catchError((_) {});
      } else if (mounted) {
        showSnack(context, 'Turn on Bluetooth first.', error: true);
        return;
      }
    }
    setState(() {
      _scanning = true;
      _results = const [];
    });
    await _scanSub?.cancel();
    try {
      _scanSub = _ble.scan().listen((r) => setState(() => _results = r));
      await _ble.isScanning.where((s) => !s).first;
    } catch (e) {
      if (mounted) showSnack(context, 'Scan failed: $e', error: true);
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _provision(ScanResult result) async {
    final creds = await showDialog<(String, String)>(context: context, builder: (_) => const _WifiDialog());
    if (creds == null || !mounted) return;
    try {
      final info = await _ble.provision(
        result.device,
        ssid: creds.$1,
        password: creds.$2,
        onStatus: (s) => setState(() => _progress = s),
      );
      widget.onProvisioned(info);
      if (mounted) showSnack(context, 'Box ${info.deviceId} is online. Now enter its pairing code below.');
    } catch (e) {
      if (mounted) showSnack(context, e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('1. Put the box online (first time only)',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            'A new box shows "Setup mode" on its screen. Keep the phone close and send it your WiFi. '
            'Skip this step if the box already shows "Online".',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 12),
          if (_progress != null)
            ListTile(
              leading: const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
              title: Text(_progress!),
            )
          else ...[
            OutlinedButton.icon(
              onPressed: _scanning ? null : _scan,
              icon: _scanning
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bluetooth_searching),
              label: Text(_scanning ? 'Searching for boxes…' : 'Find boxes nearby'),
            ),
            for (final r in _results)
              ListTile(
                leading: const Icon(Icons.inventory_2_outlined, color: AppColors.primaryDark),
                title: Text(r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.remoteId.str),
                subtitle: Text('Signal ${r.rssi} dBm'),
                trailing: const Icon(Icons.wifi),
                onTap: () => _provision(r),
              ),
            if (!_scanning && _results.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No box found yet.', style: TextStyle(color: Colors.black45)),
              ),
          ],
        ]),
      ),
    );
  }
}

class _WifiDialog extends StatefulWidget {
  const _WifiDialog();

  @override
  State<_WifiDialog> createState() => _WifiDialogState();
}

class _WifiDialogState extends State<_WifiDialog> {
  final _ssid = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('WiFi for the box'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('The box supports 2.4 GHz networks.', style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 12),
        TextField(controller: _ssid, decoration: const InputDecoration(labelText: 'Network name (SSID)')),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_ssid.text.trim().isEmpty) return;
            Navigator.pop(context, (_ssid.text.trim(), _password.text));
          },
          child: const Text('Send'),
        ),
      ],
    );
  }
}
