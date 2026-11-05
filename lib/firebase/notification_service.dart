import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../firebase_options.dart';
import '../models/notification_payload.dart';
import '../services/navigation_service.dart';
import '../services/notification_state_service.dart';
import '../services/permission_service.dart';
import '../utils/constants.dart';

/// -------------------------------------------------------------------------
/// BACKGROUND MESSAGE HANDLER
/// -------------------------------------------------------------------------
/// This MUST be a top-level function (or a static method) — Firebase spawns
/// it in a separate isolate when the app is backgrounded/terminated, so it
/// cannot be an instance method and cannot close over app state.
///
/// Keep this handler minimal. It is NOT where you navigate the UI (there is
/// no UI running in this isolate) — it's only for background data
/// processing/logging. Notification TAP handling for background/terminated
/// states is done via `FirebaseMessaging.onMessageOpenedApp` and
/// `getInitialMessage()` in [NotificationService], which run in the main
/// isolate once the user actually opens the app.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Firebase must be re-initialized in this isolate.
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  if (kDebugMode) {
    debugPrint('[Background Handler] Message received: ${message.messageId}');
    debugPrint('[Background Handler] Data: ${message.data}');
  }

  // NOTE: Android automatically displays the system notification for
  // messages that contain a `notification` block, even in the background —
  // you do NOT need to manually show a local notification here for that
  // case. This handler is only for extra background data processing
  // (e.g. updating a local cache/badge count) if your payload needs it.
  
  final badgeStr = message.data['badge']?.toString();
  if (badgeStr != null) {
    NotificationStateService.instance.updateBadgeFromPush(badgeStr);
  }
}

/// -------------------------------------------------------------------------
/// NOTIFICATION SERVICE
/// -------------------------------------------------------------------------
/// Owns:
///  - FirebaseMessaging initialization & token lifecycle
///  - flutter_local_notifications setup (for foreground display)
///  - Foreground / background / terminated message handling
///  - Dynamic, extensible payload -> action dispatch (see [_handlePayload])
class NotificationService {
  NotificationService._internal();
  static final NotificationService instance = NotificationService._internal();

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// Holds the current FCM token so the WebView controller can inject it
  /// into the authenticated Provider session once pages load.
  final ValueNotifier<String?> tokenNotifier = ValueNotifier<String?>(null);

  String? get currentToken => tokenNotifier.value;

  /// Callback invoked whenever the token changes or is first retrieved.
  void Function(String token)? onTokenRefresh;

  bool _initialized = false;

  /// Call once, early in `main()`, after `Firebase.initializeApp()`.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Register the background handler BEFORE runApp for terminated-state
    // reliability.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _initializeLocalNotifications();
    await PermissionService.instance.requestNotificationPermissions();

    // iOS: show system alert/badge/sound even while the app is in the
    // foreground.
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    await _setupTokenHandling();
    _setupForegroundListener();
    _setupNotificationOpenedListener();
    await _handleTerminatedLaunch();
  }

  // ---------------------------------------------------------------------
  // TOKEN LIFECYCLE
  // ---------------------------------------------------------------------

  Future<void> _setupTokenHandling() async {
    try {
      final token = await _messaging.getToken();
      if (token != null) {
        _onNewToken(token);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationService] getToken error: $e');
    }

    // Fires whenever FCM rotates the token.
    _messaging.onTokenRefresh.listen(_onNewToken);
  }

  void _onNewToken(String token) {
    if (kDebugMode) {
      debugPrint('[NotificationService] FCM Token: $token');
    }
    tokenNotifier.value = token;
    onTokenRefresh?.call(token);
  }

  // ---------------------------------------------------------------------
  // LOCAL NOTIFICATIONS (foreground display)
  // ---------------------------------------------------------------------

  Future<void> _initializeLocalNotifications() async {
    const androidInit = AndroidInitializationSettings(
      AppConstants.androidNotificationIcon,
    );

    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await _localNotifications.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: _onLocalNotificationTapped,
    );

    if (Platform.isAndroid) {
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          AppConstants.notificationChannelId,
          AppConstants.notificationChannelName,
          description: AppConstants.notificationChannelDescription,
          importance: Importance.high,
        ),
      );
    }
  }

  /// Called when the user taps a *local* notification.
  void _onLocalNotificationTapped(NotificationResponse response) {
    final payloadString = response.payload;
    if (payloadString == null || payloadString.isEmpty) return;

    try {
      final Map<String, dynamic> data =
          jsonDecode(payloadString) as Map<String, dynamic>;
      _handlePayload(NotificationPayload.fromMap(data));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NotificationService] Failed to decode local payload: $e');
      }
    }
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    
    final badgeStr = message.data['badge']?.toString();
    if (badgeStr != null) {
      NotificationStateService.instance.updateBadgeFromPush(badgeStr);
    }

    const androidDetails = AndroidNotificationDetails(
      AppConstants.notificationChannelId,
      AppConstants.notificationChannelName,
      channelDescription: AppConstants.notificationChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      icon: AppConstants.androidNotificationIcon,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(
      id: message.hashCode,
      title: notification.title,
      body: notification.body,
      notificationDetails: details,
      payload: jsonEncode(message.data),
    );
  }

  // ---------------------------------------------------------------------
  // MESSAGE STATE HANDLING
  // ---------------------------------------------------------------------

  void _setupForegroundListener() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      if (kDebugMode) {
        debugPrint('[Foreground] Message received: ${message.data}');
      }
      _showLocalNotification(message);
    });
  }

  void _setupNotificationOpenedListener() {
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      if (kDebugMode) {
        debugPrint('[onMessageOpenedApp] Tapped: ${message.data}');
      }
      _handlePayload(NotificationPayload.fromMap(message.data));
    });
  }

  Future<void> _handleTerminatedLaunch() async {
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      if (kDebugMode) {
        debugPrint('[Terminated Launch] Message: ${initialMessage.data}');
      }
      _handlePayload(NotificationPayload.fromMap(initialMessage.data));
    }
  }

  // ---------------------------------------------------------------------
  // DYNAMIC PAYLOAD DISPATCH
  // ---------------------------------------------------------------------

  void _handlePayload(NotificationPayload payload) {
    if (payload.notificationId != null) {
      NotificationStateService.instance.readNotification(payload.notificationId!);
    }
    
    switch (payload.actionType) {
      case NotificationActionType.example:
        _navigateFromPayload(payload);
        break;

      case NotificationActionType.generic:
        _navigateFromPayload(payload);
        break;
    }
  }

  void _navigateFromPayload(NotificationPayload payload) {
    final target = payload.hasUrl ? payload.url! : AppConstants.defaultWebsiteUrl;
    NavigationService.instance.navigateToUrl(target);
  }
}
