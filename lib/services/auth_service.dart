import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';

class AuthService {
  AuthService({FirebaseAuth? auth, FirebaseFirestore? db})
      : _auth = auth ?? FirebaseAuth.instance,
        _db = db ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;

  Stream<User?> authStateChanges() => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  Stream<AppUser?> profile(String uid) => _db
      .doc('users/$uid')
      .snapshots()
      .map((doc) => doc.exists ? AppUser.fromDoc(doc) : null);

  Future<void> signIn({required String email, required String password}) =>
      _auth.signInWithEmailAndPassword(email: email.trim(), password: password);

  Future<void> register({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  }) async {
    final cred = await _auth.createUserWithEmailAndPassword(email: email.trim(), password: password);
    await cred.user!.updateDisplayName(name.trim());
    await createProfile(user: cred.user!, name: name, role: role);
  }

  /// Also used when an account exists in Auth but its profile was never written.
  Future<void> createProfile({required User user, required String name, required UserRole role}) {
    final email = user.email ?? '';
    return _db.doc('users/${user.uid}').set({
      'name': name.trim(),
      'email': email,
      'emailLower': email.toLowerCase(),
      'role': role.value,
      'pushIds': <String>[],
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateName(String uid, String name) =>
      _db.doc('users/$uid').update({'name': name.trim(), 'updatedAt': FieldValue.serverTimestamp()});

  Future<void> sendPasswordReset(String email) => _auth.sendPasswordResetEmail(email: email.trim());

  Future<void> signOut() => _auth.signOut();
}
