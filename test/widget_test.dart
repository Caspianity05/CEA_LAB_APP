// Smoke test for LabTrack.
//
// Pumps the Login screen (which has no Firebase or timer dependencies) and
// verifies the core controls render. This keeps `flutter test` green without
// needing a live Firebase connection.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cea_lab_app/firstFile.dart';

void main() {
  testWidgets('Login screen renders core controls', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();

    // Sign In button and the (now functional) Forgot password link are present.
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
  });
}
