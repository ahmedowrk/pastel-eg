import 'package:flutter/widgets.dart';

/// A global navigation service that lets non-widget classes (like Firebase
/// background handlers, which have no BuildContext) trigger navigation.
///
/// Usage:
///   navigatorKey is attached to MaterialApp.
///   NavigationService.instance.navigateToUrl(url) can be called from
///   anywhere — e.g. from NotificationService when a push is tapped.
class NavigationService {
  NavigationService._internal();
  static final NavigationService instance = NavigationService._internal();

  /// Attach this to your `MaterialApp(navigatorKey: ...)`.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// A pending URL captured when a notification is tapped while the
  /// WebViewScreen has not been built/mounted yet (e.g. cold start from a
  /// terminated state). WebViewScreen reads and clears this on init.
  String? pendingUrl;

  /// The single source of truth for "the WebView should now show this URL".
  ///
  /// A [ValueNotifier] is used instead of raw callbacks so the WebView
  /// screen can simply `ValueListenableBuilder`/`addListener` without any
  /// tight coupling to Firebase or notification code.
  final ValueNotifier<String?> targetUrlNotifier = ValueNotifier<String?>(null);

  /// Called by NotificationService whenever a payload resolves to a URL that
  /// should be opened in the WebView.
  void navigateToUrl(String url) {
    pendingUrl = url;
    targetUrlNotifier.value = url;
  }

  BuildContext? get currentContext => navigatorKey.currentContext;
}
