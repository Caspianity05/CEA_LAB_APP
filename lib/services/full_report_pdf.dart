// -----------------------------------------------------------------------------
// LabTrack - the Full Report as a PDF to print
//
// Added 2026-10-07 at the user's request (the lab staff want the information
// easy to reach, and a printed copy is the easiest for them). The same content
// in the same order as the Full Report page (full_report.dart): title, period
// and who made it; Summary; Most Borrowed Equipment; the requests, one line
// each under a heading per day, all of them. A4, with the page number and the
// report's date at the foot of every page. A day that runs onto the next page
// has its name and the column titles again at the top of it, and a day's name
// never sits alone at the foot of a page (checked on the first printout, where
// "Aug 4, 2026" ended page 2 and its request began page 3). The PDF's built-in
// font covers Latin-1 only, hence QrLabels.pdfSafe.
// Pure Dart, so it runs in the browser and is unit-tested.
// -----------------------------------------------------------------------------

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'full_report.dart';
import 'qr_labels.dart' show QrLabels;

class FullReportPdf {
  // "labtrack-report-2026-10-07-last-90-days.pdf"
  static String fileName(FullReport r) => '${r.fileStem}.pdf';

  static const _blue = PdfColor.fromInt(0xFF1B3A8C);
  static const _mid = PdfColor.fromInt(0xFF5A6A8A);
  static const _rule = PdfColor.fromInt(0xFFDDE4F0);
  static const _band = PdfColor.fromInt(0xFFF0F3FA);

  // As on the Reports tab (reportStatusColor).
  static PdfColor _statusColor(String status) => switch (status) {
        'Approved' => const PdfColor.fromInt(0xFF27AE60),
        'Pending' => const PdfColor.fromInt(0xFFF5A623),
        'Returned' => _mid,
        'Cancelled' => const PdfColor.fromInt(0xFF9AAAC8),
        _ => const PdfColor.fromInt(0xFFE74C3C),
      };

  static String _t(String s) => QrLabels.pdfSafe(s);

  static Future<Uint8List> build(FullReport r) {
    final doc = pw.Document(title: 'LabTrack: CEA Laboratory Report', author: 'LabTrack');
    const body = pw.TextStyle(fontSize: 11);
    const quiet = pw.TextStyle(fontSize: 9, color: _mid);

    pw.Widget heading(String text) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 16, bottom: 6),
          child: pw.Text(_t(text),
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        );

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 32),
      footer: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 8),
        child: pw.Row(children: [
          pw.Expanded(
            child: pw.Text(_t('LabTrack · CEA Laboratory Report · ${r.madeLine}'),
                style: quiet),
          ),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: quiet),
        ]),
      ),
      build: (ctx) => [
        // ── What this is, when it was made, what it covers ──
        pw.Text(_t('CEA Laboratory Report'),
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text(_t('LabTrack · New Era University'),
            style: const pw.TextStyle(fontSize: 11, color: _mid)),
        pw.SizedBox(height: 8),
        pw.Text(_t(r.periodLine), style: body),
        pw.Text(_t(r.madeLine), style: body),

        // ── The six figures ──
        heading('Summary'),
        _table(
          widths: const [3, 1],
          rows: [
            for (final (name, value) in r.figures)
              [_cell(name), _cell(value, bold: true, right: true)],
          ],
        ),
        pw.SizedBox(height: 4),
        pw.Text(_t(FullReport.note), style: quiet),

        // ── Most borrowed ──
        heading('Most Borrowed Equipment'),
        if (r.mostBorrowed.isEmpty)
          pw.Text('Nothing was borrowed in this period.', style: body)
        else
          _table(
            widths: const [0.4, 4, 1.3],
            rows: [
              for (final (i, e) in r.mostBorrowed.entries.indexed)
                [
                  _cell('${i + 1}.', bold: true),
                  _cell(e.key),
                  _cell('${e.value} ${e.value == 1 ? 'time' : 'times'}', bold: true, right: true),
                ],
            ],
          ),

        // ── The requests, all of them ──
        heading('Requests'),
        if (r.requests.isEmpty)
          pw.Text('No requests in this period.', style: body)
        else ...[
          pw.Text(_t(r.requestsLine),
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 2),
          pw.Text(
              _t('Items by status: '
                  '${r.statusCounts.map((e) => '${e.$1} ${e.$2}').join(', ')}'),
              style: body),
          pw.Text('Newest first. Counted by item: a request for 3 beakers counts 3.',
              style: quiet),
          for (final day in r.requestDays) ...[
            // A new page, unless the day's name, the column titles and its
            // first request (even one long enough for four lines) fit here.
            pw.NewPage(freeSpace: 110),
            _dayTable(day),
          ],
        ],
      ],
    ));
    return doc.save();
  }

  static pw.Widget _cell(String text,
          {bool bold = false, bool right = false, PdfColor? color}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: pw.Text(_t(text),
            textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(
                fontSize: 10,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                color: color)),
      );

  // A plain table with light rules between its rows.
  static pw.Widget _table(
          {required List<double> widths, required List<List<pw.Widget>> rows}) =>
      pw.Table(
        columnWidths: {
          for (final (i, w) in widths.indexed) i: pw.FlexColumnWidth(w),
        },
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(color: _rule, width: 0.5),
          bottom: pw.BorderSide(color: _rule, width: 0.5),
          top: pw.BorderSide(color: _rule, width: 0.5),
        ),
        tableWidth: pw.TableWidth.max,
        children: [for (final row in rows) pw.TableRow(children: row)],
      );

  // How the width of a day's table is shared: Time, Student, Items, Status.
  static const _dayFlex = [9, 18, 36, 11];

  // One day's requests. The table has a single column, so its first row can
  // hold the day's name above the column titles, and that row is repeated at
  // the top of every page the day runs onto.
  static pw.Widget _dayTable(RequestDay day) {
    pw.Widget line(List<pw.Widget> cells) => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            for (final (i, cell) in cells.indexed)
              pw.Expanded(flex: _dayFlex[i], child: cell),
          ],
        );
    return pw.Table(
      columnWidths: const {0: pw.FlexColumnWidth()},
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _rule, width: 0.5),
        bottom: pw.BorderSide(color: _rule, width: 0.5),
      ),
      tableWidth: pw.TableWidth.max,
      children: [
        pw.TableRow(repeat: true, children: [
          pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 12, bottom: 4),
                child: pw.Text(_t(day.label),
                    style: pw.TextStyle(
                        fontSize: 12, fontWeight: pw.FontWeight.bold, color: _blue)),
              ),
              pw.Container(
                decoration: const pw.BoxDecoration(
                  color: _band,
                  border: pw.Border(top: pw.BorderSide(color: _rule, width: 0.5)),
                ),
                child: line([
                  _cell('Time', bold: true),
                  _cell('Student', bold: true),
                  _cell('Items', bold: true),
                  _cell('Status', bold: true),
                ]),
              ),
            ],
          ),
        ]),
        for (final l in day.lines)
          pw.TableRow(children: [
            line([
              _cell(l.time),
              _cell(l.student),
              _cell(l.items),
              _cell(l.status, bold: true, color: _statusColor(l.status)),
            ]),
          ]),
      ],
    );
  }
}
