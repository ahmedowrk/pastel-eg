import 'package:flutter/material.dart';

import 'routes/app_routes.dart';
import 'services/navigation_service.dart';

/// Root widget of the application.
///
/// Attaches [NavigationService.instance.navigatorKey] so that services with
/// no BuildContext (e.g. notification handling) can still trigger
/// navigation/UI updates.
class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Laravel WebView App',
      debugShowCheckedModeBanner: false,
      navigatorKey: NavigationService.instance.navigatorKey,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
      ),
      initialRoute: AppRoutes.webview,
      routes: AppRoutes.routes,
    );
  }
}
