// Smoke test for LabTrack.
//
// Pumps the Login screen (which has no Firebase or timer dependencies) and
// verifies the core controls render. This keeps `flutter test` green without
// needing a live Firebase connection.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cea_lab_app/screens/auth/login_screen.dart';
import 'package:cea_lab_app/screens/staff/full_report_screen.dart';
import 'package:cea_lab_app/screens/staff/request_card.dart';
import 'package:cea_lab_app/screens/staff/return_flow.dart';
import 'package:cea_lab_app/screens/student/how_it_works_screen.dart';
import 'package:cea_lab_app/services/full_report.dart';
import 'package:cea_lab_app/services/session.dart';

void main() {
  // 2026-10-06: the four steps open by themselves once per student, then
  // only from Profile.
  testWidgets('How Borrowing Works opens once per student', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(children: [
            TextButton(
                onPressed: () => HowItWorksScreen.showOnce(context, 's1'),
                child: const Text('open s1')),
            TextButton(
                onPressed: () => HowItWorksScreen.showOnce(context, 's2'),
                child: const Text('open s2')),
          ]),
        ),
      ),
    ));

    await tester.tap(find.text('open s1'));
    await tester.pumpAndSettle();
    expect(find.text('How Borrowing Works'), findsOneWidget);
    for (final step in ['Choose and send', 'Wait for approval',
        'Pick up at the lab', 'Return on time']) {
      expect(find.text(step), findsOneWidget);
    }
    // scrollUntilVisible stops as soon as the button is built, which can be
    // just below the 800×600 test screen; ensureVisible then brings it in.
    await tester.scrollUntilVisible(find.text('Got it'), 200);
    await tester.ensureVisible(find.text('Got it'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('How Borrowing Works'), findsNothing);

    // Seen: not again for s1, but a second student on this phone gets it.
    await tester.tap(find.text('open s1'));
    await tester.pumpAndSettle();
    expect(find.text('How Borrowing Works'), findsNothing);
    await tester.tap(find.text('open s2'));
    await tester.pumpAndSettle();
    expect(find.text('How Borrowing Works'), findsOneWidget);
  });

  // QA 2026-10-06: approving a request of several units takes seconds, and a
  // second tap meanwhile started a second run.
  testWidgets('A request card runs Approve once and shows it is busy',
      (WidgetTester tester) async {
    Session.set({'role': 'admin'}, 'staff');
    addTearDown(Session.clear);
    final done = Completer<void>();
    var approvals = 0;
    Map<String, dynamic> unit(int n) => {
          'student_id': 's1',
          'borrow_date': '2026-10-06T14:18:00.000',
          'borrower_name': 'Test Student',
          'equipment_name': 'Beaker 1000 mL #$n',
          'qr_code': 'OTH-$n',
          'status': 'Pending',
        };
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PendingRequestCard(
            request: [unit(1), unit(2)],
            onApprove: () {
              approvals++;
              return done.future;
            },
            onReject: () async {},
          ),
        ),
      ),
    ));

    expect(find.text('Approve all 2'), findsOneWidget);
    await tester.tap(find.text('Approve all 2'));
    await tester.pump();
    // Busy: a spinner, and neither button acts until it finishes.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Approve all 2'));
    await tester.tap(find.text('Deny'));
    await tester.pump();
    expect(approvals, 1);

    done.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  // Live test 2026-10-07 (U2): on Requests → Approved a returned loan's card
  // leaves the list while the return is saved, and the return step used to
  // stop there: no confirmation, and a damaged return never asked
  // "Log Damage & Hold?".
  group('A return whose card leaves the screen meanwhile', () {
    // Opens the return sheet from a "card" that the list drops as soon as the
    // return starts; the save answers only when the test completes [saved].
    Future<void> openSheet(
        WidgetTester tester, Completer<Map<String, dynamic>> saved) async {
      var showCard = true;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setOuter) => showCard
                ? Builder(
                    builder: (cardContext) => TextButton(
                      onPressed: () => showReturnSheet(
                        cardContext,
                        equipment: const {
                          'equipment_id': 'b1',
                          'equipment_name': 'Beaker 1000 mL #1',
                          'qr_code': 'OTH-1',
                          'status': 'Borrowed',
                        },
                        closeLabel: 'Cancel',
                        doReturn: (condition) {
                          setOuter(() => showCard = false); // the list drops it
                          return saved.future;
                        },
                      ),
                      child: const Text('Mark as Returned'),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ));
      await tester.tap(find.text('Mark as Returned'));
      await tester.pumpAndSettle();
    }

    Future<void> returnAs(WidgetTester tester, String button,
        Completer<Map<String, dynamic>> saved) async {
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(find.text('Mark as Returned'), findsNothing); // the card is gone
      saved.complete({'success': true, 'borrower_name': 'Test Student'});
      await tester.pumpAndSettle();
    }

    testWidgets('still confirms a good return', (WidgetTester tester) async {
      final saved = Completer<Map<String, dynamic>>();
      await openSheet(tester, saved);
      await returnAs(tester, 'Return — Good Condition', saved);
      expect(find.text('"Beaker 1000 mL #1" marked as returned.'), findsOneWidget);
    });

    testWidgets('still offers Log Damage & Hold for a damaged one',
        (WidgetTester tester) async {
      final saved = Completer<Map<String, dynamic>>();
      await openSheet(tester, saved);
      await returnAs(tester, 'Return — Report Damage', saved);
      expect(find.text('"Beaker 1000 mL #1" returned and marked Under Repair.'),
          findsOneWidget);
      expect(find.text('Log Damage & Hold?'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('Log Damage & Hold?'), findsNothing);
    });
  });

  // 2026-10-07: Export Full Report was a terminal-style text block; it is a
  // page now, and Copy Report gives plain text.
  testWidgets('The full report reads as a page and copies plain text',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000); // all of it on screen
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MaterialApp(
      home: FullReportScreen(
        report: FullReport(
          madeAt: DateTime(2026, 10, 7, 14, 5),
          madeBy: 'Ramoel Bello',
          days: 90,
          totalBorrowings: 28,
          totalReturned: 27,
          totalOverdue: 1,
          totalDamage: 4,
          totalEquipment: 90,
          onTimeRate: 92.6,
          mostBorrowed: const {'Beaker 1000 mL': 13},
          requests: const [
            {'borrow_date': '2026-10-07T09:05:00.000', 'borrower_name': 'ce demo',
             'equipment_name': 'Beaker 1000 mL #1', 'status': 'Returned'},
          ],
        ),
      ),
    ));

    for (final shown in [
      'CEA Laboratory Report',
      'Made on Oct 7, 2026 at 2:05 PM by Ramoel Bello',
      'Covers the last 90 days: Jul 9, 2026 to Oct 7, 2026',
      'Summary', 'Total Borrowings', '28', 'On-Time Returns', '93%',
      'Most Borrowed Equipment', 'Beaker 1000 mL', '13 times',
      'Requests', '1 request for 1 item', 'Returned: 1', 'Today, Oct 7, 2026',
      '9:05 AM', 'ce demo', 'Beaker 1000 mL #1', 'Returned',
    ]) {
      expect(find.text(shown), findsOneWidget, reason: shown);
    }
    expect(find.textContaining('Show all'), findsNothing); // only one request

    await tester.tap(find.text('Copy Report'));
    await tester.pumpAndSettle();
    expect(copied, contains('Total Borrowings: 28'));
    expect(copied, contains('Today, Oct 7, 2026\n9:05 AM - ce demo - Beaker 1000 mL #1 - Returned'));
    expect(copied, isNot(contains('====')));
    expect(find.textContaining('Report copied.'), findsOneWidget);
  });

  // "Too many" (the user): the 10 newest requests, then "Show all".
  testWidgets('The full report shows the 10 newest requests until Show all',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: FullReportScreen(
        report: FullReport(
          madeAt: DateTime(2026, 10, 7, 17, 0),
          days: 90,
          totalBorrowings: 12, totalReturned: 12, totalOverdue: 0, totalDamage: 0,
          totalEquipment: 90, onTimeRate: 100,
          requests: [
            for (var i = 0; i < 12; i++)
              {'student_id': 's$i', 'borrow_date': '2026-10-07T${(16 - i).toString().padLeft(2, '0')}:00:00.000',
               'borrower_name': 'Student $i', 'equipment_name': 'Flask 500 mL #$i',
               'status': 'Returned'},
          ],
        ),
      ),
    ));

    expect(find.text('12 requests for 12 items'), findsOneWidget);
    expect(find.text('Student 0'), findsOneWidget); // newest
    expect(find.text('Student 9'), findsOneWidget); // tenth
    expect(find.text('Student 10'), findsNothing);
    expect(find.text('Show all (2 more)'), findsOneWidget);

    await tester.tap(find.text('Show all (2 more)'));
    await tester.pumpAndSettle();
    expect(find.text('Student 10'), findsOneWidget);
    expect(find.text('Student 11'), findsOneWidget);
    expect(find.textContaining('Show all'), findsNothing);
  });

  // 2026-10-07: "Change dates", and on the web Download Excel / Download PDF.
  group('Full report downloads and dates', () {
    FullReport report({DateTime? start, DateTime? end, int borrowed = 3}) => FullReport(
          madeAt: DateTime.now(),
          madeBy: 'Ramoel Bello',
          start: start,
          end: end,
          totalBorrowings: borrowed, totalReturned: borrowed, totalOverdue: 0,
          totalDamage: 0, totalEquipment: 90, onTimeRate: 100,
          mostBorrowed: const {'Beaker 1000 mL': 3},
        );

    testWidgets('the download buttons answer outside the web portal', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          MaterialApp(home: FullReportScreen(report: report(), showDownloads: true)));

      expect(find.text('Download Excel'), findsOneWidget);
      expect(find.text('Download PDF to print'), findsOneWidget);
      expect(find.text('Change dates'), findsNothing); // no loader given

      await tester.tap(find.text('Download Excel'));
      await tester.pump();
      expect(find.text('Downloads work in the web portal.'), findsOneWidget);
      await tester.pumpAndSettle(); // in, then its timer starts
      await tester.pump(const Duration(seconds: 5)); // the message times out
      await tester.pumpAndSettle();
      expect(find.text('Downloads work in the web portal.'), findsNothing);

      await tester.runAsync(() async {
        await tester.tap(find.text('Download PDF to print'));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      expect(find.text('Downloads work in the web portal.'), findsOneWidget);
    });

    testWidgets('the phone shows no download buttons', (tester) async {
      await tester.pumpWidget(MaterialApp(home: FullReportScreen(report: report())));
      expect(find.text('Download Excel'), findsNothing);
      expect(find.text('Copy Report'), findsOneWidget);
    });

    testWidgets('Change dates makes the report for the chosen period', (tester) async {
      final asked = <(DateTime, DateTime)>[];
      await tester.pumpWidget(MaterialApp(
        home: FullReportScreen(
          report: report(),
          loadPeriod: (start, end) async {
            asked.add((start, end));
            return report(start: start, end: end, borrowed: 7);
          },
        ),
      ));
      expect(find.textContaining('Covers the last 90 days'), findsOneWidget);

      await tester.tap(find.text('Change dates'));
      await tester.pumpAndSettle();
      expect(find.text('CHOOSE THE DATES FOR THE REPORT'), findsOneWidget);
      await tester.tap(find.text('Make Report'));
      await tester.pumpAndSettle();

      expect(asked, hasLength(1));
      final today = DateTime.now();
      expect(asked.single.$2, DateTime(today.year, today.month, today.day));
      expect(find.textContaining('Covers the last 90 days'), findsNothing);
      expect(find.textContaining(RegExp(r'^Covers .* \(91 days\)$')), findsOneWidget);
      expect(find.text('7'), findsWidgets); // the new period's Total Borrowings
    });
  });

  // Found on the phone: after "Show all", scrolling to the top and back
  // collapsed the list again (the list had dropped the section's state).
  testWidgets('Show all stays open after scrolling away and back',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 600); // a small screen
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: FullReportScreen(
        report: FullReport(
          madeAt: DateTime(2026, 10, 7, 17, 0),
          days: 90,
          totalBorrowings: 12, totalReturned: 12, totalOverdue: 0, totalDamage: 0,
          totalEquipment: 90, onTimeRate: 100,
          // enough above the requests that they leave the list's reach at the top
          mostBorrowed: {for (var i = 0; i < 12; i++) 'Item $i': 12 - i},
          requests: [
            for (var i = 0; i < 12; i++)
              {'student_id': 's$i', 'borrow_date': '2026-10-07T${(16 - i).toString().padLeft(2, '0')}:00:00.000',
               'borrower_name': 'Student $i', 'equipment_name': 'Flask 500 mL #$i',
               'status': 'Returned'},
          ],
        ),
      ),
    ));
    final list = find.byType(Scrollable).first;

    await tester.scrollUntilVisible(find.text('Show all (2 more)'), 300, scrollable: list);
    await tester.ensureVisible(find.text('Show all (2 more)')); // built is not on screen
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show all (2 more)'));
    await tester.pumpAndSettle();

    await tester.drag(list, const Offset(0, 20000)); // back to the top
    await tester.pumpAndSettle();
    expect(find.text('CEA Laboratory Report'), findsOneWidget);
    // The premise: up here the list has dropped the requests section
    // altogether, which is when a section-held "Show all" was forgotten.
    expect(find.text('Newest first'), findsNothing);

    await tester.scrollUntilVisible(find.text('Student 11'), 300, scrollable: list);
    expect(find.text('Student 11'), findsOneWidget);
    expect(find.textContaining('Show all'), findsNothing);
  });

  testWidgets('Login screen renders core controls', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();

    // Sign In button and the (now functional) Forgot password link are present.
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
  });

  // 2026-10-13: the student tab asks for an email, and a student number saved
  // by "remember me" in an older version is not pre-filled.
  testWidgets('Login asks students for an email, not a student ID', (tester) async {
    SharedPreferences.setMockInitialValues({
      'remember_me': true,
      'saved_identifier': '26-12345-222',
      'saved_is_student': true,
    });
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Email Address'), findsOneWidget);
    expect(find.text('Student ID / Email'), findsNothing);
    expect(find.text('name@neu.edu.ph'), findsOneWidget);
    expect(find.text('26-12345-222'), findsNothing);

    // Forgot password offers the email already typed (QA 2026-10-13: the
    // Student tab used to open it empty).
    await tester.enterText(find.byType(TextFormField).first, 'ce.demo@gmail.com');
    await tester.ensureVisible(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    expect(find.text('Reset Password'), findsOneWidget);
    expect(find.text('ce.demo@gmail.com'), findsNWidgets(2));
  });
}
