// -----------------------------------------------------------------------------
// LabTrack - the Excel report (.xlsx)
//
// Added 2026-10-06; replaces the .csv download (2026-10-05), which staff found
// confusing: one flat sheet of raw values with stored statuses like
// "Approved" that did not say whether an item was late or ever collected.
//
// 2026-10-07: the workbook holds the same report as the Full Report page and
// its PDF (the user: "make the excel report detailed the same with the pdf
// printable"), built from the same FullReport, so the numbers always match:
//   • Report: title, period and who made it; the Summary (the six Reports
//     figures); Most Borrowed Equipment; how many requests, and their items by
//     status. The first sheet reads like the first page of the PDF.
//   • Requests: one row per request, as the PDF lists them, newest first, with
//     a frozen header row and filters.
//   • Borrowing records: one row per item, with every detail (who approved,
//     handed over and received it, times, condition, notes), the stored
//     status as on the page and the PDF, and its result in plain words
//     ("Returned late", "Not picked up").
// Pure Dart apart from the shared helpers: unit-tested.
// -----------------------------------------------------------------------------

import 'dart:typed_data';

import '../constants.dart';
import 'api_service.dart';
import 'full_report.dart';
import 'xlsx.dart';

class ReportXlsx {
  static const requestColumns = [
    'Sent', 'Student', 'Student No.', 'Items', 'Number of items', 'Status',
  ];
  static const _requestWidths = <double>[22, 26, 15, 56, 16, 14];

  static const recordColumns = [
    'Requested', 'Student', 'Student No.', 'Item', 'Item code', 'Status', 'Result',
    'Return by', 'Picked up', 'Returned', 'Condition', 'Subject', 'Where',
    'Purpose', 'Approved by', 'Handed over by', 'Received by', 'Notes',
  ];
  static const _recordWidths = <double>[
    22, 26, 15, 30, 13, 12, 20, 22, 22, 22, 12, 18, 24, 34, 18, 18, 18, 36,
  ];

  // "labtrack-report-2026-10-07-last-90-days.xlsx"
  static String fileName(FullReport r) => '${r.fileStem}.xlsx';

  static Uint8List build(FullReport r) => Xlsx.build([
        reportSheet(r),
        requestsSheet(r),
        recordsSheet(r.requests, now: r.madeAt),
      ]);

  static XSheet reportSheet(FullReport r) {
    XCell t(Object? v, [int style = Xlsx.normal]) => XCell(v, style);
    final period = r.isLastDays
        ? 'Last ${r.days} days: ${formatDate(r.from)} to ${formatDate(r.to)}'
        : '${formatDate(r.from)} to ${formatDate(r.to)} (${r.periodDays} '
            '${r.periodDays == 1 ? 'day' : 'days'})';
    final rows = <List<XCell?>>[
      [t('CEA Laboratory Report', Xlsx.title)],
      [t('LabTrack, New Era University')],
      [t('Period', Xlsx.bold), t(period)],
      [t('Made', Xlsx.bold), t(r.madeAt, Xlsx.dateTime),
       if (r.madeBy.isNotEmpty) t('by ${r.madeBy}')],
      [],
      [t('Summary', Xlsx.bold)],
      [t('Figure', Xlsx.header), t('Value', Xlsx.header)],
      for (final (name, value) in r.figureValues)
        [t(name), t(value, name == FullReport.onTimeLabel ? Xlsx.percent : Xlsx.normal)],
      [t(FullReport.note, Xlsx.note)],
      [],
      [t('Most Borrowed Equipment', Xlsx.bold)],
      if (r.mostBorrowed.isEmpty)
        [t('Nothing was borrowed in this period.', Xlsx.note)]
      else ...[
        [t('Rank', Xlsx.header), t('Equipment', Xlsx.header), t('Times borrowed', Xlsx.header)],
        for (final (i, e) in r.mostBorrowed.entries.indexed) [t(i + 1), t(e.key), t(e.value)],
      ],
      [],
      [t('Requests', Xlsx.bold)],
      if (r.requests.isEmpty)
        [t('No requests in this period.', Xlsx.note)]
      else ...[
        [t(r.requestsLine)],
        [t('Status', Xlsx.header), t('Items', Xlsx.header)],
        for (final (status, n) in r.statusCounts) [t(status), t(n)],
        [t('Counted by item: a request for 3 beakers counts 3.', Xlsx.note)],
      ],
      [],
      [t('Every request is on the "Requests" sheet, newest first. Every item, with all its '
          'details, is on the "Borrowing records" sheet.', Xlsx.note)],
    ];
    return XSheet('Report', rows, widths: const [30, 44, 18]);
  }

  // One row per request, as the PDF lists them.
  static XSheet requestsSheet(FullReport r) => XSheet(
        'Requests',
        [
          [for (final c in requestColumns) XCell(c, Xlsx.header)],
          for (final day in r.requestDays)
            for (final l in day.lines)
              [
                l.sent == null ? null : XCell(l.sent, Xlsx.dateTime),
                XCell(l.student),
                l.number.isEmpty ? null : XCell(l.number),
                XCell(l.items),
                XCell(l.count),
                XCell(l.status, Xlsx.bold),
              ],
        ],
        widths: _requestWidths,
        tableHeader: true,
      );

  static XSheet recordsSheet(List<dynamic> txns, {DateTime? now}) {
    XCell? date(dynamic v) {
      final d = ApiService.asDate(v);
      return d == null ? null : XCell(d, Xlsx.dateTime);
    }
    XCell? text(dynamic v, [int style = Xlsx.normal]) {
      final s = '${v ?? ''}'.trim();
      return s.isEmpty ? null : XCell(s, style);
    }
    String notes(dynamic t) => [
          if ('${t['reject_reason'] ?? ''}'.trim().isNotEmpty) 'Reason: ${t['reject_reason']}',
          if ('${t['cancel_reason'] ?? ''}'.trim().isNotEmpty &&
              t['cancel_reason'] != 'Not picked up')
            'Reason: ${t['cancel_reason']}',
          if ('${t['cancelled_by_name'] ?? ''}'.trim().isNotEmpty)
            'Cancelled by ${t['cancelled_by_name']}',
          if ('${t['due_set_by_name'] ?? ''}'.trim().isNotEmpty)
            'Return time set by ${t['due_set_by_name']}',
        ].join('; ');

    return XSheet(
      'Borrowing records',
      [
        [for (final c in recordColumns) XCell(c, Xlsx.header)],
        for (final t in txns)
          [
            date(t['borrow_date']),
            text(t['borrower_name']),
            text(t['student_number']),
            text(t['equipment_name']),
            text(t['qr_code']),
            text(t['status'], Xlsx.bold),
            XCell(ApiService.loanOutcome(t, now: now)),
            date(t['due_date']),
            date(t['picked_up_at']),
            date(t['return_date']),
            text(t['condition_returned']),
            text(t['subject']),
            text(t['use_location']),
            text(t['purpose']),
            text(t['approved_by_name']),
            text(t['picked_up_by_name']),
            text(t['returned_by_name']),
            text(notes(t)),
          ],
      ],
      widths: _recordWidths,
      tableHeader: true,
    );
  }
}
