import 'package:flutter/material.dart';
import 'app.dart';
import 'firebase/firebase_service.dart';

Future<void> main() async {
  // Required before calling any plugin code (Firebase, permission_handler,
  // etc.) before runApp().
  WidgetsFlutterBinding.ensureInitialized();

  // Initializes Firebase core + Firebase Messaging + local notifications +
  // permission requests + all message-state listeners. See
  // lib/firebase/firebase_service.dart and notification_service.dart.
  await FirebaseService.instance.initialize();

  runApp(const App());
}