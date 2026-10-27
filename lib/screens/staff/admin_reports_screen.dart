// -----------------------------------------------------------------------------
// LabTrack - staff: admin reports screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
//
// 2026-10-07: back to the 1.0.16 page, as the user asked: the 1.0.17 redesign
// (period picker, "At a glance", explained figures, Copy Summary) was more
// than they wanted. Only the download changed: the web portal's "Download
// Excel Report (.xlsx)" saves the workbook from report_xlsx.dart (Summary +
// Borrowing records) instead of the old .csv. Kept from 1.0.17 because they
// are fixes, not looks: no second title bar under the staff header (the
// refresh button sits on the period line instead), Overdue Items counts every
// loan still out as the Dashboard does (not only those sent in the last 90
// days), a message instead of zeros when loading fails, and Most Borrowed by
// item type (ApiService.reportMetrics).
//
// 2026-10-07, later: "Export Full Report" opens the report as a readable page
// (full_report_screen.dart) instead of a green-on-black, terminal-style text
// dialog, which the lab staff found confusing. Copy Report is on that page,
// and (later still) "Change dates" for any period and, on the web portal,
// Download Excel and Download PDF to print. Every form comes from one
// FullReport, so this page's Excel button saves the same workbook for its
// 90 days.
// -----------------------------------------------------------------------------


import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/file_download.dart';
import '../../services/full_report.dart';
import '../../services/report_xlsx.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'full_report_screen.dart';

// ─── Admin Reports Screen ──────────────────────────────────────────────────────

class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});
  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  bool _loading = true;
  bool _failed = false;

  // Reporting window. Borrowing figures below cover this many days back, not
  // all time — see the note in _load(). Surfaced in the UI and the exported
  // report so the numbers are never read as lifetime totals.
  static const int _reportPeriodDays = 90;

  // Live stats
  int _totalBorrowings   = 0;
  int _totalReturned     = 0;
  int _totalOverdue      = 0;
  int _totalDamage       = 0;
  int _totalEquipment    = 0;
  double _onTimeRate     = 0;

  // Most borrowed equipment map: name → count
  Map<String, int> _mostBorrowed = {};

  // Recent transactions for export
  List<dynamic> _allTransactions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      // Scoped to a reporting period rather than all-time: borrow_transactions
      // grows forever, so an unbounded read here gets more expensive every
      // semester. Equipment and damage totals are counted server-side. All
      // start before any is awaited, so they run concurrently.
      final now     = DateTime.now();
      final cutoff  = now.subtract(const Duration(days: _reportPeriodDays));
      final txF     = ApiService.getRequestsSince(cutoff);
      final openF   = ApiService.getOpenRequests();
      final eqF     = ApiService.getEquipmentStatusCounts();
      final damageF = ApiService.damageReportCount();
      final txSnap        = await txF;
      final open          = await openF;
      final equipment     = await eqF;
      final damageReports = await damageF;

      // Borrowing stats. The counting rules live in ApiService.reportMetrics so
      // they are unit-tested rather than done by hand here — the hand-rolled
      // version counted Pending and Rejected requests as borrowings and worked
      // out "on time" without ever looking at a return date (QA 2026-09-19, M2).
      final m = ApiService.reportMetrics(txSnap, now: now);

      if (!mounted) return;
      setState(() {
        _totalBorrowings  = m['borrowings'] as int;
        _totalReturned    = m['returned'] as int;
        // Every loan still out past its time, whenever it was sent, as on the
        // Dashboard: one sent before the period used to be left out.
        _totalOverdue     = ApiService.overdueLoans(open, now: now).length;
        _totalDamage      = damageReports;
        _totalEquipment   = equipment['Total'] ?? 0;
        _onTimeRate       = m['onTimeRate'] as double;
        _mostBorrowed     = m['mostBorrowed'] as Map<String, int>;
        _allTransactions  = txSnap;
        _loading          = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  // ── The full report, as a page anyone can read ───────────────────────────
  // 2026-10-07: it used to be a terminal-style text dialog (green on black,
  // "=====" lines, "[Approved] name | item | date"). The page and the text
  // Copy Report gives are in full_report_screen.dart and full_report.dart.
  // This page's 90 days as a report: what Export Full Report opens and what
  // Download Excel Report saves.
  FullReport _fullReport() => FullReport(
        madeAt:          DateTime.now(),
        madeBy:          Session.name,
        days:            _reportPeriodDays,
        totalBorrowings: _totalBorrowings,
        totalReturned:   _totalReturned,
        totalOverdue:    _totalOverdue,
        totalDamage:     _totalDamage,
        totalEquipment:  _totalEquipment,
        onTimeRate:      _onTimeRate,
        mostBorrowed:    _mostBorrowed,
        requests:        _allTransactions,
      );

  // The report for dates staff chose on the Full Report page ("Change dates",
  // 2026-10-07). Worked out like this page's 90 days; overdue items,
  // equipment and damage reports are counted as of today, as here.
  Future<FullReport> _reportFor(DateTime start, DateTime end) async {
    final now   = DateTime.now();
    final from  = DateTime(start.year, start.month, start.day);
    final until = DateTime(end.year, end.month, end.day).add(const Duration(days: 1));
    final txF     = ApiService.getRequestsBetween(from, until);
    final openF   = ApiService.getOpenRequests();
    final eqF     = ApiService.getEquipmentStatusCounts();
    final damageF = ApiService.damageReportCount();
    final txns      = await txF;
    final open      = await openF;
    final equipment = await eqF;
    final damage    = await damageF;
    final m = ApiService.reportMetrics(txns, now: now);
    return FullReport(
      madeAt:          now,
      madeBy:          Session.name,
      start:           from,
      end:             DateTime(end.year, end.month, end.day),
      totalBorrowings: m['borrowings'] as int,
      totalReturned:   m['returned'] as int,
      totalOverdue:    ApiService.overdueLoans(open, now: now).length,
      totalDamage:     damage,
      totalEquipment:  equipment['Total'] ?? 0,
      onTimeRate:      m['onTimeRate'] as double,
      mostBorrowed:    m['mostBorrowed'] as Map<String, int>,
      requests:        txns,
    );
  }

  void _exportReport() {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                FullReportScreen(report: _fullReport(), loadPeriod: _reportFor)));
  }

  // ── Web portal: the period as an Excel workbook ───────────────────────────
  // 2026-10-07: replaces the .csv. The same workbook as the Full Report's
  // Download Excel, for this page's 90 days: Report (as the PDF), Requests,
  // Borrowing records; see report_xlsx.dart.
  void _downloadXlsx() {
    final report = _fullReport();
    final bytes = ReportXlsx.build(report);
    final ok = downloadBytes(ReportXlsx.fileName(report), bytes,
        mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Downloaded the Excel report: ${_allTransactions.length} '
              '${_allTransactions.length == 1 ? 'record' : 'records'} '
              '(last $_reportPeriodDays days).'
          : 'Downloading is available in the web portal.'),
      backgroundColor: ok ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // The period line, with the refresh button that used to sit in this page's
  // own title bar.
  Widget _periodLine() => Row(children: [
        const Icon(Icons.event_note_outlined,
            size: 14, color: AppTheme.textMid),
        const SizedBox(width: 6),
        Expanded(
          child: Text('Borrowing activity — last $_reportPeriodDays days',
              style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textMid,
                  fontWeight: FontWeight.w600)),
        ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded, color: AppTheme.primary),
          onPressed: _load,
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Two report cards per row on a phone, three on a wide window, all six in
    // one row on a full-size monitor (as on the Dashboard).
    final width = MediaQuery.sizeOf(context).width;
    final cardsPerRow = width >= 1400 ? 6 : width >= 900 ? 3 : 2;
    final cards = [
      _ReportCard(
        label: 'Total\nBorrowings',
        value: '$_totalBorrowings',
        icon: Icons.trending_up_rounded,
        color: AppTheme.accent,
      ),
      _ReportCard(
        label: 'On-Time\nReturns',
        value: '${_onTimeRate.toStringAsFixed(0)}%',
        icon: Icons.check_circle_outline_rounded,
        color: AppTheme.success,
      ),
      _ReportCard(
        label: 'Overdue\nItems',
        value: '$_totalOverdue',
        icon: Icons.warning_amber_rounded,
        color: AppTheme.danger,
      ),
      _ReportCard(
        label: 'Damage\nReports',
        value: '$_totalDamage',
        icon: Icons.report_problem_outlined,
        color: AppTheme.warning,
      ),
      _ReportCard(
        label: 'Total\nEquipment',
        value: '$_totalEquipment',
        icon: Icons.science_rounded,
        color: AppTheme.primary,
      ),
      _ReportCard(
        label: 'Returned\nSuccessfully',
        value: '$_totalReturned',
        icon: Icons.assignment_return_rounded,
        color: AppTheme.success,
      ),
    ];
    final exportButton = ElevatedButton.icon(
      onPressed: _exportReport,
      icon: const Icon(Icons.download_rounded),
      label: const Text('Export Full Report'),
      style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primary,
          padding: const EdgeInsets.symmetric(vertical: 14)),
    );
    final xlsxButton = OutlinedButton.icon(
      onPressed: _downloadXlsx,
      icon: const Icon(Icons.table_view_rounded),
      label: const Text('Download Excel Report (.xlsx)'),
      style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14)),
    );

    // No title bar of its own: the staff header above already says "Reports"
    // (until 2026-10-06 this page showed a second one).
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // Borrowing figures are scoped to a period, not all-time.
              _periodLine(),
              const SizedBox(height: 12),

              if (_failed)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14)),
                  child: const Text(
                      'Could not load the report. Pull down or tap refresh to try again.',
                      style: TextStyle(color: AppTheme.textMid)),
                )
              else ...[

              // ── Summary Cards ──
              for (var i = 0; i < cards.length; i += cardsPerRow) ...[
                if (i > 0) const SizedBox(height: 12),
                Row(children: [
                  for (var j = i; j < i + cardsPerRow; j++) ...[
                    if (j > i) const SizedBox(width: 12),
                    cards[j],
                  ],
                ]),
              ],
              const SizedBox(height: 24),

              // ── Most Borrowed and Recent Transactions ──
              // Side by side on a full-size monitor.
              if (width >= 1200)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _mostBorrowedSection()),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _recentSection()),
                    ),
                  ],
                )
              else ...[
                ..._mostBorrowedSection(),
                const SizedBox(height: 24),
                ..._recentSection(),
              ],
              const SizedBox(height: 24),

              // ── Export Buttons ── (side by side on a wide window)
              if (kIsWeb && width >= 900)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: exportButton),
                      const SizedBox(width: 12),
                      Expanded(child: xlsxButton),
                    ],
                  ),
                )
              else ...[
                SizedBox(width: double.infinity, child: exportButton),
                if (kIsWeb) ...[
                  const SizedBox(height: 10),
                  SizedBox(width: double.infinity, child: xlsxButton),
                ],
              ],
              const SizedBox(height: 8),
              // Full width, so it stays centred when it fits on one line.
              SizedBox(
                width: double.infinity,
                child: Text(
                  kIsWeb
                      ? 'Export Full Report shows the whole report on one page: '
                          'choose its dates there, copy it, or download it as an '
                          'Excel workbook or as a PDF to print. Download Excel '
                          'Report saves the last $_reportPeriodDays days.'
                      : 'Export Full Report shows the whole report on one page; '
                          'you can choose its dates there. Copy Report puts it on '
                          'your clipboard for Notes, Email, or Google Docs.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMid),
                ),
              ),
              const SizedBox(height: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Most Borrowed ──
  List<Widget> _mostBorrowedSection() {
    final maxCount = _mostBorrowed.values.isEmpty
        ? 1
        : _mostBorrowed.values.reduce((a, b) => a > b ? a : b);
    return [
      const SectionHeader(title: 'Most Borrowed Equipment'),
      const SizedBox(height: 12),
      if (_mostBorrowed.isEmpty)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14)),
          child: const Center(
            child: Text('No borrowing data yet.',
                style: TextStyle(color: AppTheme.textMid)),
          ),
        )
      else
        ..._mostBorrowed.entries.map((e) {
          final ratio = maxCount > 0 ? e.value / maxCount : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.key,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: AppTheme.textDark)),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 6,
                          backgroundColor: AppTheme.divider,
                          valueColor: const AlwaysStoppedAnimation(
                              AppTheme.accent),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Text('${e.value}x',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppTheme.accent)),
              ]),
            ),
          );
        }),
    ];
  }

  // ── Recent Transactions ──
  List<Widget> _recentSection() => [
        const SectionHeader(title: 'Recent Transactions'),
        const SizedBox(height: 12),
        if (_allTransactions.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14)),
            child: const Center(
              child: Text('No transactions yet.',
                  style: TextStyle(color: AppTheme.textMid)),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14)),
            child: Column(
              children: _allTransactions.take(8).map((tx) {
                final status   = tx['status'] ?? '';
                final student  = tx['borrower_name'] ??
                    tx['student_number'] ?? '—';
                final equip    = tx['equipment_name'] ?? '—';
                final bDate    =
                    '${tx['borrow_date'] ?? ''}'.split('T').first.split(' ').first;
                // The same colours as the full report (Cancelled, new in
                // 1.0.17, is grey, as on Requests).
                final sc = reportStatusColor('$status');
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppTheme.divider),
                    ),
                  ),
                  child: Row(children: [
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                          color: sc, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(student, style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold,
                          color: AppTheme.textDark)),
                      Text(equip, style: const TextStyle(
                          fontSize: 11, color: AppTheme.textMid)),
                    ])),
                    Column(crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                      StatusBadge(label: status, color: sc),
                      const SizedBox(height: 2),
                      Text(bDate, style: const TextStyle(
                          fontSize: 10, color: AppTheme.textLight)),
                    ]),
                  ]),
                );
              }).toList(),
            ),
          ),
      ];
}

class _ReportCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _ReportCard(
      {required this.label,
      required this.value,
      required this.icon,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: color.withAlpha(31),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: color)),
                Text(label,
                    style: const TextStyle(
                        fontSize: 10, color: AppTheme.textMid)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

