// Unit tests for the pure business logic in ApiService — no Firebase or
// network needed, so these run in plain `flutter test`.

import 'package:flutter_test/flutter_test.dart';

// These now import only the service layer and shared constants — the pure
// business logic no longer pulls in the UI module at all.
import 'package:cea_lab_app/constants.dart';
import 'package:cea_lab_app/services/api_service.dart';

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

  group('courseLabel', () {
    test('maps known program codes to full names', () {
      expect(courseLabel('CE'), 'Civil Engineering');
      expect(courseLabel('Arch'), 'Architecture');
    });
    test('falls back to the raw code for unknown values', () {
      expect(courseLabel('BSIT'), 'BSIT');
    });
  });
}
