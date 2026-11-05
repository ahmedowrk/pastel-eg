import 'package:flutter/material.dart';

import '../webview/webview_screen.dart';

/// Named route table. Kept intentionally minimal since this app is
/// currently a single WebView screen — add new routes here as the app
/// grows (e.g. a splash screen, an onboarding flow, native settings, etc.).
class AppRoutes {
  AppRoutes._();

  static const String webview = '/';

  static Map<String, WidgetBuilder> get routes => {
        webview: (_) => const WebViewScreen(),
      };
}
