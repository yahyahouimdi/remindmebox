import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remindmebox/models/app_user.dart';
import 'package:remindmebox/screens/auth/register_screen.dart';

void main() {
  testWidgets('role selector reports the chosen role', (tester) async {
    var role = UserRole.superUser;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => RoleSelector(value: role, onChanged: (r) => setState(() => role = r)),
        ),
      ),
    ));

    expect(find.text('Super User'), findsOneWidget);
    expect(find.text('Simple User'), findsOneWidget);

    await tester.tap(find.text('Simple User'));
    await tester.pump();
    expect(role, UserRole.simpleUser);
  });
}
