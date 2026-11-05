import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Centralizes all runtime permission requests:
///  - Android 13+ (API 33+) POST_NOTIFICATIONS runtime permission
///  - iOS notification permission (alert, badge, sound) via FCM's own API
///
/// Keeping this in one place means main.dart / notification_service.dart
/// never duplicate permission logic.
class PermissionService {
  PermissionService._internal();
  static final PermissionService instance = PermissionService._internal();

  /// Requests all notification-related permissions required for the current
  /// platform. Safe to call multiple times (it's idempotent from the OS'
  /// perspective — it won't re-prompt if already granted/denied permanently).
  Future<bool> requestNotificationPermissions() async {
    bool granted = true;

    if (Platform.isAndroid) {
      granted = await _requestAndroidNotificationPermission();
    }

    if (Platform.isIOS || Platform.isMacOS) {
      granted = await _requestIOSNotificationPermission();
    }

    return granted;
  }

  /// Android 13 (API 33) introduced a runtime POST_NOTIFICATIONS permission.
  /// On Android 12 and below this is a no-op and permission_handler will
  /// simply report `granted` since no prompt is needed.
  Future<bool> _requestAndroidNotificationPermission() async {
    final status = await ph.Permission.notification.status;

    if (status.isGranted) return true;

    final result = await ph.Permission.notification.request();

    if (kDebugMode) {
      debugPrint('[PermissionService] Android POST_NOTIFICATIONS: $result');
    }

    return result.isGranted;
  }

  /// iOS requires explicit permission for alert/badge/sound notifications.
  /// This uses FirebaseMessaging's native permission API rather than
  /// permission_handler, since FCM's request dialog is the canonical one
  /// that also registers the app for remote notifications with APNs.
  Future<bool> _requestIOSNotificationPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
      criticalAlert: false,
      announcement: false,
      carPlay: false,
    );

    if (kDebugMode) {
      debugPrint(
        '[PermissionService] iOS permission status: ${settings.authorizationStatus}',
      );
    }

    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }
}
