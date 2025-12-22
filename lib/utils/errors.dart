import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Turns Firebase exceptions into short messages for a SnackBar.
String friendlyError(Object error) {
  if (error is FirebaseAuthException) {
    return switch (error.code) {
      'invalid-email' => 'This email address is not valid.',
      'user-disabled' => 'This account has been disabled.',
      'user-not-found' || 'wrong-password' || 'invalid-credential' => 'Wrong email or password.',
      'email-already-in-use' => 'An account already exists with this email.',
      'weak-password' => 'Choose a stronger password (at least 6 characters).',
      'too-many-requests' => 'Too many attempts. Please wait a moment and try again.',
      'network-request-failed' => 'No internet connection.',
      _ => error.message ?? 'Authentication failed.',
    };
  }
  if (error is FirebaseFunctionsException) {
    return error.message ?? 'The server could not complete the request.';
  }
  if (error is FirebaseException) {
    return switch (error.code) {
      'permission-denied' => "You don't have permission to do this.",
      'unavailable' => 'Service unavailable. Check your connection.',
      _ => error.message ?? 'Something went wrong.',
    };
  }
  return error.toString().replaceFirst('Exception: ', '');
}
