import 'package:cloud_firestore/cloud_firestore.dart';

enum UserRole {
  superUser('super', 'Super User', 'Doctor or family member — full access'),
  simpleUser('simple', 'Simple User', 'Caregiver — view & monitor');

  const UserRole(this.value, this.label, this.description);

  final String value;
  final String label;
  final String description;

  static UserRole fromValue(Object? value) =>
      UserRole.values.firstWhere((r) => r.value == value, orElse: () => UserRole.simpleUser);
}

class AppUser {
  const AppUser({required this.uid, required this.name, required this.email, required this.role});

  final String uid;
  final String name;
  final String email;
  final UserRole role;

  bool get isSuperUser => role == UserRole.superUser;

  factory AppUser.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const {};
    return AppUser(
      uid: doc.id,
      name: d['name'] as String? ?? '',
      email: d['email'] as String? ?? '',
      role: UserRole.fromValue(d['role']),
    );
  }
}
