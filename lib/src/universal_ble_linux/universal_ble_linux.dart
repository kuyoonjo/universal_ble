// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:typed_data';

import 'package:bluez/bluez.dart';
import 'package:collection/collection.dart';
import 'package:universal_ble/src/models/model_exports.dart';
import 'package:universal_ble/src/universal_ble_platform_interface.dart';

class UniversalBleLinux extends UniversalBlePlatform {
  UniversalBleLinux._();
  static UniversalBleLinux? _instance;
  static UniversalBleLinux get instance => _instance ??= UniversalBleLinux._();

  bool isInitialized = false;

  final BlueZClient _client = BlueZClient();

  BlueZAdapter? _activeAdapter;
  final Map<String, BlueZDevice> _devices = {};
  final Map<String, StreamSubscription> _deviceStreamSubscriptions = {};
  final Map<String, StreamSubscription> _characteristicPropertiesSubscriptions =
      {};

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async {
    await _ensureInitialized();
    BlueZAdapter? adapter = _activeAdapter;
    if (adapter == null) {
      return AvailabilityState.unsupported;
    }
    return adapter.powered
        ? AvailabilityState.poweredOn
        : AvailabilityState.poweredOff;
  }

  @override
  Future<bool> enableBluetooth() async {
    await _ensureInitialized();
    if (_activeAdapter?.powered == true) return true;
    await _activeAdapter?.setPowered(true);
    return _activeAdapter?.powered ?? false;
  }

  @override
  Future<void> startScan({
    WebRequestOptionsBuilder? webRequestOptions,
  }) async {
    await _ensureInitialized();

    if (!_activeAdapter!.discovering) {
      _activeAdapter!.startDiscovery();
      _client.devices.forEach(_onDeviceAdd);
    }
  }

  @override
  Future<void> stopScan() async {
    await _ensureInitialized();
    var adapter = _activeAdapter;
    if (adapter != null && adapter.discovering) {
      adapter.stopDiscovery();
    }
  }

  @override
  Future<void> connect(String deviceId, {Duration? connectionTimeout}) async {
    await _findDeviceById(deviceId).connect();
  }

  @override
  Future<void> disconnect(String deviceId) async {
    await _findDeviceById(deviceId).disconnect();
  }

  @override
  Future<List<BleService>> discoverServices(String deviceId) async {
    var device = _findDeviceById(deviceId);
    if (!device.servicesResolved) {
      await device.propertiesChanged
          .firstWhere(
              (element) => element.contains(BluezProperty.servicesResolved))
          .timeout(const Duration(seconds: 2), onTimeout: () => []);
    }

    // while (!device.servicesResolved) {
    //   await Future.delayed(const Duration(seconds: 200));
    // }

    List<BleService> services = [];
    for (var service in device.gattServices) {
      var characteristics = service.characteristics.map((e) {
        var properties = List<CharacteristicProperty>.from(e.flags
            .map((e) => e.toCharacteristicProperty())
            .where((element) => element != null)
            .toList());
        return BleCharacteristic(e.uuid.toString(), properties);
      }).toList();
      services.add(BleService(service.uuid.toString(), characteristics));
    }
    return services;
  }

  BlueZGattCharacteristic _getCharacteristic(
      String deviceId, String service, String characteristic) {
    var device = _findDeviceById(deviceId);
    var s = device.gattServices
        .firstWhereOrNull((s) => s.uuid.toString() == service);
    var c = s?.characteristics
        .firstWhereOrNull((c) => c.uuid.toString() == characteristic);

    if (c == null) {
      throw Exception('Unknown characteristic:$characteristic');
    }
    return c;
  }

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    var char = _getCharacteristic(deviceId, service, characteristic);
    if (bleInputProperty != BleInputProperty.disabled) {
      char.startNotify();

      if (_characteristicPropertiesSubscriptions[characteristic] != null) {
        _characteristicPropertiesSubscriptions[characteristic]?.cancel();
      }

      _characteristicPropertiesSubscriptions[characteristic] =
          char.propertiesChanged.listen((List<String> properties) {
        for (String property in properties) {
          switch (property) {
            case BluezProperty.value:
              onValueChanged?.call(
                deviceId,
                characteristic,
                Uint8List.fromList(char.value),
              );
              break;
            default:
              print("UnhandledCharValuePropertyChange: $property");
          }
        }
      });
    } else {
      char.stopNotify();
      _characteristicPropertiesSubscriptions.remove(characteristic)?.cancel();
    }
  }

  @override
  Future<Uint8List> readValue(
      String deviceId, String service, String characteristic) async {
    var c = _getCharacteristic(deviceId, service, characteristic);
    var data = await c.readValue();
    return Uint8List.fromList(data);
  }

  @override
  Future<void> writeValue(
      String deviceId,
      String service,
      String characteristic,
      Uint8List value,
      BleOutputProperty bleOutputProperty) async {
    var c = _getCharacteristic(deviceId, service, characteristic);

    if (bleOutputProperty == BleOutputProperty.withResponse) {
      await c.writeValue(value, type: BlueZGattCharacteristicWriteType.request);
    } else {
      await c.writeValue(value, type: BlueZGattCharacteristicWriteType.command);
    }
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    // var device = _findDeviceById(deviceId);
    // if (!device.connected) return 0;
    // for (BlueZGattService service in device.gattServices) {
    //   for (BlueZGattCharacteristic characteristic in service.characteristics) {
    //     // The value provided by Bluez includes an extra 3 bytes from the GATT header, which needs to be removed.
    //     // requires `int? get mtu => _object.getUint16Property(_gattCharacteristicInterfaceName, 'MTU');` to add in bluez.dart
    //      return characteristic.mtu - 3;
    //   }
    // }
    // return 0;
    throw UnimplementedError();
  }

  @override
  Future<void> pair(String deviceId) async {
    BlueZDevice device = _findDeviceById(deviceId);
    await device.pair();
  }

  @override
  Future<void> unPair(String deviceId) async {
    BlueZDevice device = _findDeviceById(deviceId);
    if (device.paired) {
      // await device.cancelPairing();
      await _activeAdapter?.removeDevice(device);
    }
  }

  @override
  Future<bool> isPaired(String deviceId) async {
    return _findDeviceById(deviceId).paired;
  }

  @override
  Future<List<BleScanResult>> getConnectedDevices(
    List<String>? withServices,
  ) async {
    List<BlueZDevice> devices = _client.devices;
    if (withServices != null && withServices.isNotEmpty) {
      return devices
          .where((device) {
            if (device.servicesResolved) {
              return device.gattServices
                  .map((e) => e.uuid.toString())
                  .any((service) => withServices.contains(service));
            }
            return true;
          })
          .map((device) => device.toBleScanResult())
          .toList();
    }
    return devices.map((device) => device.toBleScanResult()).toList();
  }

  AvailabilityState get _availabilityState {
    return _activeAdapter!.powered
        ? AvailabilityState.poweredOn
        : AvailabilityState.poweredOff;
  }

  BlueZDevice _findDeviceById(String deviceId) {
    var device = _devices[deviceId] ??
        _client.devices
            .firstWhereOrNull((device) => device.address == deviceId);
    if (device == null) {
      throw Exception('Unknown deviceId:$deviceId');
    }
    return device;
  }

  Future<void> _ensureInitialized() async {
    if (!isInitialized) {
      await _client.connect();

      _activeAdapter ??=
          _client.adapters.firstWhereOrNull((adapter) => adapter.powered);

      if (_activeAdapter == null) {
        if (_client.adapters.isEmpty) {
          throw Exception('Bluetooth adapter unavailable');
        }
        await _client.adapters.first.setPowered(true);
        _activeAdapter = _client.adapters.first;
      }

      _client.deviceAdded.listen(_onDeviceAdd);
      _client.deviceRemoved.listen(_onDeviceRemoved);

      _activeAdapter?.propertiesChanged.listen((List<String> properties) {
        // Handle pairing state change
        for (var property in properties) {
          switch (property) {
            case BluezProperty.powered:
              onAvailabilityChange?.call(_availabilityState);
              break;
            case BluezProperty.discoverable:
            case BluezProperty.discovering:
              break;
            default:
              print("UnhandledPropertyChanged: $property");
          }
        }
      });

      onAvailabilityChange?.call(_availabilityState);
      isInitialized = true;
    }
  }

  void _onDeviceAdd(BlueZDevice device) {
    // Update ScanResults
    onScanResult?.call(device.toBleScanResult());

    // Setup Cache
    _devices[device.address] = device;

    // Setup update listener
    if (_deviceStreamSubscriptions[device.address] != null) {
      _deviceStreamSubscriptions[device.address]?.cancel();
    }
    _deviceStreamSubscriptions[device.address] =
        device.propertiesChanged.listen((properties) {
      for (var property in properties) {
        switch (property) {
          case BluezProperty.rssi:
            onScanResult?.call(device.toBleScanResult());
            break;
          case BluezProperty.connected:
            onConnectionChanged?.call(
              device.address,
              device.connected
                  ? BleConnectionState.connected
                  : BleConnectionState.disconnected,
            );
            break;
          case BluezProperty.manufacturerData:
            onScanResult?.call(device.toBleScanResult());
            break;
          case BluezProperty.paired:
            onPairStateChange?.call(device.address, device.paired, null);
            break;
          case BluezProperty.legacyPairing:
          case BluezProperty.servicesResolved:
          case BluezProperty.uuids:
            break;
          default:
            print("UnhandledDevicePropertyChanged: $property");
            break;
        }
      }
    });
  }

  void _onDeviceRemoved(BlueZDevice device) {
    _devices.remove(device.address);

    // Stop listener
    _deviceStreamSubscriptions[device.address]?.cancel();
    _deviceStreamSubscriptions
        .removeWhere((key, value) => key == device.address);
  }
}

class BluezProperty {
  static const String rssi = 'RSSI';
  static const String connected = 'Connected';
  static const String manufacturerData = 'ManufacturerData';
  static const String legacyPairing = 'LegacyPairing';
  static const String servicesResolved = 'ServicesResolved';
  static const String paired = 'Paired';
  static const String address = 'Address';
  static const String addressType = 'AddressType';
  static const String modalias = 'Modalias';
  static const String uuids = 'UUIDs';
  static const String value = 'Value';
  static const String powered = 'Powered';
  static const String discoverable = 'Discoverable';
  static const String discovering = 'Discovering';
}

extension BlueZDeviceExtension on BlueZDevice {
  Uint8List get manufacturerDataHead {
    if (manufacturerData.isEmpty) return Uint8List(0);

    final sorted = manufacturerData.entries.toList()
      ..sort((a, b) => a.key.id - b.key.id);
    return Uint8List.fromList(sorted.first.value);
  }

  BleScanResult toBleScanResult() {
    return BleScanResult(
      name: alias,
      deviceId: address,
      isPaired: paired,
      manufacturerData: manufacturerDataHead,
      manufacturerDataHead: manufacturerDataHead,
      rssi: rssi,
    );
  }
}

extension on BlueZGattCharacteristicFlag {
  CharacteristicProperty? toCharacteristicProperty() {
    return switch (this) {
      BlueZGattCharacteristicFlag.broadcast => CharacteristicProperty.broadcast,
      BlueZGattCharacteristicFlag.read => CharacteristicProperty.read,
      BlueZGattCharacteristicFlag.writeWithoutResponse =>
        CharacteristicProperty.writeWithoutResponse,
      BlueZGattCharacteristicFlag.write => CharacteristicProperty.write,
      BlueZGattCharacteristicFlag.notify => CharacteristicProperty.notify,
      BlueZGattCharacteristicFlag.indicate => CharacteristicProperty.indicate,
      BlueZGattCharacteristicFlag.authenticatedSignedWrites =>
        CharacteristicProperty.authenticatedSignedWrites,
      BlueZGattCharacteristicFlag.extendedProperties =>
        CharacteristicProperty.extendedProperties,
      _ => null,
    };
  }
}
