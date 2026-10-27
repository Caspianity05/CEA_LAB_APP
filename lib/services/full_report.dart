// -----------------------------------------------------------------------------
// LabTrack - the "Export Full Report" content
//
// Added 2026-10-07 at the user's request. The report used to be a block of
// green-on-black text with "=====" lines and "[Approved] name | item | date"
// rows: it looked like a computer terminal, and the lab staff, who are not
// used to computers, found it confusing. Now it is a plain page
// (full_report_screen.dart), and the text Copy Report puts on the clipboard
// reads like a short document: headings, "Label: value" lines, dates written
// out. The figures are the Reports tab's, under the names its cards use.
//
// The requests were one row per item (an 8-item request was 8 rows), which
// made a long list ("too many", the user). They are one line per request now
// (per request and status, if its items ended differently), under a heading
// per day, after a count of the items by status.
//
// 2026-10-07, later: staff can choose the dates (start/end), and this one
// model feeds every form of the report, so the numbers always match: the page,
// the copied text, the PDF to print (full_report_pdf.dart) and the Excel
// workbook (report_xlsx.dart).
// Pure Dart, so it is unit-tested.
// -----------------------------------------------------------------------------

import '../constants.dart';
import 'api_service.dart';

// One request in the list. [items] reads "Beaker 1000 mL #1" for one unit and
// "Beaker 1000 mL × 2, Flask 500 mL" for more; [count] is its number of items;
// [sent] (when it was sent) and [number] (student number) are for the Excel
// report's Requests sheet.
typedef RequestLine = ({
  String time,
  String student,
  String items,
  String status,
  int count,
  DateTime? sent,
  String number,
});

// The requests sent on one day, under a heading such as "Today, Oct 7, 2026".
typedef RequestDay = ({String label, List<RequestLine> lines});

class FullReport {
  final DateTime madeAt;
  final String madeBy;
  // The period: the last [days] days up to madeAt, or (2026-10-07) dates staff
  // chose, [start] to [end], whole days, both included.
  final int days;
  final DateTime? start, end;
  final int totalBorrowings, totalReturned, totalOverdue, totalDamage, totalEquipment;
  final double onTimeRate; // percent, 0–100
  final Map<String, int> mostBorrowed; // item type → times borrowed
  final List<dynamic> requests; // the period's records (one per item), newest first

  const FullReport({
    required this.madeAt,
    this.madeBy = '',
    this.days = 90,
    this.start,
    this.end,
    required this.totalBorrowings,
    required this.totalReturned,
    required this.totalOverdue,
    required this.totalDamage,
    required this.totalEquipment,
    required this.onTimeRate,
    this.mostBorrowed = const {},
    this.requests = const [],
  });

  bool get isLastDays => start == null;
  DateTime get from => start ?? madeAt.subtract(Duration(days: days));
  DateTime get to => end ?? madeAt;

  // How many calendar days the period spans, both ends included.
  int get periodDays =>
      DateTime(to.year, to.month, to.day)
          .difference(DateTime(from.year, from.month, from.day))
          .inDays +
      1;

  // "labtrack-report-2026-10-07-last-90-days" or
  // "labtrack-report-2026-08-01-to-2026-10-07", for the downloads.
  String get fileStem {
    String iso(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return isLastDays
        ? 'labtrack-report-${iso(to)}-last-$days-days'
        : 'labtrack-report-${iso(from)}-to-${iso(to)}';
  }

  // The six figures, in the order and under the names of the Reports cards.
  // As numbers for the Excel report (On-Time Returns as a fraction, shown as
  // a percentage there), and as text for the page, the PDF and the copy.
  static const onTimeLabel = 'On-Time Returns';
  List<(String, num)> get figureValues => [
        ('Total Borrowings', totalBorrowings),
        (onTimeLabel, onTimeRate / 100),
        ('Overdue Items', totalOverdue),
        ('Damage Reports', totalDamage),
        ('Total Equipment', totalEquipment),
        ('Returned Successfully', totalReturned),
      ];
  List<(String, String)> get figures => [
        for (final (name, value) in figureValues)
          (name, name == onTimeLabel ? '${(value * 100).toStringAsFixed(0)}%' : '$value'),
      ];

  static const note = 'Borrowing numbers cover the period above. Overdue items, '
      'equipment and damage reports are counted as of today.';

  // "2:45 PM"
  static String clock(DateTime d) {
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '$hour:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  // "Oct 7, 2026 at 2:45 PM"
  static String when(DateTime d) => '${formatDate(d)} at ${clock(d)}';

  String get madeLine => 'Made on ${when(madeAt)}${madeBy.isEmpty ? '' : ' by $madeBy'}';

  String get periodLine => isLastDays
      ? 'Covers the last $days days: ${formatDate(from)} to ${formatDate(to)}'
      : 'Covers ${formatDate(from)} to ${formatDate(to)} '
          '($periodDays ${periodDays == 1 ? 'day' : 'days'})';

  // "Today, Oct 7, 2026", "Yesterday, Oct 6, 2026", "Oct 5, 2026"
  String dayLabel(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    final today = DateTime(madeAt.year, madeAt.month, madeAt.day);
    final ago = today.difference(day).inDays;
    return ago == 0
        ? 'Today, ${formatDate(day)}'
        : ago == 1
            ? 'Yesterday, ${formatDate(day)}'
            : formatDate(day);
  }

  // How many requests the period had (an 8-item request is one).
  int get requestCount => ApiService.groupRequests(requests).length;

  // How many items ended in each status, in a fixed order so every report
  // reads the same way: out or waiting first, then the finished ones.
  static const _statusOrder = ['Approved', 'Pending', 'Returned', 'Cancelled', 'Rejected'];
  List<(String, int)> get statusCounts {
    final counts = <String, int>{};
    for (final t in requests) {
      final s = '${t['status'] ?? ''}';
      counts[s] = (counts[s] ?? 0) + 1;
    }
    int rank(String s) {
      final i = _statusOrder.indexOf(s);
      return i < 0 ? _statusOrder.length : i;
    }
    final names = counts.keys.toList()
      ..sort((a, b) => rank(a) != rank(b) ? rank(a) - rank(b) : a.compareTo(b));
    return [for (final s in names) (s, counts[s]!)];
  }

  // The requests, one line each (one per status if its items ended
  // differently, as in the student's History), under a heading per day,
  // newest first.
  List<RequestDay> get requestDays {
    final byDay = <String, List<RequestLine>>{};
    for (final group in ApiService.groupRequests(requests, byStatus: true)) {
      final first = group.first;
      final asked = ApiService.asDate(first['borrow_date']);
      byDay.putIfAbsent(asked == null ? 'Date not recorded' : dayLabel(asked), () => []).add((
        time: asked == null ? '' : clock(asked),
        student: '${first['borrower_name'] ?? first['student_number'] ?? '—'}',
        items: group.length == 1
            ? '${first['equipment_name'] ?? '—'}'
            : ApiService.requestSummary(group),
        status: '${first['status'] ?? ''}',
        count: group.length,
        sent: asked,
        number: '${first['student_number'] ?? ''}',
      ));
    }
    return [for (final e in byDay.entries) (label: e.key, lines: e.value)];
  }

  // "32 requests for 57 items"
  String get requestsLine {
    final n = requestCount, items = requests.length;
    return '$n ${n == 1 ? 'request' : 'requests'} for $items ${items == 1 ? 'item' : 'items'}';
  }

  // What Copy Report puts on the clipboard, for an email, Notes or Word.
  String asText() {
    final b = StringBuffer()
      ..writeln('CEA LABORATORY REPORT')
      ..writeln('LabTrack, New Era University')
      ..writeln(madeLine)
      ..writeln(periodLine)
      ..writeln()
      ..writeln('SUMMARY');
    for (final (label, value) in figures) {
      b.writeln('$label: $value');
    }
    b
      ..writeln(note)
      ..writeln()
      ..writeln('MOST BORROWED EQUIPMENT');
    if (mostBorrowed.isEmpty) b.writeln('Nothing was borrowed in this period.');
    var rank = 1;
    mostBorrowed.forEach((name, n) =>
        b.writeln('${rank++}. $name: borrowed $n ${n == 1 ? 'time' : 'times'}'));
    b
      ..writeln()
      ..writeln('REQUESTS (newest first)');
    if (requests.isEmpty) {
      b.writeln('No requests in this period.');
    } else {
      b
        ..writeln(requestsLine)
        ..writeln('Items by status: '
            '${statusCounts.map((e) => '${e.$1} ${e.$2}').join(', ')}');
    }
    for (final day in requestDays) {
      b
        ..writeln()
        ..writeln(day.label);
      for (final l in day.lines) {
        b.writeln(joinParts([l.time, l.student, l.items, l.status], separator: ' - '));
      }
    }
    return b.toString();
  }
}
