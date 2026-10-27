// Unit tests for the pure business logic in ApiService — no Firebase or
// network needed, so these run in plain `flutter test`.

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';

// These now import only the service layer and shared constants — the pure
// business logic no longer pulls in the UI module at all.
import 'package:cea_lab_app/constants.dart';
import 'package:cea_lab_app/services/api_service.dart';
import 'package:cea_lab_app/services/full_report.dart';
import 'package:cea_lab_app/services/full_report_pdf.dart';
import 'package:cea_lab_app/services/qr_labels.dart';
import 'package:cea_lab_app/services/report_xlsx.dart';
import 'package:cea_lab_app/services/session.dart';
import 'package:cea_lab_app/services/xlsx.dart';

void main() {
  group('Due-date policy (same-day 10:00 PM cap)', () {
    final morning = DateTime(2026, 7, 25, 9, 0);

    test('honours a requested time before 10 PM, on today\'s date', () {
      final due = ApiService.computeDueDate(morning, DateTime(2026, 7, 25, 15, 30));
      expect(due, DateTime(2026, 7, 25, 15, 30));
    });

    test('a time after 5 PM is allowed since 1.0.20', () {
      final due = ApiService.computeDueDate(morning, DateTime(2026, 7, 25, 19, 45));
      expect(due, DateTime(2026, 7, 25, 19, 45));
    });

    test('a requested time of exactly 10:00 PM is allowed', () {
      final due = ApiService.computeDueDate(morning, DateTime(2026, 7, 25, 22, 0));
      expect(due, DateTime(2026, 7, 25, 22, 0));
    });

    test('clamps a requested time after 10 PM to 10:00 PM', () {
      final due = ApiService.computeDueDate(morning, DateTime(2026, 7, 25, 22, 1));
      expect(due, DateTime(2026, 7, 25, 22, 0));
    });

    test('defaults to 10:00 PM when no time was requested', () {
      final due = ApiService.computeDueDate(morning, null);
      expect(due, DateTime(2026, 7, 25, 22, 0));
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

    test('a requested time earlier than now falls back to 10:00 PM', () {
      final due = ApiService.computeDueDate(afternoon, DateTime(2026, 7, 25, 9, 0));
      expect(due, DateTime(2026, 7, 25, 22, 0));
    });

    test('a requested time equal to now falls back to 10:00 PM', () {
      final due = ApiService.computeDueDate(afternoon, DateTime(2026, 7, 25, 14, 0));
      expect(due, DateTime(2026, 7, 25, 22, 0));
    });

    test('a requested time still ahead is honoured', () {
      final due = ApiService.computeDueDate(afternoon, DateTime(2026, 7, 25, 16, 30));
      expect(due, DateTime(2026, 7, 25, 16, 30));
    });
  });

  // Regression: registration dropped the Condition field, so every item was
  // stored Available — a scope registered For Disposal was immediately
  // borrowable (QA 2026-09-19, M1). addEquipmentUnits now maps through here.
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

  // Register Equipment's Quantity used to be validated and then thrown away,
  // so a lot of ten flasks became one record. Each unit is now its own record,
  // named and numbered the way the 2026-10-02 import named them.
  group('Registration: one numbered record per unit', () {
    test('a single unit keeps its plain name', () {
      expect(ApiService.unitNames('Current Meter', 1, const []), ['Current Meter']);
    });
    test('several units are numbered from #1', () {
      expect(ApiService.unitNames('Beaker 250 mL', 3, const []),
          ['Beaker 250 mL #1', 'Beaker 250 mL #2', 'Beaker 250 mL #3']);
    });
    test('numbers are padded to the width of the highest one', () {
      final names = ApiService.unitNames('Total Station', 10, const []);
      expect(names.first, 'Total Station #01');
      expect(names.last, 'Total Station #10');
      expect(names.length, 10);
    });
    test('numbering carries on after the units already there', () {
      final existing = [for (var i = 1; i <= 9; i++) 'Flask 500 mL #$i'];
      expect(ApiService.unitNames('Flask 500 mL', 3, existing),
          ['Flask 500 mL #10', 'Flask 500 mL #11', 'Flask 500 mL #12']);
    });
    test('one more unit is numbered when numbered ones exist', () {
      expect(
          ApiService.unitNames(
              'Flask 500 mL', 1, const ['Flask 500 mL #1', 'Flask 500 mL #2']),
          ['Flask 500 mL #3']);
    });
    test('keeps the padding already in use', () {
      expect(
          ApiService.unitNames(
              'Total Station', 2, const ['Total Station #01', 'Total Station #10']),
          ['Total Station #11', 'Total Station #12']);
      expect(ApiService.unitNames('Sieve', 1, const ['Sieve #007']), ['Sieve #008']);
    });
    test('ignores names that only share a prefix', () {
      expect(
          ApiService.unitNames(
              'Flask', 2, const ['Flask 500 mL #4', 'Flask #2b', 'Flask']),
          ['Flask #1', 'Flask #2']);
    });
  });

  group('Registration: QR codes', () {
    test('category prefix and six clock digits, one apart per unit', () {
      expect(ApiService.qrCodesFor('Tools', 3, 1759380137900, {}),
          ['TOO-137900', 'TOO-137901', 'TOO-137902']);
    });
    test('keeps leading zeros', () {
      expect(ApiService.qrCodesFor('Optics', 1, 1759380000042, {}), ['OPT-000042']);
    });
    test('skips codes already in use', () {
      expect(ApiService.qrCodesFor('Tools', 3, 1759380137900, {'TOO-137901'}),
          ['TOO-137900', 'TOO-137902', 'TOO-137903']);
    });
    test('wraps around after 999999', () {
      expect(ApiService.qrCodesFor('Other', 2, 1759380999999, {}),
          ['OTH-999999', 'OTH-000000']);
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

  // Every staff list maps all of its records through isoDate, so it must never
  // throw: one record holding the wrong type used to stop the whole list from
  // loading (QA 2026-10-03).
  group('isoDate', () {
    test('converts a Timestamp to the ISO string the screens split on', () {
      final when = DateTime(2026, 10, 3, 9, 30);
      expect(ApiService.isoDate(Timestamp.fromDate(when)), when.toIso8601String());
    });
    test('a missing field is undated', () {
      expect(ApiService.isoDate(null), '');
    });
    test('a value of any other type is undated, not an error', () {
      expect(ApiService.isoDate('2026-10-03'), '');
      expect(ApiService.isoDate(42), '');
      expect(ApiService.isoDate({'seconds': 1}), '');
      expect(ApiService.isoDate(['x']), '');
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

  // Borrowing by item type (prof's comment 2026-10-05: borrowing was
  // confusing; the Quantity box reserved nothing).
  group('Borrowing by item type', () {
    test('baseNameOf strips the unit number only', () {
      expect(ApiService.baseNameOf('Beaker 1000 mL #3'), 'Beaker 1000 mL');
      expect(ApiService.baseNameOf('Total Station #01'), 'Total Station');
      expect(ApiService.baseNameOf('Current Meter'), 'Current Meter');
      // A '#' that is not a trailing unit number stays.
      expect(ApiService.baseNameOf('Sieve #200 mesh'), 'Sieve #200 mesh');
    });

    test('unitNumberOf reads the trailing number', () {
      expect(ApiService.unitNumberOf('Flask 500 mL #10'), 10);
      expect(ApiService.unitNumberOf('Total Station #01'), 1);
      expect(ApiService.unitNumberOf('Current Meter'), 0);
    });

    Map<String, dynamic> unit(String id, String name, String status) =>
        {'equipment_id': id, 'equipment_name': name, 'status': status};
    final beakers = [
      unit('b3', 'Beaker 1000 mL #3', 'Available'),
      unit('b1', 'Beaker 1000 mL #1', 'Borrowed'),
      unit('b10', 'Beaker 1000 mL #10', 'Available'),
      unit('b2', 'Beaker 1000 mL #2', 'Available'),
      unit('b4', 'Beaker 1000 mL #4', 'Under Repair'),
    ];

    test('pickUnits takes free units in number order', () {
      final got = ApiService.pickUnits(beakers, 2);
      expect(got.map((u) => u['equipment_id']), ['b2', 'b3']);
    });

    test('pickUnits puts the unit the student looked at first', () {
      final got = ApiService.pickUnits(beakers, 2, preferId: 'b10');
      expect(got.map((u) => u['equipment_id']), ['b10', 'b2']);
    });

    test('pickUnits ignores a preferred unit that is not free', () {
      final got = ApiService.pickUnits(beakers, 1, preferId: 'b1');
      expect(got.map((u) => u['equipment_id']), ['b2']);
    });

    test('pickUnits returns fewer when not enough are free', () {
      expect(ApiService.pickUnits(beakers, 5).length, 3);
    });

    test('records of one submit group into one request', () {
      final t = [
        {'student_id': 's1', 'borrow_date': '2026-10-05T15:21:00.000', 'equipment_name': 'Beaker 1000 mL #1'},
        {'student_id': 's1', 'borrow_date': '2026-10-05T15:21:00.000', 'equipment_name': 'Beaker 1000 mL #2'},
        {'student_id': 's2', 'borrow_date': '2026-10-05T15:21:00.000', 'equipment_name': 'Flask 500 mL #1'},
        {'student_id': 's1', 'borrow_date': '2026-10-04T09:00:00.000', 'equipment_name': 'Rubber Mallet #1'},
      ];
      final groups = ApiService.groupRequests(t);
      expect(groups.length, 3);
      expect(groups.first.length, 2);
      expect(ApiService.requestSummary(groups.first), 'Beaker 1000 mL × 2');
    });

    test('requestSummary lists each type once, with its count', () {
      final records = [
        {'equipment_name': 'Beaker 1000 mL #1'},
        {'equipment_name': 'Flask 500 mL #4'},
        {'equipment_name': 'Beaker 1000 mL #2'},
      ];
      expect(ApiService.requestSummary(records), 'Beaker 1000 mL × 2, Flask 500 mL');
    });

    // QA 2026-10-06: the same request read "Flask, Beaker × 2" on one screen
    // and "Beaker × 2, Flask" on another, following the record order.
    test('requestSummary is alphabetical whatever the record order', () {
      final records = [
        {'equipment_name': 'Flask 500 mL #1'},
        {'equipment_name': 'Beaker 1000 mL #2'},
        {'equipment_name': 'Air-Content Apparatus'},
        {'equipment_name': 'Beaker 1000 mL #1'},
      ];
      expect(ApiService.requestSummary(records),
          'Air-Content Apparatus, Beaker 1000 mL × 2, Flask 500 mL');
    });

    // QA 2026-10-06: a request partly returned and partly rejected showed as
    // one "Returned" card, rejected items included.
    test('groupRequests byStatus splits a request by its status', () {
      Map<String, dynamic> rec(String name, String status) => {
            'student_id': 's1',
            'borrow_date': '2026-10-06T12:00:00.000',
            'equipment_name': name,
            'status': status,
          };
      final t = [
        rec('Depth Gauge with Torpedo #2', 'Returned'),
        rec('Beaker 1000 mL #1', 'Returned'),
        rec('Air-Content Apparatus', 'Rejected'),
        rec('Depth Gauge with Torpedo #2', 'Rejected'),
      ];
      expect(ApiService.groupRequests(t).length, 1);
      final split = ApiService.groupRequests(t, byStatus: true);
      expect(split.length, 2);
      expect(split.map((g) => g.map((r) => r['status']).toSet()),
          [{'Returned'}, {'Rejected'}]);
      expect(ApiService.requestSummary(split.last),
          'Air-Content Apparatus, Depth Gauge with Torpedo');
    });
  });

  // 2026-10-06: sending a request reserves its units.
  group('Reservations', () {
    test('a unit reserved for this request is held for it', () {
      final eq = {'status': 'Reserved', 'reserved_tx': 'tx1', 'reserved_by': 's1'};
      expect(ApiService.isReservedFor(eq, 'tx1'), isTrue);
    });

    test('a unit reserved for another request is not', () {
      final eq = {'status': 'Reserved', 'reserved_tx': 'tx2', 'reserved_by': 's2'};
      expect(ApiService.isReservedFor(eq, 'tx1'), isFalse);
    });

    test('a free, lent or missing unit is not held for anyone', () {
      expect(ApiService.isReservedFor({'status': 'Available'}, 'tx1'), isFalse);
      // A leftover reserved_tx on a lent unit does not count.
      expect(ApiService.isReservedFor({'status': 'Borrowed', 'reserved_tx': 'tx1'}, 'tx1'),
          isFalse);
      expect(ApiService.isReservedFor(null, 'tx1'), isFalse);
    });

    test('pickUnits never offers a reserved unit (reservation)', () {
      final units = [
        {'equipment_id': 'f1', 'equipment_name': 'Flask 500 mL #1', 'status': 'Reserved'},
        {'equipment_id': 'f2', 'equipment_name': 'Flask 500 mL #2', 'status': 'Available'},
      ];
      expect(ApiService.pickUnits(units, 2, preferId: 'f1').map((u) => u['equipment_id']),
          ['f2']);
    });
  });

  // 2026-10-06: approved units wait at the lab until staff hand them over.
  group('Pick-up and overdue', () {
    final now = DateTime(2026, 10, 6, 18, 0);
    const past = '2026-10-06T17:00:00.000';
    Map<String, dynamic> rec(String id, String eq, String name,
            {String status = 'Approved', bool? waiting, String due = past}) =>
        {
          'transaction_id': id,
          'student_id': 's1',
          'borrow_date': '2026-10-06T09:00:00.000',
          'equipment_id': eq,
          'equipment_name': name,
          'status': status,
          'due_date': due,
          'awaiting_pickup': ?waiting,
        };

    test('an approved unit still at the lab is not out, and never overdue', () {
      final t = rec('t1', 'b1', 'Beaker 1000 mL #1', waiting: true);
      expect(ApiService.awaitingPickup(t), isTrue);
      expect(ApiService.isOut(t), isFalse);
      expect(ApiService.isOverdue(t, now: now), isFalse);
      expect(ApiService.overdueLoans([t], now: now), isEmpty);
    });

    test('a loan approved before pick-up existed counts as handed over', () {
      final t = rec('t1', 'b1', 'Beaker 1000 mL #1');
      expect(ApiService.isOut(t), isTrue);
      expect(ApiService.isOverdue(t, now: now), isTrue);
    });

    test('reliability and reports do not count a waiting unit as overdue', () {
      final txns = [
        rec('t1', 'b1', 'Beaker 1000 mL #1', waiting: true),
        rec('t2', 'b2', 'Beaker 1000 mL #2'),
      ];
      expect(ApiService.studentReliability(txns, now: now)['overdue'], 1);
      expect(ApiService.reportMetrics(txns, now: now)['overdue'], 1);
    });

    test('groupRequests byPickup puts waiting and handed-over units apart', () {
      final txns = [
        rec('t1', 'b1', 'Beaker 1000 mL #1', waiting: true),
        rec('t2', 'b2', 'Beaker 1000 mL #2'),
      ];
      expect(ApiService.groupRequests(txns).length, 1);
      expect(ApiService.groupRequests(txns, byPickup: true).length, 2);
    });

    group('handOverTarget', () {
      final request = [
        rec('t1', 'b1', 'Beaker 1000 mL #1', waiting: true),
        rec('t2', 'b2', 'Beaker 1000 mL #2', waiting: true),
        rec('t3', 'f1', 'Flask 500 mL #1'), // already handed over
      ];
      Map<String, dynamic> unit(String id, String name) =>
          {'equipment_id': id, 'equipment_name': name};

      test('the unit set aside is handed over as itself', () {
        expect(ApiService.handOverTarget(request, unit('b2', 'Beaker 1000 mL #2'))?['transaction_id'],
            't2');
      });

      test('another unit of the same item takes a waiting record', () {
        expect(ApiService.handOverTarget(request, unit('b7', 'Beaker 1000 mL #7'))?['transaction_id'],
            't1');
      });

      test('an item the request did not ask for is refused', () {
        expect(ApiService.handOverTarget(request, unit('m1', 'Rubber Mallet #1')), isNull);
      });

      test('a type already fully handed over has nothing left to take', () {
        expect(ApiService.handOverTarget(request, unit('f2', 'Flask 500 mL #2')), isNull);
      });
    });

    // Live test 2026-10-07 (U1): a request cancelled meanwhile was shown as
    // "Everything is handed over."
    group('handOverState', () {
      test('something set aside is still waiting', () {
        expect(ApiService.handOverState([
          rec('t1', 'b1', 'Beaker 1000 mL #1', waiting: true),
          rec('t2', 'f1', 'Flask 500 mL #1'),
        ]), 'waiting');
      });

      test('everything in the student\'s hands is done', () {
        expect(ApiService.handOverState([
          rec('t1', 'b1', 'Beaker 1000 mL #1'),
          rec('t2', 'f1', 'Flask 500 mL #1'),
        ]), 'done');
      });

      test('a request cancelled, rejected or still Pending is over, not done', () {
        expect(ApiService.handOverState([
          rec('t1', 'b1', 'Beaker 1000 mL #1', status: 'Cancelled'),
        ]), 'over');
        expect(ApiService.handOverState([
          rec('t1', 'b1', 'Beaker 1000 mL #1', status: 'Rejected'),
          rec('t2', 'f1', 'Flask 500 mL #1', status: 'Returned'),
        ]), 'over');
        expect(ApiService.handOverState([
          rec('t1', 'b1', 'Beaker 1000 mL #1', status: 'Pending'),
        ]), 'over');
      });

      test('part handed over, the rest not picked up, is done', () {
        expect(ApiService.handOverState([
          rec('t1', 'b1', 'Beaker 1000 mL #1'),
          rec('t2', 'f1', 'Flask 500 mL #1', status: 'Cancelled'),
        ]), 'done');
      });
    });
  });

  // Equipment dates (date acquired / date added), prof's comment 2026-10-05.
  group('formatDate', () {
    test('writes month name, day, year', () {
      expect(formatDate(DateTime(1992, 5, 6)), 'May 6, 1992');
      expect(formatDate(DateTime(2026, 10, 2, 14, 30)), 'Oct 2, 2026');
    });
    test('covers the first and last months', () {
      expect(formatDate(DateTime(1991, 1, 18)), 'Jan 18, 1991');
      expect(formatDate(DateTime(2025, 12, 31)), 'Dec 31, 2025');
    });
    test('reads a stored Timestamp the same way, via asDate', () {
      final ts = Timestamp.fromDate(DateTime(1991, 7, 18));
      expect(formatDate(ApiService.asDate(ts)!), 'Jul 18, 1991');
    });
  });

  // Live test 2026-10-07: an item without a QR code read "Digital Multimeter  •".
  group('joinParts', () {
    test('puts the separator only between parts that are there', () {
      expect(joinParts(['Beaker 1000 mL #1', 'OTH-137911']), 'Beaker 1000 mL #1  •  OTH-137911');
      expect(joinParts(['Digital Multimeter', '']), 'Digital Multimeter');
      expect(joinParts([null, 'Electronics'], separator: '  ·  '), 'Electronics');
      expect(joinParts(['', ' ', null]), '');
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

  // 2026-10-06: Reports in plain words (staff found them hard to read).
  group('Plain statuses (loanOutcome)', () {
    final now = DateTime(2026, 10, 6, 18, 0);
    String o(Map<String, dynamic> t) => ApiService.loanOutcome(t, now: now);

    test('each stored state reads as what happened', () {
      expect(o({'status': 'Pending'}), 'Waiting for approval');
      expect(o({'status': 'Rejected'}), 'Rejected');
      expect(o({'status': 'Approved', 'awaiting_pickup': true,
          'due_date': '2026-10-06T17:00:00'}), 'Ready for pick-up');
      expect(o({'status': 'Approved', 'due_date': '2026-10-06T17:00:00'}), 'Overdue');
      expect(o({'status': 'Approved', 'due_date': '2026-10-06T18:30:00'}), 'On loan');
    });

    test('a return says whether it was late', () {
      expect(o({'status': 'Returned', 'due_date': '2026-10-06T17:00:00',
          'return_date': Timestamp.fromDate(DateTime(2026, 10, 6, 16, 59))}), 'Returned on time');
      expect(o({'status': 'Returned', 'due_date': '2026-10-06T17:00:00',
          'return_date': Timestamp.fromDate(DateTime(2026, 10, 6, 17, 20))}), 'Returned late');
    });

    test('a cancel says who cancelled, or that nobody came', () {
      expect(o({'status': 'Cancelled'}), 'Cancelled by student');
      expect(o({'status': 'Cancelled', 'cancel_reason': 'Not picked up',
          'cancelled_by_name': 'Lab Staff'}), 'Not picked up');
      expect(o({'status': 'Cancelled', 'cancelled_by_name': 'Lab Staff'}), 'Cancelled by staff');
    });

    // 2026-10-07: a staff cancel now gets a "Request Cancelled" alert on the
    // student's Home; their own cancel does not.
    test('cancelledByStaff tells a staff cancel from the student\'s own', () {
      expect(ApiService.cancelledByStaff({'status': 'Cancelled'}), isFalse);
      expect(ApiService.cancelledByStaff({'status': 'Cancelled',
          'cancel_reason': 'Not picked up', 'cancelled_by_name': 'Lab Staff'}), isTrue);
      expect(ApiService.cancelledByStaff({'status': 'Cancelled',
          'cancelled_by_name': 'Lab Staff'}), isTrue);
      expect(ApiService.cancelledByStaff({'status': 'Rejected',
          'cancel_reason': 'Not picked up'}), isFalse);
    });
  });

  group('Excel workbook', () {
    test('columns are lettered like Excel', () {
      expect([0, 25, 26, 51, 52].map(Xlsx.column), ['A', 'Z', 'AA', 'AZ', 'BA']);
    });

    test('dates are real Excel dates', () {
      expect(Xlsx.serial(DateTime(1900, 3, 1)), 61);
      expect(Xlsx.serial(DateTime(2000, 1, 1)), 36526);
      expect(Xlsx.serial(DateTime(2000, 1, 1, 18)), 36526.75);
    });

    test('text is escaped and a formula-looking value stays text', () {
      final xml = Xlsx.sheetXml(const XSheet('S', [
        [XCell('Tom & "Jerry" <3'), XCell('=HYPERLINK("x")'), XCell(5), XCell(null)],
      ]));
      expect(xml, contains('Tom &amp; &quot;Jerry&quot; &lt;3'));
      expect(xml, contains('<c r="B1" t="inlineStr"><is><t xml:space="preserve">=HYPERLINK'));
      expect(xml, contains('<c r="C1"><v>5</v></c>'));
      expect(xml, isNot(contains('<f>')));
    });

    // 2026-10-07: the workbook holds the same report as the Full Report page
    // and its PDF (the user: "make the excel report detailed the same").
    test('the report sheet, a requests sheet and the detailed records sheet', () {
      final now = DateTime(2026, 10, 6, 18, 0);
      final txns = [
        {
          'student_id': 's1', 'borrow_date': '2026-10-06T08:00:00',
          'borrower_name': 'Dela Peña, Ana', 'student_number': '26-00001-001',
          'equipment_name': 'Beaker 1000 mL #1', 'qr_code': 'GLS-000001',
          'status': 'Returned', 'due_date': '2026-10-06T17:00:00',
          'return_date': Timestamp.fromDate(DateTime(2026, 10, 6, 17, 30)),
        },
        {
          'student_id': 's1', 'borrow_date': '2026-10-06T08:00:00',
          'borrower_name': 'Dela Peña, Ana', 'student_number': '26-00001-001',
          'equipment_name': 'Beaker 1000 mL #2', 'qr_code': 'GLS-000002',
          'status': 'Returned', 'due_date': '2026-10-06T17:00:00',
          'return_date': Timestamp.fromDate(DateTime(2026, 10, 6, 16, 0)),
        },
      ];
      final report = FullReport(
        madeAt: now, madeBy: 'Lab Staff', days: 30,
        totalBorrowings: 2, totalReturned: 2, totalOverdue: 0, totalDamage: 1,
        totalEquipment: 90, onTimeRate: 50,
        mostBorrowed: const {'Beaker 1000 mL': 2}, requests: txns,
      );
      final zip = ZipDecoder().decodeBytes(ReportXlsx.build(report));
      String part(String name) => utf8.decode(zip.findFile(name)!.content);

      expect(zip.findFile('[Content_Types].xml'), isNotNull);
      final book = part('xl/workbook.xml');
      expect(book.indexOf('<sheet name="Report"'), lessThan(book.indexOf('<sheet name="Requests"')));
      expect(book, contains('<sheet name="Borrowing records"'));

      // The Report sheet: what the PDF's first page says.
      final first = part('xl/worksheets/sheet1.xml');
      for (final shown in ['CEA Laboratory Report', 'Last 30 days: Sep 6, 2026 to Oct 6, 2026',
          'by Lab Staff', 'Total Borrowings', 'On-Time Returns', 'Overdue Items',
          'Damage Reports', 'Total Equipment', 'Returned Successfully',
          'Most Borrowed Equipment', 'Beaker 1000 mL', '1 request for 2 items',
          FullReport.note]) {
        expect(first, contains(shown), reason: shown);
      }
      expect(first, contains('<v>0.5</v>')); // On-Time Returns as a percentage

      // Requests: one row per request, as the PDF lists them.
      final requests = part('xl/worksheets/sheet2.xml');
      for (final c in ReportXlsx.requestColumns) {
        expect(requests, contains('>$c<'));
      }
      expect(requests, contains('Beaker 1000 mL × 2'));
      expect(requests, contains('26-00001-001'));
      expect(requests, contains('<autoFilter ref="A1:F2"/>'));

      // Borrowing records: every item, the stored status and its result.
      final records = part('xl/worksheets/sheet3.xml');
      for (final c in ReportXlsx.recordColumns) {
        expect(records, contains('>$c<'));
      }
      expect(records, contains('Returned late'));
      expect(records, contains('Returned on time'));
      expect(records, contains('Dela Peña, Ana'));
      expect(records, contains('state="frozen"'));
      expect(records, contains('<autoFilter ref="A1:R3"/>'));
      expect(ReportXlsx.fileName(report), 'labtrack-report-2026-10-06-last-30-days.xlsx');
    });
  });

  // 2026-10-07: the Full Report as a PDF to print, same content as the page.
  group('Full report PDF', () {
    FullReport report(int requests) => FullReport(
          madeAt: DateTime(2026, 10, 7, 15, 0),
          madeBy: 'Ramoel Bello',
          start: DateTime(2026, 8, 1),
          end: DateTime(2026, 10, 7),
          totalBorrowings: requests, totalReturned: requests, totalOverdue: 0,
          totalDamage: 0, totalEquipment: 90, onTimeRate: 100,
          mostBorrowed: const {'Beaker 1000 mL': 3},
          requests: [
            for (var i = 0; i < requests; i++)
              {'student_id': 's$i',
               'borrow_date': DateTime(2026, 10, 7, 9).subtract(Duration(hours: i)).toIso8601String(),
               'borrower_name': 'Student — $i', 'equipment_name': 'Flask 500 mL #$i',
               'status': 'Returned'},
          ],
        );

    test('is a PDF named after its dates', () async {
      final bytes = await FullReportPdf.build(report(3));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(FullReportPdf.fileName(report(3)), 'labtrack-report-2026-08-01-to-2026-10-07.pdf');
    });

    test('a long list of requests continues on more pages', () async {
      String pages(Uint8List b) => RegExp(r'/Count (\d+)').firstMatch(latin1.decode(b))!.group(1)!;
      expect(pages(await FullReportPdf.build(report(3))), '1');
      expect(int.parse(pages(await FullReportPdf.build(report(120)))), greaterThan(2));
    });

    // The words on each page, in the order the PDF draws them (the footer
    // first). Each page is drawn by one compressed stream.
    List<String> pageTexts(Uint8List pdf) {
      final s = latin1.decode(pdf);
      final pages = <String>[];
      for (final m in RegExp(r'(?<!end)stream\r?\n').allMatches(s)) {
        final String drawn;
        try {
          drawn = latin1.decode(io.zlib.decode(pdf.sublist(m.end, s.indexOf('endstream', m.end))));
        } on FormatException {
          continue;
        }
        if (!drawn.contains(')]TJ')) continue;
        pages.add(RegExp(r'\[\((.*?)\)\]TJ').allMatches(drawn).map((w) => w[1]).join(' '));
      }
      return pages;
    }

    // [perDay] requests on each day, from Oct 6 back, every one at 8 PM or
    // a little before.
    FullReport days(List<int> perDay) => FullReport(
          madeAt: DateTime(2026, 10, 7, 15, 0),
          madeBy: 'Ramoel Bello',
          start: DateTime(2026, 8, 1),
          end: DateTime(2026, 10, 7),
          totalBorrowings: 1, totalReturned: 1, totalOverdue: 0,
          totalDamage: 0, totalEquipment: 90, onTimeRate: 100,
          mostBorrowed: const {'Beaker 1000 mL': 3},
          requests: [
            for (final (d, n) in perDay.indexed)
              for (var i = 0; i < n; i++)
                {'student_id': 's$d-$i',
                 'borrow_date': DateTime(2026, 10, 6 - d, 20)
                     .subtract(Duration(minutes: i)).toIso8601String(),
                 'borrower_name': 'Student $i', 'equipment_name': 'Flask 500 mL #$i',
                 'status': 'Returned'},
          ],
        );

    // Printed report, 2026-10-07: the rows at the top of a page did not say
    // which day they were from.
    test("a day's name repeats at the top of every page it runs onto", () async {
      final pages = pageTexts(await FullReportPdf.build(days([80])));
      expect(pages.length, greaterThan(2));
      for (final (i, p) in pages.indexed) {
        expect(p, contains('Yesterday, Oct 6, 2026 Time Student Items Status'),
            reason: 'page ${i + 1}');
      }
    });

    // Printed report, 2026-10-07: "Aug 4, 2026" and the column titles sat at
    // the foot of page 2, and that day's one request was on page 3.
    test("a day's name is never left at the foot of a page without a request", () async {
      final request = RegExp(r'[78]:\d\d PM');
      for (var first = 1; first <= 60; first++) {
        final pages = pageTexts(await FullReportPdf.build(days([first, 3])));
        for (final (i, p) in pages.indexed) {
          final a = p.lastIndexOf('Yesterday, Oct 6, 2026'), b = p.lastIndexOf('Oct 5, 2026');
          final name = a > b ? a : b;
          if (name < 0) continue;
          expect(request.hasMatch(p.substring(name)), isTrue,
              reason: 'page ${i + 1} of ${pages.length}, $first requests on the first day');
        }
      }
    });
  });

  group('QR labels', () {
    test('21 labels to an A4 sheet', () {
      expect([0, 1, 21, 22, 90].map(QrLabels.pages), [0, 1, 1, 2, 5]);
    });

    test('text the PDF font cannot draw is made plain', () {
      expect(QrLabels.pdfSafe('Gauge – 2 µm “A” ‘b’ … ✓'), 'Gauge - 2 µm "A" \'b\' ... ?');
    });

    test('builds a PDF, leaving out items with no code', () async {
      final bytes = await QrLabels.build([
        {'equipment_name': 'Beaker 1000 mL #1', 'qr_code': 'GLS-000001'},
        {'equipment_name': 'No code yet', 'qr_code': ''},
      ]);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    // Live test 2026-10-07: the dialog said 90 labels for an 89-label PDF;
    // it now counts from the same list the PDF is made of.
    test('only items with a code get a label', () {
      final items = [
        {'equipment_name': 'Beaker 1000 mL #1', 'qr_code': 'GLS-000001'},
        {'equipment_name': 'Digital Multimeter', 'qr_code': ''},
        {'equipment_name': 'Older item'},
        {'equipment_name': 'Flask 500 mL #1', 'qr_code': ' '},
      ];
      expect(QrLabels.withCode(items).map((e) => e['equipment_name']),
          ['Beaker 1000 mL #1']);
    });
  });

  // 2026-10-07: Export Full Report looked like a computer terminal; the lab
  // staff found it hard to read.
  group('Full report', () {
    final report = FullReport(
      madeAt: DateTime(2026, 10, 7, 14, 5),
      madeBy: 'Ramoel Bello',
      days: 90,
      totalBorrowings: 28,
      totalReturned: 27,
      totalOverdue: 1,
      totalDamage: 4,
      totalEquipment: 90,
      onTimeRate: 92.6,
      mostBorrowed: const {'Beaker 1000 mL': 13, 'Flask 500 mL': 1},
      // Newest first, one record per item, as the Reports tab loads them.
      requests: const [
        // one request, one item
        {'student_id': 's1', 'borrow_date': '2026-10-07T09:05:00.000',
         'borrower_name': 'ce demo', 'equipment_name': 'Beaker 1000 mL #1',
         'status': 'Returned'},
        // one request, three items: two came back, one was refused
        {'student_id': 's2', 'borrow_date': '2026-10-07T08:30:00.000',
         'borrower_name': 'IE Demo', 'equipment_name': 'Beaker 1000 mL #2',
         'status': 'Returned'},
        {'student_id': 's2', 'borrow_date': '2026-10-07T08:30:00.000',
         'borrower_name': 'IE Demo', 'equipment_name': 'Beaker 1000 mL #3',
         'status': 'Returned'},
        {'student_id': 's2', 'borrow_date': '2026-10-07T08:30:00.000',
         'borrower_name': 'IE Demo', 'equipment_name': 'Flask 500 mL #1',
         'status': 'Rejected'},
        // the day before, by student number only
        {'student_id': 's1', 'borrow_date': '2026-10-06T11:56:00.000',
         'student_number': '26-12345-222', 'equipment_name': 'Current Meter',
         'status': 'Cancelled'},
        // two weeks before
        {'student_id': 's3', 'borrow_date': '2026-09-23T13:00:00.000',
         'borrower_name': 'ME Demo', 'equipment_name': 'Keyboard', 'status': 'Approved'},
      ],
    );

    test('says when it was made and what it covers, in words', () {
      expect(report.madeLine, 'Made on Oct 7, 2026 at 2:05 PM by Ramoel Bello');
      expect(report.periodLine, 'Covers the last 90 days: Jul 9, 2026 to Oct 7, 2026');
      expect(FullReport.when(DateTime(2026, 1, 2, 0, 30)), 'Jan 2, 2026 at 12:30 AM');
      expect(FullReport.when(DateTime(2026, 1, 2, 12, 0)), 'Jan 2, 2026 at 12:00 PM');
    });

    test('uses the Reports card names, in their order', () {
      expect(report.figures, [
        ('Total Borrowings', '28'),
        ('On-Time Returns', '93%'),
        ('Overdue Items', '1'),
        ('Damage Reports', '4'),
        ('Total Equipment', '90'),
        ('Returned Successfully', '27'),
      ]);
    });

    // "Too many" (the user): one line per request, not per item, by day.
    test('lists one line per request, under a heading per day', () {
      final days = report.requestDays;
      expect([for (final d in days) d.label],
          ['Today, Oct 7, 2026', 'Yesterday, Oct 6, 2026', 'Sep 23, 2026']);
      expect([for (final l in days[0].lines) (l.time, l.student, l.items, l.status, l.count)], [
        ('9:05 AM', 'ce demo', 'Beaker 1000 mL #1', 'Returned', 1),
        // a request whose items ended differently: one line per status
        ('8:30 AM', 'IE Demo', 'Beaker 1000 mL × 2', 'Returned', 2),
        ('8:30 AM', 'IE Demo', 'Flask 500 mL #1', 'Rejected', 1),
      ]);
      expect(days[0].lines.first.sent, DateTime(2026, 10, 7, 9, 5));
      expect(days[1].lines.single.student, '26-12345-222');
      expect(days[1].lines.single.number, '26-12345-222');
      expect(days[2].lines.single.time, '1:00 PM');
    });

    // 2026-10-07: "Change dates" on the Full Report.
    test('a chosen period reads as its dates and names its files', () {
      FullReport chosen(DateTime a, DateTime b) => FullReport(
          madeAt: DateTime(2026, 10, 7, 15), start: a, end: b,
          totalBorrowings: 0, totalReturned: 0, totalOverdue: 0, totalDamage: 0,
          totalEquipment: 90, onTimeRate: 0);
      final term = chosen(DateTime(2026, 8, 1), DateTime(2026, 10, 7));
      expect(term.isLastDays, isFalse);
      expect(term.periodDays, 68);
      expect(term.periodLine, 'Covers Aug 1, 2026 to Oct 7, 2026 (68 days)');
      expect(term.fileStem, 'labtrack-report-2026-08-01-to-2026-10-07');
      expect(chosen(DateTime(2026, 10, 7), DateTime(2026, 10, 7)).periodLine,
          'Covers Oct 7, 2026 to Oct 7, 2026 (1 day)');
      expect(report.isLastDays, isTrue);
      expect(report.fileStem, 'labtrack-report-2026-10-07-last-90-days');
    });

    test('the figures as numbers for Excel, On-Time Returns as a fraction', () {
      expect(report.figureValues.first, ('Total Borrowings', 28));
      expect(report.figureValues[1].$2, closeTo(0.926, 1e-9));
    });

    test('counts requests and items, and items by status in a fixed order', () {
      expect(report.requestCount, 4);
      expect(report.requestsLine, '4 requests for 6 items');
      expect(report.statusCounts,
          [('Approved', 1), ('Returned', 3), ('Cancelled', 1), ('Rejected', 1)]);
    });

    test('the copied text reads like a document, not a terminal', () {
      final text = report.asText();
      expect(text, contains('CEA LABORATORY REPORT'));
      expect(text, contains('Total Borrowings: 28'));
      expect(text, contains('On-Time Returns: 93%'));
      expect(text, contains('1. Beaker 1000 mL: borrowed 13 times'));
      expect(text, contains('2. Flask 500 mL: borrowed 1 time'));
      expect(text, contains('REQUESTS (newest first)\n4 requests for 6 items\n'
          'Items by status: Approved 1, Returned 3, Cancelled 1, Rejected 1'));
      expect(text, contains('Today, Oct 7, 2026\n'
          '9:05 AM - ce demo - Beaker 1000 mL #1 - Returned\n'
          '8:30 AM - IE Demo - Beaker 1000 mL × 2 - Returned\n'
          '8:30 AM - IE Demo - Flask 500 mL #1 - Rejected\n'));
      expect(text, contains('Yesterday, Oct 6, 2026\n'
          '11:56 AM - 26-12345-222 - Current Meter - Cancelled\n'));
      for (final terminalBit in ['====', '----', '[Returned]', ' | ', 'Courier']) {
        expect(text, isNot(contains(terminalBit)));
      }
    });

    test('an empty period says so', () {
      final empty = FullReport(madeAt: DateTime(2026, 10, 7), days: 90,
          totalBorrowings: 0, totalReturned: 0, totalOverdue: 0, totalDamage: 0,
          totalEquipment: 90, onTimeRate: 0);
      expect(empty.madeLine, 'Made on Oct 7, 2026 at 12:00 AM');
      expect(empty.asText(), contains('Nothing was borrowed in this period.'));
      expect(empty.asText(), contains('No requests in this period.'));
    });
  });

  // 2026-10-13 (pen test R3): students sign in with their email only. A
  // student number is answered before Firebase is touched, so this needs no
  // connection.
  group('Student login', () {
    test('a student number is refused with a plain message', () async {
      final res = await ApiService.login('26-12345-222', 'secret', 'student');
      expect(res['success'], isFalse);
      expect(res['message'], kStudentIdLoginMessage);
    });
  });

  // 1.0.19 (2026-10-15): one record lists the item types, so students read it
  // instead of every unit (1,067 after the import).
  group('Item types', () {
    Map<String, dynamic> unit(String name, String status,
            {String category = 'Measurement',
            String location = 'ELWO – CE Laboratory',
            List<String> courses = const ['CE']}) =>
        {
          'equipment_name': name,
          'status': status,
          'category': category,
          'location': location,
          'courses': courses,
        };

    test('Under Repair and For Disposal are out of service', () {
      expect(ApiService.isOutOfService('Under Repair'), isTrue);
      expect(ApiService.isOutOfService('For Disposal'), isTrue);
      for (final s in ['Available', 'Reserved', 'Borrowed', null]) {
        expect(ApiService.isOutOfService(s), isFalse);
      }
    });

    test('the list counts units and units out of service per type', () {
      final index = ApiService.buildTypeIndex([
        unit('Pocket Type Level #1', 'Available'),
        unit('Pocket Type Level #2', 'Borrowed'),
        unit('Pocket Type Level #3', 'Under Repair'),
        unit('Pantograph', 'Available'),
        unit('Total Station #01', 'For Disposal'),
        unit('', 'Available'),
      ]);
      expect(index.keys.toSet(), {'Pocket Type Level', 'Pantograph', 'Total Station'});
      expect(index['Pocket Type Level']!['units'], 3);
      expect(index['Pocket Type Level']!['out'], 1);
      expect(index['Pantograph']!['units'], 1);
      expect(index['Total Station']!['out'], 1);
    });

    test("a type takes most of its units' category and location", () {
      final index = ApiService.buildTypeIndex([
        unit('Digital Multimeter', 'Available', category: 'Electronics', location: ''),
        unit('Digital Multimeter #01', 'Available'),
        unit('Digital Multimeter #02', 'Available'),
      ]);
      expect(index['Digital Multimeter']!['category'], 'Measurement');
      expect(index['Digital Multimeter']!['location'], 'ELWO – CE Laboratory');
    });

    test("a type's programs are all its units' programs, or none if any unit has none", () {
      expect(ApiService.typeCourses([
        unit('A #1', 'Available', courses: ['ECE']),
        unit('A #2', 'Available', courses: ['EE', 'ECE']),
      ]), ['ECE', 'EE']);
      expect(ApiService.typeCourses([
        unit('A #1', 'Available', courses: ['CE']),
        unit('A #2', 'Available', courses: []),
      ]), isEmpty);
    });

    test('the stored list reads back by name, with units in service', () {
      final list = ApiService.typeListFrom({
        'pantograph': {'units': 1, 'out': 0, 'category': 'Measurement'},
        'Analog Base Trainer': {'units': 5, 'out': 5, 'category': 'Electronics'},
        'Gone': {'units': 0, 'out': 0},
        'Odd': {'units': 2, 'out': 7},
      });
      expect(list.map((t) => t['name']), ['Analog Base Trainer', 'Odd', 'pantograph']);
      expect(list.first['in_service'], 0);
      expect(list[1]['out'], 2);
      expect(list.last['in_service'], 1);
    });

    test('a new unit adds to its type, with its details', () {
      final d = ApiService.typeDelta(null, unit('Wire Saw #3', 'Available'));
      expect(d.keys, ['Wire Saw']);
      expect(d['Wire Saw']!['units'], 1);
      expect(d['Wire Saw']!['out'], 0);
      expect(d['Wire Saw']!['category'], 'Measurement');
      expect(d['Wire Saw']!['courses'], ['CE']);
    });

    test('a deleted unit leaves its type, out of service or not', () {
      final d = ApiService.typeDelta(unit('Total Station #04', 'Under Repair'), null);
      expect(d['Total Station']!['units'], -1);
      expect(d['Total Station']!['out'], -1);
      expect(d['Total Station']!.containsKey('category'), isFalse);
    });

    test('a status change moves only the out-of-service count', () {
      final before = unit('Total Station #04', 'Under Repair');
      final d = ApiService.typeDelta(before, {...before, 'status': 'Available'});
      expect(d['Total Station'], {'units': 0, 'out': -1});
    });

    test('an unchanged edit changes nothing', () {
      final u = unit('Pocket Type Level #2', 'Available');
      expect(ApiService.typeDelta(u, Map<String, dynamic>.from(u))['Pocket Type Level'],
          {'units': 0, 'out': 0});
    });

    test('a renamed unit moves to the new type', () {
      final before = unit('Pocket Level #2', 'For Disposal');
      final d = ApiService.typeDelta(before, {...before, 'equipment_name': 'Pocket Type Level #7'});
      expect(d['Pocket Level'], {'units': -1, 'out': -1});
      expect(d['Pocket Type Level']!['units'], 1);
      expect(d['Pocket Type Level']!['out'], 1);
      expect(d['Pocket Type Level']!['category'], 'Measurement');
    });

    test('an edited category or program is carried to the type', () {
      final before = unit('Pantograph', 'Available');
      final d = ApiService.typeDelta(before, {...before, 'category': 'Tools', 'courses': ['CE', 'ME']});
      expect(d['Pantograph'], {'units': 0, 'out': 0, 'category': 'Tools', 'courses': ['CE', 'ME']});
    });

    test('a registration of several units adds up', () {
      final d = ApiService.mergeTypeDeltas([
        for (var i = 1; i <= 8; i++)
          ApiService.typeDelta(null, unit('Sieve #00$i', i == 8 ? 'Under Repair' : 'Available')),
      ]);
      expect(d['Sieve']!['units'], 8);
      expect(d['Sieve']!['out'], 1);
    });

    test('a staff search finds types by part of the name, or by a unit name', () {
      final types = ['Digital Multimeter', 'Clamp Multimeter', 'Pantograph'];
      expect(ApiService.typesMatching(types, 'multi'), ['Digital Multimeter', 'Clamp Multimeter']);
      expect(ApiService.typesMatching(types, 'Digital Multimeter #03'), ['Digital Multimeter']);
      expect(ApiService.typesMatching(types, ''), types);
      expect(ApiService.typesMatching(types, 'sieve'), isEmpty);
    });

    // Submit reads only the student's open records (1.0.19); the overdue
    // check must find the same loans as it did over the whole history.
    test('the checks before a request need only open records', () {
      final now = DateTime(2026, 10, 15, 12);
      Map<String, dynamic> rec(String name, String status, DateTime due,
              {bool waiting = false}) =>
          {
            'equipment_name': name,
            'status': status,
            'due_date': due.toIso8601String(),
            if (waiting) 'awaiting_pickup': true,
          };
      final history = [
        rec('Beaker 1000 mL #1', 'Returned', DateTime(2026, 9, 1, 17)),
        rec('Flask 500 mL #2', 'Rejected', DateTime(2026, 9, 2, 17)),
        rec('Monitor', 'Cancelled', DateTime(2026, 9, 3, 17)),
        rec('Keyboard', 'Approved', DateTime(2026, 10, 14, 17)),
        rec('Flask 500 mL #1', 'Approved', DateTime(2026, 10, 14, 17), waiting: true),
        rec('Pantograph', 'Pending', DateTime(2026, 10, 15, 17)),
      ];
      final open = history.where((t) => kOpenRequestStatuses.contains(t['status'])).toList();
      expect(kOpenRequestStatuses, ['Pending', 'Approved']);
      expect(open.length, 3);
      expect(ApiService.overdueLoans(open, now: now).map((t) => t['equipment_name']),
          ApiService.overdueLoans(history, now: now).map((t) => t['equipment_name']));
      expect(ApiService.overdueLoans(open, now: now).map((t) => t['equipment_name']), ['Keyboard']);
    });

    test('QR codes are told from names in the search box', () {
      for (final q in ['MEA-868984', 'too-869071', 'OTH-', '868984', ' 8689 ']) {
        expect(ApiService.looksLikeQrCode(q), isTrue, reason: q);
      }
      for (final q in ['Pantograph', 'Meter', '12', 'MEA868984', 'Sieve #001']) {
        expect(ApiService.looksLikeQrCode(q), isFalse, reason: q);
      }
    });
  });
}
