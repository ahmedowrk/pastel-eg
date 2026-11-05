import '../utils/constants.dart';

/// Known notification "types" the Laravel backend may send inside the
/// `data.type` field.
///
/// ADDING A NEW NOTIFICATION TYPE FROM LARAVEL REQUIRES **NO FLUTTER CODE
/// CHANGES TO THE ARCHITECTURE** as long as it just needs to open a URL:
/// Laravel simply sends `{"data": {"url": "...", "type": "order_update"}}`
/// and the generic `NotificationActionType.generic` branch (the default
/// case below) will navigate the WebView to that URL automatically.
///
/// You only need to add a new enum value + switch case here when a new type
/// needs *custom, non-navigation* behavior (e.g. show a dialog, refresh a
/// specific widget, trigger a local action). This keeps the "dynamic by
/// default, custom by exception" contract intact.
enum NotificationActionType {
  /// Default / fallback: just navigate the WebView to `data.url` (if any).
  generic,

  /// Example of a custom type. Add real ones as your product grows, e.g.
  /// orderUpdate, chatMessage, promo, accountAlert, etc.
  example,
}

/// A strongly-typed, immutable representation of an incoming FCM message's
/// `data` payload.
///
/// This class is the single seam between "whatever Laravel decided to send"
/// and "what the app does about it". Every field is optional except that the
/// payload is always parsed defensively — a malformed or partial payload
/// must never crash the app.
class NotificationPayload {
  final String? title;
  final String? body;
  final String? url;
  final String? badge;
  final String? notificationId;
  final String rawType;
  final Map<String, dynamic> raw;

  const NotificationPayload({
    this.title,
    this.body,
    this.url,
    this.badge,
    this.notificationId,
    required this.rawType,
    required this.raw,
  });

  /// Parses a raw FCM `data` map (always `Map<String, dynamic>` /
  /// `Map<String, String>` coming from firebase_messaging) into a typed
  /// payload. Never throws — falls back to safe defaults.
  factory NotificationPayload.fromMap(Map<String, dynamic> data) {
    return NotificationPayload(
      title: data[AppConstants.payloadKeyTitle] as String?,
      body: data[AppConstants.payloadKeyBody] as String?,
      url: data[AppConstants.payloadKeyUrl] as String?,
      badge: data['badge']?.toString(),
      notificationId: data['notification_id']?.toString(),
      rawType: (data[AppConstants.payloadKeyType] as String?) ?? 'generic',
      raw: data,
    );
  }

  /// Maps the free-form `rawType` string sent by Laravel to a known enum.
  /// Unknown or future types safely fall back to [NotificationActionType.generic],
  /// which means "just navigate to the url if present" — this is what
  /// makes new notification types require zero Flutter changes by default.
  NotificationActionType get actionType {
    switch (rawType) {
      case 'example':
        return NotificationActionType.example;
      default:
        return NotificationActionType.generic;
    }
  }

  bool get hasUrl => url != null && url!.trim().isNotEmpty;

  @override
  String toString() =>
      'NotificationPayload(title: $title, body: $body, url: $url, type: $rawType, badge: $badge, notificationId: $notificationId)';
}
