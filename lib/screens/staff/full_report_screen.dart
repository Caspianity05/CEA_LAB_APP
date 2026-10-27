// -----------------------------------------------------------------------------
// LabTrack - staff: the full report, as a page anyone can read
//
// Added 2026-10-07 at the user's request: "Export Full Report" showed a
// terminal-style block (green monospaced text on black, "=====" lines,
// "[Approved] name | item | date"), and the lab staff, who are not used to
// computers, found it confusing. This page shows the same report as a
// document: large ordinary text, headed sections, the Reports tab's figure
// names, dates written out, coloured statuses, and a Copy Report button that
// is always in view. The content and its text form are in full_report.dart.
//
// Requests: one line per request under a heading per day, after a count by
// status, and only the 10 newest until "Show all" (the list of every item was
// too long to read, the user said).
//
// Later the same day (the user: easy access to the information staff need):
// "Change dates" makes the report for any period, and on the web portal the
// page downloads it as an Excel workbook (report_xlsx.dart) or as a PDF to
// print (full_report_pdf.dart), both with the same content as the page.
// -----------------------------------------------------------------------------

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/file_download.dart';
import '../../services/full_report.dart';
import '../../services/full_report_pdf.dart';
import '../../services/report_xlsx.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// The colour of a stored status, as on the Reports tab's Recent Transactions.
Color reportStatusColor(String status) => switch (status) {
      'Approved' => AppTheme.success,
      'Pending' => AppTheme.accent,
      'Returned' => AppTheme.textMid,
      'Cancelled' => AppTheme.textLight,
      _ => AppTheme.danger,
    };

const _quiet = TextStyle(fontSize: 14, color: AppTheme.textMid);

Widget _card(Widget child) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: child,
    );

// Makes the report for the dates staff chose (whole days, both included).
typedef ReportLoader = Future<FullReport> Function(DateTime start, DateTime end);

class FullReportScreen extends StatefulWidget {
  final FullReport report;
  // "Change dates"; hidden when null.
  final ReportLoader? loadPeriod;
  // Download Excel / Download PDF: the web portal only, since the phone app
  // cannot save files.
  final bool showDownloads;
  const FullReportScreen(
      {super.key, required this.report, this.loadPeriod, this.showDownloads = kIsWeb});

  @override
  State<FullReportScreen> createState() => _FullReportScreenState();
}

class _FullReportScreenState extends State<FullReportScreen> {
  late FullReport _report = widget.report;
  bool _loadingPeriod = false;
  bool _makingPdf = false;
  // "Show all" requests. Kept here, by the page: the list drops sections that
  // scroll far out of view, and a section keeping it itself was collapsed
  // again after scrolling back up (found on the phone, 2026-10-07).
  bool _allRequests = false;

  FullReport get report => _report;

  void _say(String text, {bool ok = true}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: ok ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: report.asText()));
    messenger.showSnackBar(const SnackBar(
      content: Text('Report copied. You can now paste it into an email, Notes or Word.'),
      backgroundColor: AppTheme.success,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _changeDates() async {
    final load = widget.loadPeriod;
    if (load == null || _loadingPeriod) return;
    final today = DateTime.now();
    DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2025, 1, 1),
      lastDate: day(today),
      initialDateRange: DateTimeRange(start: day(report.from), end: day(report.to)),
      helpText: 'CHOOSE THE DATES FOR THE REPORT',
      saveText: 'Make Report',
      confirmText: 'Make Report',
    );
    if (picked == null || !mounted) return;
    setState(() => _loadingPeriod = true);
    try {
      final next = await load(picked.start, picked.end);
      if (!mounted) return;
      setState(() {
        _report = next;
        _allRequests = false;
        _loadingPeriod = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingPeriod = false);
      _say('Could not make the report for those dates. Check the connection and try again.',
          ok: false);
    }
  }

  void _downloadExcel() {
    final ok = downloadBytes(ReportXlsx.fileName(report), ReportXlsx.build(report),
        mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    _say(ok
        ? 'Downloaded the Excel report (${ReportXlsx.fileName(report)}).'
        : 'Downloads work in the web portal.',
        ok: ok);
  }

  Future<void> _downloadPdf() async {
    setState(() => _makingPdf = true);
    try {
      final bytes = await FullReportPdf.build(report);
      if (!mounted) return;
      final ok = downloadBytes(FullReportPdf.fileName(report), bytes,
          mimeType: 'application/pdf');
      _say(ok
          ? 'Downloaded the PDF. Open it and print it (Ctrl+P).'
          : 'Downloads work in the web portal.',
          ok: ok);
    } finally {
      if (mounted) setState(() => _makingPdf = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = report;
    const label = TextStyle(fontSize: 16, color: AppTheme.textDark);
    final busy = _loadingPeriod || _makingPdf;

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(title: const Text('Full Report')),
      body: ListView(
        padding: readablePadding(context, const EdgeInsets.fromLTRB(16, 16, 16, 24),
            maxWidth: 720),
        children: [
          // ── What this is, when it was made, what it covers ──
          _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('CEA Laboratory Report',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
            const SizedBox(height: 4),
            const Text('LabTrack · New Era University', style: _quiet),
            const SizedBox(height: 14),
            _line(Icons.date_range_rounded, r.periodLine),
            const SizedBox(height: 8),
            _line(Icons.schedule_rounded, r.madeLine),
            if (widget.loadPeriod != null) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : _changeDates,
                  icon: _loadingPeriod
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.edit_calendar_rounded),
                  label: Text(_loadingPeriod ? 'Making the report…' : 'Change dates',
                      style: const TextStyle(fontSize: 16)),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
            ],
          ])),
          const SizedBox(height: 24),

          // ── The six figures ──
          const _Heading('Summary'),
          _card(Column(children: [
            for (final (i, (name, value)) in r.figures.indexed) ...[
              if (i > 0) const Divider(height: 24, color: AppTheme.divider),
              Row(children: [
                Expanded(child: Text(name, style: label)),
                Text(value,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.primary)),
              ]),
            ],
          ])),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(FullReport.note, style: _quiet),
          ),
          const SizedBox(height: 24),

          // ── Most borrowed ──
          const _Heading('Most Borrowed Equipment'),
          _card(r.mostBorrowed.isEmpty
              ? const Text('Nothing was borrowed in this period.', style: _quiet)
              : Column(children: [
                  for (final (i, e) in r.mostBorrowed.entries.indexed) ...[
                    if (i > 0) const Divider(height: 24, color: AppTheme.divider),
                    Row(children: [
                      SizedBox(
                        width: 28,
                        child: Text('${i + 1}.',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold,
                                color: AppTheme.accent)),
                      ),
                      Expanded(child: Text(e.key, style: label)),
                      Text('${e.value} ${e.value == 1 ? 'time' : 'times'}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold,
                              color: AppTheme.textDark)),
                    ]),
                  ],
                ])),
          const SizedBox(height: 24),

          // ── The requests ──
          _RequestsSection(
            report: r,
            showAll: _allRequests,
            onShowAll: () => setState(() => _allRequests = true),
          ),
        ],
      ),
      // The actions stay in view however long the report is. On the web, the
      // two downloads above Close and Copy Report.
      bottomNavigationBar: SafeArea(
        child: Container(
          color: Colors.white,
          padding: readablePadding(context, const EdgeInsets.fromLTRB(16, 10, 16, 10),
              maxWidth: 720),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (widget.showDownloads) ...[
              Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: busy ? null : _downloadExcel,
                    icon: const Icon(Icons.table_view_rounded),
                    label: const _ButtonText('Download Excel'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.success,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: busy ? null : _downloadPdf,
                    icon: _makingPdf
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.print_rounded),
                    label: const _ButtonText('Download PDF to print'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.danger,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
            ],
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: const _ButtonText('Close'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: busy ? null : () => _copy(context),
                  icon: const Icon(Icons.copy_rounded),
                  label: const _ButtonText('Copy Report'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  static Widget _line(IconData icon, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppTheme.primary),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: const TextStyle(fontSize: 15, color: AppTheme.textDark))),
        ],
      );
}

// A button label that shrinks rather than overflows on a narrow phone with
// large text.
class _ButtonText extends StatelessWidget {
  final String text;
  const _ButtonText(this.text);

  @override
  Widget build(BuildContext context) => FittedBox(
      fit: BoxFit.scaleDown, child: Text(text, style: const TextStyle(fontSize: 16)));
}

// The period's requests: how many, how their items ended, then one line per
// request under a heading per day. Only the newest [_first] lines until
// "Show all" ([showAll], kept by the page), so the page stays short.
class _RequestsSection extends StatelessWidget {
  final FullReport report;
  final bool showAll;
  final VoidCallback onShowAll;
  const _RequestsSection(
      {required this.report, required this.showAll, required this.onShowAll});

  static const _first = 10;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final days = r.requestDays;
    final total = days.fold<int>(0, (n, d) => n + d.lines.length);

    // The days and lines to show now: everything, or the newest _first lines.
    final shown = <RequestDay>[];
    var left = showAll ? total : _first;
    for (final d in days) {
      if (left <= 0) break;
      final lines = d.lines.take(left).toList();
      shown.add((label: d.label, lines: lines));
      left -= lines.length;
    }
    final hidden = total - shown.fold<int>(0, (n, d) => n + d.lines.length);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Heading('Requests', note: 'Newest first'),
      if (r.requests.isEmpty)
        _card(const Text('No requests in this period.', style: _quiet))
      else ...[
        // ── How many, and how their items ended ──
        _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.requestsLine,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (status, n) in r.statusCounts)
              StatusBadge(label: '$status: $n', color: reportStatusColor(status)),
          ]),
          const SizedBox(height: 8),
          const Text('Counted by item: a request for 3 beakers counts 3.', style: _quiet),
        ])),

        // ── One line per request, a heading per day ──
        for (final day in shown) ...[
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(day.label,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.primary)),
          ),
          _card(Column(children: [
            for (final (i, line) in day.lines.indexed) ...[
              if (i > 0) const Divider(height: 24, color: AppTheme.divider),
              _requestLine(line),
            ],
          ])),
        ],

        if (hidden > 0) ...[
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onShowAll,
              icon: const Icon(Icons.expand_more_rounded),
              // Counts lines, not requests: a request whose items ended
              // differently has a line per status.
              label: Text('Show all ($hidden more)', style: const TextStyle(fontSize: 16)),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ),
        ],
      ],
    ]);
  }

  // Name and status, then the items across the full width (a time column
  // squeezed them onto two lines on a phone), then the time.
  Widget _requestLine(RequestLine line) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(line.student,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
          ),
          const SizedBox(width: 10),
          StatusBadge(label: line.status, color: reportStatusColor(line.status)),
        ]),
        const SizedBox(height: 2),
        Text(line.items, style: const TextStyle(fontSize: 15, color: AppTheme.textDark)),
        if (line.time.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(line.time, style: _quiet),
        ],
      ]);
}

class _Heading extends StatelessWidget {
  final String text;
  final String? note;
  const _Heading(this.text, {this.note});

  // A Wrap, not a Row: with large system text (older staff often set it) a
  // heading and its note go onto two lines instead of running off the screen.
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            Text(text,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
            if (note != null) Text(note!, style: _quiet),
          ],
        ),
      );
}
