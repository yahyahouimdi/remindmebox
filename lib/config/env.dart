import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Build-time settings, passed with `--dart-define`.
class Env {
  /// `flutter run --dart-define=USE_FIREBASE_EMULATOR=true`
  static const useEmulator = bool.fromEnvironment('USE_FIREBASE_EMULATOR');

  /// Host running `firebase emulators:start`. Defaults to the Android emulator's
  /// alias for the computer; use the computer's LAN IP for a physical phone.
  static const emulatorHost = String.fromEnvironment(
    'EMULATOR_HOST',
    defaultValue: kIsWeb ? 'localhost' : '10.0.2.2',
  );

  /// Must match REGION in backend/functions/src/admin.ts.
  static const functionsRegion = 'europe-west1';
}

FirebaseFunctions functions() => FirebaseFunctions.instanceFor(region: Env.functionsRegion);

Future<void> configureFirebaseEmulators() async {
  if (!Env.useEmulator) return;
  await FirebaseAuth.instance.useAuthEmulator(Env.emulatorHost, 9099);
  FirebaseFirestore.instance.useFirestoreEmulator(Env.emulatorHost, 8080);
  functions().useFunctionsEmulator(Env.emulatorHost, 5001);
}
