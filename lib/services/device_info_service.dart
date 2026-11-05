import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Helper service to retrieve a descriptive, human-readable device name
/// for device token registration on the Laravel backend.
class DeviceInfoService {
  DeviceInfoService._internal();
  static final DeviceInfoService instance = DeviceInfoService._internal();

  String? _cachedDeviceName;

  /// Returns a clean device name like "Samsung SM-G998B", "iPhone 13,4",
  /// or a sensible fallback based on the OS.
  Future<String> getDeviceName() async {
    if (_cachedDeviceName != null) return _cachedDeviceName!;

    final deviceInfo = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        final manufacturer = androidInfo.manufacturer;
        final model = androidInfo.model;
        if (model.toLowerCase().startsWith(manufacturer.toLowerCase())) {
          _cachedDeviceName = model;
        } else {
          _cachedDeviceName = '$manufacturer $model';
        }
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        _cachedDeviceName = '${iosInfo.name} (${iosInfo.model})';
      } else {
        _cachedDeviceName = Platform.operatingSystem;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[DeviceInfoService] Error getting device info: $e');
      _cachedDeviceName = Platform.isAndroid ? 'Android Device' : 'iOS Device';
    }

    return _cachedDeviceName!;
  }
}
