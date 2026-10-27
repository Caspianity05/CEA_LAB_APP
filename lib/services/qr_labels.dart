// -----------------------------------------------------------------------------
// LabTrack - printable QR labels (PDF)
//
// Added 2026-10-06 (usability update). The web portal's Inventory makes a PDF
// of A4 sheets, 3 × 7 labels each: the item's QR code (the same code its page
// shows and Scan QR reads), its name and its code, with a thin cutting line.
// Print at 100% ("Actual size"), cut, and stick one on each unit. Pure Dart,
// so it runs in the browser and is unit-tested.
// -----------------------------------------------------------------------------

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class QrLabels {
  static const columns = 3, rows = 7;
  static const perPage = columns * rows;

  // Pages needed for [count] labels.
  static int pages(int count) => (count + perPage - 1) ~/ perPage;

  // The PDF's built-in Helvetica covers Latin-1 only, so typographic dashes
  // and quotes become plain ones and anything else outside it a '?'.
  static String pdfSafe(String s) => s
      .replaceAll(RegExp('[–—−]'), '-')
      .replaceAll(RegExp('[‘’]'), "'")
      .replaceAll(RegExp('[“”]'), '"')
      .replaceAll('…', '...')
      .replaceAll(RegExp('[^\u0000-ÿ]'), '?');

  // The items that get a label: those with a QR code. Inventory counts and
  // names the rest from this too; its dialog used to promise a label for
  // every item (90 for an 89-label PDF, live test 2026-10-07).
  static List<Map<String, dynamic>> withCode(List<Map<String, dynamic>> items) => [
        for (final e in items)
          if ('${e['qr_code'] ?? ''}'.trim().isNotEmpty) e,
      ];

  // [items]: equipment records with equipment_name and qr_code. Those
  // without a code are left out.
  static Future<Uint8List> build(List<Map<String, dynamic>> items,
      {String footer = 'CEA Laboratory, NEU'}) {
    final labels = withCode(items);
    final doc = pw.Document(title: 'LabTrack QR labels', author: 'LabTrack');
    for (var start = 0; start < labels.length; start += perPage) {
      final page = labels.skip(start).take(perPage).toList();
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(8 * PdfPageFormat.mm),
        build: (_) => pw.Column(children: [
          for (var r = 0; r < rows; r++)
            pw.Expanded(
              child: pw.Row(children: [
                for (var c = 0; c < columns; c++)
                  pw.Expanded(
                    child: r * columns + c < page.length
                        ? _label(page[r * columns + c], footer)
                        : pw.SizedBox(),
                  ),
              ]),
            ),
        ]),
      ));
    }
    return doc.save();
  }

  static pw.Widget _label(Map<String, dynamic> e, String footer) {
    final code = '${e['qr_code']}'.trim();
    return pw.Container(
      margin: const pw.EdgeInsets.all(1.5 * PdfPageFormat.mm),
      padding: const pw.EdgeInsets.all(2.5 * PdfPageFormat.mm),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Row(children: [
        pw.BarcodeWidget(
          barcode: pw.Barcode.qrCode(),
          drawText: false,
          data: code,
          width: 26 * PdfPageFormat.mm,
          height: 26 * PdfPageFormat.mm,
        ),
        pw.SizedBox(width: 2.5 * PdfPageFormat.mm),
        pw.Expanded(
          child: pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(pdfSafe('${e['equipment_name'] ?? ''}'),
                  maxLines: 3,
                  style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 3),
              pw.Text(pdfSafe(code), style: const pw.TextStyle(fontSize: 9)),
              pw.SizedBox(height: 3),
              pw.Text(pdfSafe(footer),
                  style: const pw.TextStyle(fontSize: 6, color: PdfColors.grey700)),
            ],
          ),
        ),
      ]),
    );
  }
}
