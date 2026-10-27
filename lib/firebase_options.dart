// Placeholder Firebase configuration.
//
// These values point at the offline "demo-remindmebox" project, which only works
// with the local Firebase Emulator Suite (run with --dart-define=USE_FIREBASE_EMULATOR=true).
//
// To connect a real Firebase project, regenerate this file with:
//   dart pub global activate flutterfire_cli
//   flutterfire configure --project=<your-project-id>
// ignore_for_file: lines_longer_than_80_chars
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return _demo('web');
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _demo('android');
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return _demo('ios');
      default:
        return _demo('web');
    }
  }

  static FirebaseOptions _demo(String platform) => FirebaseOptions(
        apiKey: 'demo-api-key',
        appId: '1:000000000000:$platform:0000000000000000',
        messagingSenderId: '000000000000',
        projectId: 'demo-remindmebox',
        storageBucket: 'demo-remindmebox.appspot.com',
        iosBundleId: 'com.example.remindmebox',
      );
}
