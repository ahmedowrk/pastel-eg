// ---------------------------------------------------------------------------
// THIS FILE IS A PLACEHOLDER.
//
// Do NOT hand-write FirebaseOptions in production. Instead, generate the
// real `firebase_options.dart` automatically with the FlutterFire CLI:
//
//   dart pub global activate flutterfire_cli
//   flutterfire configure
//
// That command will:
//   1. Ask you to select your Firebase project
//   2. Ask which platforms to configure (Android / iOS)
//   3. Automatically create/overwrite `lib/firebase_options.dart`
//   4. Automatically place google-services.json and
//      GoogleService-Info.plist in the correct native folders
//
// Once generated, update `main.dart` to import the REAL file:
//
//   import 'firebase_options.dart';
//   await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
//
// and delete this placeholder (or leave it — it is unused once the real
// file exists).
//
// See README.md -> "Firebase Console Setup" for the full step-by-step guide.
// ---------------------------------------------------------------------------

import 'package:firebase_core/firebase_core.dart';

/// Placeholder so the project compiles before you run `flutterfire configure`.
/// Replace all usages of this class with the generated `DefaultFirebaseOptions`
/// from `firebase_options.dart`.
class FirebaseOptionsPlaceholder {
  static FirebaseOptions get currentPlatform => const FirebaseOptions(
        apiKey: 'REPLACE_ME',
        appId: 'REPLACE_ME',
        messagingSenderId: 'REPLACE_ME',
        projectId: 'REPLACE_ME',
        storageBucket: 'REPLACE_ME',
      );
}
