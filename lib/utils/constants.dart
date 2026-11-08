/// Centralized application constants.
///
/// Keep every "magic string" / configurable value here so the rest of the
/// codebase never hardcodes URLs, channel ids, or keys. This is the ONLY
/// file you should need to edit when pointing the app at a new backend.
class AppConstants {
  AppConstants._();

  /// The default Laravel website URL loaded when the app starts and when a
  /// notification payload does not specify a target URL.
  static const String defaultWebsiteUrl = 'https://pastel-eg.com';

  /// Android notification channel id. Must match the channel created by
  /// flutter_local_notifications and referenced by the Laravel backend if it
  /// ever sends `android.notification.channel_id` explicitly (optional).
  static const String notificationChannelId = 'high_importance_channel';

  /// Human readable channel name shown in Android system settings.
  static const String notificationChannelName = 'High Importance Notifications';

  /// Channel description shown in Android system settings.
  static const String notificationChannelDescription =
      'This channel is used for important notifications from the app.';

  /// Drawable name for the small notification icon on Android.
  /// Must exist at: android/app/src/main/res/drawable/ic_notification.png
  static const String androidNotificationIcon = '@drawable/ic_notification';

  /// Laravel backend endpoint path used to register/update the device FCM token
  /// within the authenticated Provider WebView session.
  static const String deviceTokenPath = '/ar/fcm/device-token';
  static const String deviceTokenEndpoint = '$defaultWebsiteUrl$deviceTokenPath';

  /// Key names used inside the FCM `data` payload. Keeping them centralized
  /// means the Laravel team and the Flutter team always agree on the schema.
  static const String payloadKeyUrl = 'url';
  static const String payloadKeyType = 'type';
  static const String payloadKeyTitle = 'title';
  static const String payloadKeyBody = 'body';

  /// TikTok Login Kit v2 configuration (Official OpenSDK)
  /// Client Key from TikTok Developer Portal -> Manage Apps
  static const String tiktokClientKey = 'aw68o0783j7z9eeg';

  /// Standard scopes required for TikTok profile identity and account linking
  static const List<String> tiktokDefaultScopes = [
    'user.info.basic',
  ];

  /// TikTok Login Kit v2 Official HTTPS Redirect URI
  /// Must be registered in TikTok Developer Portal and backed by:
  /// - Android App Links (`/.well-known/assetlinks.json` + `android:autoVerify="true"`)
  /// - iOS Universal Links (`/.well-known/apple-app-site-association` + `applinks:pastel-eg.com`)
  static const String tiktokRedirectUri =
      '$defaultWebsiteUrl/social-connections/tiktok/callback';

  static const String tiktokWebRedirectUri =
      '$defaultWebsiteUrl/provider/automation-settings/provider/social-connections/tiktok/callback';

  /// TikTok backend connection endpoints on Laravel
  static const String tiktokConnectTokenPath =
      '/provider/mobile/social/connect-token';
  static const String tiktokFallbackConnectTokenPath =
      '/provider/social/connect-token';
  static const String tiktokLegacyConnectTokenPath =
      '/provider/automation-settings/provider/social-connections/tiktok/connect-token';
  static const String tiktokMobileConnectTokenPath =
      '/ar/mobile/social/tiktok/connect-token';
}
