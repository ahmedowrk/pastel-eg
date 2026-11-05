import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'notification_service.dart';

/// Thin wrapper around Firebase core bootstrap.
///
/// Uses the generated [DefaultFirebaseOptions] from `flutterfire configure`.
class FirebaseService {
  FirebaseService._internal();
  static final FirebaseService instance = FirebaseService._internal();

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    _initialized = true;

    if (kDebugMode) {
      debugPrint('[FirebaseService] Firebase initialized.');
    }

    await NotificationService.instance.initialize();
  }
}
