// Unit tests for the pure business logic in ApiService — no Firebase or
// network needed, so these run in plain `flutter test`.

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';

// These now import only the service layer and shared constants — the pure
// business logic no longer pulls in the UI module at all.
import 'package:cea_lab_app/constants.dart';
import 'package:cea_lab_app/services/api_service.dart';
import 'package:cea_lab_app/services/session.dart';

void main() {
  group('Due-date policy (same-day 5:00 PM cap)', () {
    final morning = DateTime(2026, 7, 25, 9, 0);

    test('honours a requested time before 5 PM, on today\'s date', () {
      final due = ApiService.computeDueDate(morning, DateTime(2026, 7, 25, 15, 30));
      expect(due, DateTime(2026, 7, 25, 15, 30));
    });

    test('a requested time of exactly 5:00 PM is allowed', () {
      final due = ApiService.computeDueDate(morning, DateTime(2026, 7, 25, 17, 0));
      expect(due, DateTime(2026, 7, 25, 17, 0));
    });

    test('clamps a requested time after 5 PM to 5:00 PM', () {
      final due = ApiService.computeDueDate(morning, DateTime(2026, 7, 25, 19, 45));
      expect(due, DateTime(2026, 7, 25, 17, 0));
    });

    test('defaults to 5:00 PM when no time was requested', () {
      final due = ApiService.computeDueDate(morning, null);
      expect(due, DateTime(2026, 7, 25, 17, 0));
    });

    test('always lands on the borrow date (same-day policy)', () {
      // A requested time on a DIFFERENT day still resolves to today.
      final due = ApiService.computeDueDate(morning, DateTime(2026, 8, 1, 10, 0));
      expect(due, DateTime(2026, 7, 25, 10, 0));
    });
  });

  group('Equipment status after a return', () {
    test('Damaged goes to Under Repair', () {
      expect(ApiService.equipmentStatusForCondition('Damaged'), 'Under Repair');
    });
    test('Under Repair stays Under Repair', () {
      expect(ApiService.equipmentStatusForCondition('Under Repair'), 'Under Repair');
    });
    test('For Disposal goes to For Disposal', () {
      expect(ApiService.equipmentStatusForCondition('For Disposal'), 'For Disposal');
    });
    test('Good condition returns to Available', () {
      expect(ApiService.equipmentStatusForCondition('Good'), 'Available');
    });
    test('unknown condition safely returns to Available', () {
      expect(ApiService.equipmentStatusForCondition('???'), 'Available');
    });
  });

  group('Student reliability summary', () {
    final now = DateTime(2026, 7, 27, 12, 0);

    test('no transactions → Good rating, all zero', () {
      final r = ApiService.studentReliability(const [], now: now);
      expect(r['rating'], 'Good');
      expect(r['loans'], 0);
      expect(r['late'], 0);
      expect(r['overdue'], 0);
      expect(r['damages'], 0);
    });

    test('counts approved + returned as loans; pending/rejected are not loans', () {
      final r = ApiService.studentReliability([
        {'status': 'Approved', 'due_date': '2999-01-01T17:00:00'},
        {'status': 'Returned', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-20T16:00:00'},
        {'status': 'Pending'},
        {'status': 'Rejected'},
      ], now: now);
      expect(r['loans'], 2);
      expect(r['rating'], 'Good');
    });

    test('counts only still-approved loans as active', () {
      final r = ApiService.studentReliability([
        {'status': 'Approved', 'due_date': '2999-01-01T17:00:00'},
        {'status': 'Approved', 'due_date': '2999-01-02T17:00:00'},
        {'status': 'Returned', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-20T16:00:00'},
        {'status': 'Pending'},
        {'status': 'Rejected'},
      ], now: now);
      expect(r['active'], 2);
      expect(r['loans'], 3);
    });

    test('a return after the due date counts as late', () {
      final r = ApiService.studentReliability([
        {'status': 'Returned', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-21T09:00:00'},
      ], now: now);
      expect(r['late'], 1);
      expect(r['rating'], 'Fair');
    });

    test('an approved loan past its due date counts as overdue', () {
      final r = ApiService.studentReliability([
        {'status': 'Approved', 'due_date': '2026-07-25T17:00:00'},
      ], now: now);
      expect(r['overdue'], 1);
    });

    test('a damaged-condition return counts as a damage', () {
      final r = ApiService.studentReliability([
        {'status': 'Returned', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-20T10:00:00', 'condition_returned': 'Damaged'},
      ], now: now);
      expect(r['damages'], 1);
    });

    test('3+ combined issues → Watch rating', () {
      final r = ApiService.studentReliability([
        {'status': 'Returned', 'due_date': '2026-07-10T17:00:00', 'return_date': '2026-07-12T10:00:00', 'condition_returned': 'Damaged'},
        {'status': 'Approved', 'due_date': '2026-07-25T17:00:00'},
        {'status': 'Returned', 'due_date': '2026-07-15T17:00:00', 'return_date': '2026-07-16T10:00:00'},
      ], now: now);
      // 1 damage + 1 late (first), 1 overdue (second), 1 late (third) = 4 flags
      expect(r['rating'], 'Watch');
    });
  });

  // Regression: a due time that has already passed used to be stored as-is, so
  // the loan was overdue the instant staff approved it (QA 2026-09-19, M3).
  group('Due-date policy (a deadline already past)', () {
    final afternoon = DateTime(2026, 7, 25, 14, 0);

    test('a requested time earlier than now falls back to 5:00 PM', () {
      final due = ApiService.computeDueDate(afternoon, DateTime(2026, 7, 25, 9, 0));
      expect(due, DateTime(2026, 7, 25, 17, 0));
    });

    test('a requested time equal to now falls back to 5:00 PM', () {
      final due = ApiService.computeDueDate(afternoon, DateTime(2026, 7, 25, 14, 0));
      expect(due, DateTime(2026, 7, 25, 17, 0));
    });

    test('a requested time still ahead is honoured', () {
      final due = ApiService.computeDueDate(afternoon, DateTime(2026, 7, 25, 16, 30));
      expect(due, DateTime(2026, 7, 25, 16, 30));
    });
  });

  // Regression: registration dropped the Condition field, so every item was
  // stored Available — a scope registered For Disposal was immediately
  // borrowable (QA 2026-09-19, M1). addEquipment now maps through here.
  group('Registration condition to starting status', () {
    test('Good starts Available', () {
      expect(ApiService.equipmentStatusForCondition('Good'), 'Available');
    });
    test('Fair starts Available', () {
      expect(ApiService.equipmentStatusForCondition('Fair'), 'Available');
    });
    test('Under Repair does not start borrowable', () {
      expect(ApiService.equipmentStatusForCondition('Under Repair'), 'Under Repair');
    });
    test('For Disposal does not start borrowable', () {
      expect(ApiService.equipmentStatusForCondition('For Disposal'), 'For Disposal');
    });
  });

  // Regression: the Reports screen counted Pending and Rejected requests as
  // borrowings, and worked out "on time" without ever comparing a return date
  // with a due date (QA 2026-09-19, M2).
  group('Report metrics', () {
    final now = DateTime(2026, 7, 27, 12, 0);

    test('no transactions → all zero, and a 0% rate rather than a crash', () {
      final m = ApiService.reportMetrics(const [], now: now);
      expect(m['borrowings'], 0);
      expect(m['returned'], 0);
      expect(m['overdue'], 0);
      expect(m['onTimeRate'], 0.0);
      expect(m['mostBorrowed'], <String, int>{});
    });

    test('Pending and Rejected are not borrowings and cannot rank', () {
      final m = ApiService.reportMetrics([
        {'status': 'Approved', 'equipment_name': 'Theodolite', 'due_date': '2999-01-01T17:00:00'},
        {'status': 'Pending',  'equipment_name': 'Multimeter'},
        {'status': 'Rejected', 'equipment_name': 'Multimeter'},
        {'status': 'Rejected', 'equipment_name': 'Multimeter'},
      ], now: now);
      expect(m['borrowings'], 1);
      // The rejected-only item used to place second in Most Borrowed.
      expect(m['mostBorrowed'], {'Theodolite': 1});
    });

    test('on-time rate is measured against returns, not every request', () {
      // One of two returns was late; two more requests never became loans. The
      // old formula divided returns by all four and landed on 50% by accident.
      final m = ApiService.reportMetrics([
        {'status': 'Returned', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-20T16:00:00'},
        {'status': 'Returned', 'due_date': '2026-07-21T17:00:00', 'return_date': '2026-07-22T09:00:00'},
        {'status': 'Pending'},
        {'status': 'Rejected'},
      ], now: now);
      expect(m['borrowings'], 2);
      expect(m['returned'], 2);
      expect(m['onTime'], 1);
      expect(m['onTimeRate'], 50.0);
    });

    test('a return exactly on the deadline is on time', () {
      final m = ApiService.reportMetrics([
        {'status': 'Returned', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-20T17:00:00'},
      ], now: now);
      expect(m['onTimeRate'], 100.0);
    });

    test('a return with no recorded date is not held against the student', () {
      final m = ApiService.reportMetrics([
        {'status': 'Returned', 'due_date': '2026-07-20T17:00:00'},
      ], now: now);
      expect(m['onTime'], 1);
    });

    test('with no returns at all the rate is 0%, not a division by zero', () {
      final m = ApiService.reportMetrics([
        {'status': 'Approved', 'due_date': '2999-01-01T17:00:00'},
      ], now: now);
      expect(m['returned'], 0);
      expect(m['onTimeRate'], 0.0);
    });

    test('overdue counts loans still out past their due date', () {
      final m = ApiService.reportMetrics([
        {'status': 'Approved', 'due_date': '2026-07-25T17:00:00'},
        {'status': 'Approved', 'due_date': '2999-01-01T17:00:00'},
        {'status': 'Returned', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-21T09:00:00'},
      ], now: now);
      expect(m['overdue'], 1);
      expect(m['borrowings'], 3);
    });

    test('Most Borrowed ranks by count and keeps the top four', () {
      final m = ApiService.reportMetrics([
        {'status': 'Returned', 'equipment_name': 'A', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-20T10:00:00'},
        {'status': 'Returned', 'equipment_name': 'A', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-20T10:00:00'},
        {'status': 'Returned', 'equipment_name': 'A', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-20T10:00:00'},
        {'status': 'Approved', 'equipment_name': 'B', 'due_date': '2999-01-01T17:00:00'},
        {'status': 'Approved', 'equipment_name': 'B', 'due_date': '2999-01-01T17:00:00'},
        {'status': 'Approved', 'equipment_name': 'C', 'due_date': '2999-01-01T17:00:00'},
        {'status': 'Approved', 'equipment_name': 'D', 'due_date': '2999-01-01T17:00:00'},
        {'status': 'Approved', 'equipment_name': 'E', 'due_date': '2999-01-01T17:00:00'},
      ], now: now);
      final ranked = m['mostBorrowed'] as Map<String, int>;
      expect(ranked.length, 4);
      expect(ranked.keys.first, 'A');
      expect(ranked['A'], 3);
      expect(ranked['B'], 2);
    });
  });

  // Regression: the Home banner and Lab Policies both promised that overdue
  // items stop you borrowing, but only a staff-placed hold blocked anything
  // (QA 2026-09-19, M6). borrowEquipment now gates on this.
  group('Overdue loans gate', () {
    final now = DateTime(2026, 7, 27, 12, 0);

    test('an approved loan past its due date is overdue', () {
      final late = ApiService.overdueLoans([
        {'status': 'Approved', 'equipment_name': 'Theodolite', 'due_date': '2026-07-25T17:00:00'},
      ], now: now);
      expect(late.length, 1);
      expect(late.first['equipment_name'], 'Theodolite');
    });

    test('an approved loan not yet due is not overdue', () {
      final late = ApiService.overdueLoans([
        {'status': 'Approved', 'due_date': '2026-07-27T17:00:00'},
      ], now: now);
      expect(late, isEmpty);
    });

    test('returned, pending and rejected are never overdue', () {
      final late = ApiService.overdueLoans([
        {'status': 'Returned', 'due_date': '2026-07-20T17:00:00', 'return_date': '2026-07-22T09:00:00'},
        {'status': 'Pending',  'due_date': '2026-07-20T17:00:00'},
        {'status': 'Rejected', 'due_date': '2026-07-20T17:00:00'},
      ], now: now);
      expect(late, isEmpty);
    });

    test('a loan with no due date is not treated as overdue', () {
      final late = ApiService.overdueLoans([
        {'status': 'Approved'},
      ], now: now);
      expect(late, isEmpty);
    });
  });

  // Made public 2026-09-21 so the student Home screen can age out alert cards
  // without importing cloud_firestore. Firestore Timestamps are covered by the
  // groups above, which run this through real transaction maps.
  group('asDate', () {
    test('parses an ISO string', () {
      expect(ApiService.asDate('2026-07-20T17:00:00'),
          DateTime(2026, 7, 20, 17, 0));
    });
    test('parses the space-separated form Firestore prints', () {
      expect(ApiService.asDate('2026-07-20 17:00:00'),
          DateTime(2026, 7, 20, 17, 0));
    });
    test('returns null for null', () {
      expect(ApiService.asDate(null), isNull);
    });
    test('returns null for an unparseable value rather than throwing', () {
      expect(ApiService.asDate('not a date'), isNull);
      expect(ApiService.asDate(''), isNull);
    });
  });

  group('courseLabel', () {
    test('maps known program codes to full names', () {
      expect(courseLabel('CE'), 'Civil Engineering');
      expect(courseLabel('Arch'), 'Architecture');
    });
    test('falls back to the raw code for unknown values', () {
      expect(courseLabel('BSIT'), 'BSIT');
    });
  });

  // Regression: studentId used to int.parse the Firebase UID, which is always
  // alphanumeric, so it was always 0 and Edit Profile wrote to students/0.
  group('Session.studentId', () {
    tearDown(Session.clear);

    test('is the Firebase UID exactly as stored', () {
      Session.set({'student_id': 'aB3xY9kLmN0pQrStUvWx12345678'}, 'student');
      expect(Session.studentId, 'aB3xY9kLmN0pQrStUvWx12345678');
    });
    test('is empty (not 0) when nobody is signed in', () {
      Session.clear();
      expect(Session.studentId, '');
    });
  });

  // Regression (QA 2026-09-23, F1): a double space in a name split into an
  // empty piece, ''[0] threw, and every avatar for that user red-screened.
  group('Session.initials', () {
    tearDown(Session.clear);

    test('survives repeated, leading and trailing whitespace', () {
      expect(Session.initialsOf('ce  demo'), 'CD');
      expect(Session.initialsOf('  juan \t dela cruz '), 'JD');
    });
    test('one word gives one initial', () {
      expect(Session.initialsOf('admin'), 'A');
    });
    test('blank names fall back instead of throwing', () {
      expect(Session.initialsOf(''), '?');
      expect(Session.initialsOf('   '), '?');
      Session.set({'name': '   '}, 'student');
      expect(Session.initials, 'U');
    });
    test('the signed-in getter uses the same rule', () {
      Session.set({'name': 'Lab  Admin 1'}, 'staff');
      expect(Session.initials, 'LA');
    });
  });

  // QA 2026-09-23, F5: the four staff roles and what each getter reports.
  group('Session staff roles', () {
    tearDown(Session.clear);

    void as(String r) => Session.set({'role': r}, 'staff');

    test('superadmin can manage, labelled SUPER ADMIN', () {
      as('superadmin');
      expect(Session.isSuper, isTrue);
      expect(Session.canManage, isTrue);
      expect(Session.isViewer, isFalse);
      expect(Session.staffRoleLabel, 'SUPER ADMIN');
    });
    // F4: the two labels carry identical permissions, by design.
    test('admin and staff get exactly the same answers', () {
      for (final r in ['admin', 'staff']) {
        as(r);
        expect(Session.isSuper, isFalse, reason: r);
        expect(Session.canManage, isTrue, reason: r);
        expect(Session.isViewer, isFalse, reason: r);
        expect(Session.staffRoleLabel, r.toUpperCase());
      }
    });
    test('viewer can manage nothing', () {
      as('viewer');
      expect(Session.isViewer, isTrue);
      expect(Session.canManage, isFalse);
      expect(Session.isSuper, isFalse);
    });
    test('a missing role defaults to staff', () {
      Session.set({}, 'staff');
      expect(Session.staffRole, 'staff');
      expect(Session.canManage, isTrue);
    });
    test('a student is never staff, whatever its map says', () {
      Session.set({'role': 'superadmin'}, 'student');
      expect(Session.isSuper, isFalse);
      expect(Session.canManage, isFalse);
    });
  });

  // QA 2026-09-23, F2: the portal folds live copies of its own staff document
  // into the session; these pin down what it is told about each change.
  group('Session.refreshStaff', () {
    tearDown(Session.clear);

    void signIn(String role) => Session.set(
        {'name': 'Lab Admin 2', 'email': 'admin2@neu.edu.ph', 'role': role,
         'staff_id': 'uid2'}, 'staff');
    Map<String, dynamic> doc(String role, {String name = 'Lab Admin 2'}) =>
        {'name': name, 'email': 'admin2@neu.edu.ph', 'role': role};

    test('the same document again reports nothing', () {
      signIn('admin');
      final c = Session.refreshStaff(doc('admin'));
      expect([c.nameChanged, c.roleChanged, c.narrowed], [false, false, false]);
    });
    test('demoted to View Only: narrowed, and the session is a viewer now', () {
      signIn('admin');
      final c = Session.refreshStaff(doc('viewer'));
      expect(c.roleChanged, isTrue);
      expect(c.narrowed, isTrue);
      expect(Session.canManage, isFalse);
      expect(Session.staffRoleLabel, 'VIEWER');
    });
    test('super admin to admin is narrowed: Staff Accounts is gone', () {
      signIn('superadmin');
      final c = Session.refreshStaff(doc('admin'));
      expect(c.narrowed, isTrue);
      expect(Session.isSuper, isFalse);
      expect(Session.canManage, isTrue);
    });
    test('promotion and admin/staff relabels are not narrowed', () {
      for (final (from, to) in [('viewer', 'admin'), ('admin', 'superadmin'),
                                ('admin', 'staff'), ('staff', 'admin')]) {
        signIn(from);
        final c = Session.refreshStaff(doc(to));
        expect(c.roleChanged, isTrue, reason: '$from → $to');
        expect(c.narrowed, isFalse, reason: '$from → $to');
      }
    });
    test('a rename is reported, and staff_id survives the refresh', () {
      signIn('admin');
      final c = Session.refreshStaff(doc('admin', name: 'Engr. R. Bello'));
      expect(c.nameChanged, isTrue);
      expect(c.roleChanged, isFalse);
      expect(Session.name, 'Engr. R. Bello');
      expect(Session.staffId, 'uid2');
    });
    test('a student session is left alone', () {
      Session.set({'name': 'ce demo', 'student_id': 's1'}, 'student');
      final c = Session.refreshStaff(doc('superadmin'));
      expect(c.roleChanged, isFalse);
      expect(Session.name, 'ce demo');
    });
  });

  // QA 2026-09-23, F4. The e-mail gate is the one place Admin and Lab Staff
  // differ, and it used to treat a Super Admin as Lab Staff. These accounts
  // are all created after the cutoff, so only the role can let them through
  // — and it does, without asking Firebase Auth anything.
  group('E-mail gate for staff levels', () {
    final recent = {'created_at': Timestamp.fromDate(DateTime.utc(2026, 9, 23))};

    test('provisioned levels skip it, superadmin included', () {
      for (final r in ['superadmin', 'admin', 'viewer']) {
        expect(ApiService.passesVerificationGate({...recent, 'role': r}, isStaff: true),
            isTrue, reason: r);
      }
    });
    test('Lab Staff is the one level that must verify', () {
      expect(kProvisionedStaffRoles, isNot(contains('staff')));
      expect(kProvisionedStaffRoles.union({'staff'}), kStaffRoles.toSet());
    });
    test('a Lab Staff account from before the cutoff still gets in', () {
      expect(ApiService.passesVerificationGate({'role': 'staff'}, isStaff: true), isTrue);
    });
  });
}
