import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// First-time setup of a box over Bluetooth LE: read its ID and send it the
/// home WiFi credentials. UUIDs must match firmware/remindmebox_esp32/config.h.
class ProvisioningService {
  static final serviceUuid = Guid('6e0a0001-7c5f-4b8e-9d3a-52454d494e44');
  static final infoUuid = Guid('6e0a0002-7c5f-4b8e-9d3a-52454d494e44');
  static final wifiUuid = Guid('6e0a0003-7c5f-4b8e-9d3a-52454d494e44');
  static final statusUuid = Guid('6e0a0004-7c5f-4b8e-9d3a-52454d494e44');

  Future<bool> get isSupported => FlutterBluePlus.isSupported;

  Stream<BluetoothAdapterState> get adapterState => FlutterBluePlus.adapterState;

  /// Boxes in setup mode advertise the RemindMeBox service.
  Stream<List<ScanResult>> scan({Duration timeout = const Duration(seconds: 12)}) {
    FlutterBluePlus.startScan(withServices: [serviceUuid], timeout: timeout);
    return FlutterBluePlus.scanResults;
  }

  Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  /// Connects, reads the box identity, sends the WiFi credentials and waits
  /// until the box confirms it reached the internet. Returns the device ID.
  Future<BoxInfo> provision(
    BluetoothDevice device, {
    required String ssid,
    required String password,
    void Function(String status)? onStatus,
  }) async {
    await stopScan();
    onStatus?.call('Connecting to the box…');
    await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 20));
    try {
      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == serviceUuid,
        orElse: () => throw Exception('This device is not a RemindMeBox.'),
      );
      BluetoothCharacteristic char(Guid id) => service.characteristics.firstWhere((c) => c.uuid == id);

      final info = BoxInfo.fromJson(jsonDecode(utf8.decode(await char(infoUuid).read())) as Map<String, dynamic>);

      final statusChar = char(statusUuid);
      await statusChar.setNotifyValue(true);
      final result = Completer<String>();
      final sub = statusChar.onValueReceived.listen((value) {
        final status = utf8.decode(value);
        if (status == 'connecting') onStatus?.call('The box is joining "$ssid"…');
        if ((status == 'connected' || status == 'failed') && !result.isCompleted) result.complete(status);
      });

      onStatus?.call('Sending WiFi settings…');
      await char(wifiUuid).write(utf8.encode(jsonEncode({'ssid': ssid, 'password': password})));
      final status = await result.future.timeout(
        const Duration(seconds: 40),
        onTimeout: () => 'timeout',
      );
      await sub.cancel();
      if (status == 'failed') throw Exception('The box could not join "$ssid". Check the password and try again.');
      if (status == 'timeout') throw Exception('The box did not answer. Move closer and try again.');
      return info;
    } finally {
      // The box reboots after a successful setup, which also drops the link.
      await device.disconnect().catchError((_) {});
    }
  }
}

class BoxInfo {
  const BoxInfo({required this.deviceId, required this.compartments, required this.firmware});

  final String deviceId;
  final int compartments;
  final String firmware;

  factory BoxInfo.fromJson(Map<String, dynamic> json) => BoxInfo(
        deviceId: json['deviceId'] as String,
        compartments: (json['compartments'] as num?)?.toInt() ?? 0,
        firmware: json['firmware'] as String? ?? '',
      );
}
