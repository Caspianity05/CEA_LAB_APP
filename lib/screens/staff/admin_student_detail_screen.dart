// -----------------------------------------------------------------------------
// LabTrack - staff: admin student detail screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ─── Admin Student Detail ─────────────────────────────────────────────────────
// One student's profile, borrowing history, and — for staff who can manage —
// hold and password-reset actions. Viewers see everything but no action buttons.
class AdminStudentDetailScreen extends StatefulWidget {
  final Map<String, dynamic> student;
  const AdminStudentDetailScreen({super.key, required this.student});
  @override
  State<AdminStudentDetailScreen> createState() => _AdminStudentDetailScreenState();
}

class _AdminStudentDetailScreenState extends State<AdminStudentDetailScreen> {
  late Map<String, dynamic> _student;
  List<dynamic> _txns = [];
  bool _loadingTxns = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _student = Map<String, dynamic>.from(widget.student);
    _loadTxns();
  }

  String get _sid => '${_student['student_id'] ?? ''}';

  Future<void> _loadTxns() async {
    setState(() => _loadingTxns = true);
    try {
      final t = await ApiService.getStudentTransactions(_sid);
      if (!mounted) return;
      setState(() { _txns = t; _loadingTxns = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingTxns = false);
    }
  }

  Future<void> _refreshStudent() async {
    final fresh = await ApiService.getStudent(_sid);
    if (fresh != null && mounted) setState(() => _student = fresh);
  }

  void _snack(String msg, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _placeHold() async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Place Hold'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('The student will be blocked from borrowing until the hold '
              'is lifted. Add a reason they will see.',
              style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const SizedBox(height: 12),
          TextField(controller: reasonCtrl, maxLines: 2,
            decoration: const InputDecoration(
                hintText: 'e.g. Unreturned multimeter; settle with lab staff')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(onPressed: () => Navigator.pop(dCtx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              child: const Text('Place Hold')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final res = await ApiService.setStudentHold(_sid, true, reason: reasonCtrl.text.trim());
    if (mounted) setState(() => _busy = false);
    if (res['success'] == true) { await _refreshStudent(); _snack('Hold placed.'); }
    else { _snack(res['message'] ?? 'Failed to place hold.', ok: false); }
  }

  Future<void> _liftHold() async {
    setState(() => _busy = true);
    final res = await ApiService.setStudentHold(_sid, false);
    if (mounted) setState(() => _busy = false);
    if (res['success'] == true) { await _refreshStudent(); _snack('Hold lifted.'); }
    else { _snack(res['message'] ?? 'Failed to lift hold.', ok: false); }
  }

  Future<void> _sendReset() async {
    final email = '${_student['email'] ?? ''}';
    if (email.isEmpty) { _snack('This student has no email on file.', ok: false); return; }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Send Password Reset'),
        content: Text('Send a password-reset email to $email?',
            style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(onPressed: () => Navigator.pop(dCtx, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final res = await ApiService.sendPasswordReset(email);
    if (mounted) setState(() => _busy = false);
    _snack(res['success'] == true
        ? 'Reset email sent to $email.'
        : (res['message'] ?? 'Could not send reset email.'),
        ok: res['success'] == true);
  }

  @override
  Widget build(BuildContext context) {
    final onHold = _student['hold'] == true;
    final name = '${_student['name'] ?? 'Student'}';
    return Scaffold(
      appBar: AppBar(title: const Text('Student')),
      body: ListView(padding: readablePadding(context, const EdgeInsets.all(16), maxWidth: 900), children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            CircleAvatar(radius: 28, backgroundColor: const Color(0x141B3A8C),
              child: Text(Session.initialsOf(name),
                  style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 18))),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textDark)),
              const SizedBox(height: 2),
              Text('${_student['student_number'] ?? ''}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
            ])),
            if (onHold) StatusBadge(label: 'On Hold', color: AppTheme.danger),
          ]),
        ),
        const SizedBox(height: 12),
        // Info rows (each is its own card)
        DetailRow(label: 'Program', value: courseLabel('${_student['course'] ?? ''}')),
        DetailRow(label: 'Year Level', value: '${_student['year_level'] ?? '-'}'),
        DetailRow(label: 'Email', value: '${_student['email'] ?? '-'}'),
        DetailRow(label: 'Member Since', value: _memberSince()),
        // Reliability summary (once history has loaded)
        if (!_loadingTxns) ...[
          const SizedBox(height: 4),
          _reliabilityCard(),
        ],
        // Hold reason
        if (onHold && '${_student['hold_reason'] ?? ''}'.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0x14E53935), borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x33E53935))),
            child: Row(children: [
              const Icon(Icons.gpp_bad_outlined, color: AppTheme.danger, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text('${_student['hold_reason']}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textDark))),
            ]),
          ),
        ],
        // Actions — managers only; viewers see the info above but no buttons.
        if (Session.canManage) ...[
          const SizedBox(height: 16),
          if (onHold)
            SizedBox(width: double.infinity, child: ElevatedButton.icon(
              onPressed: _busy ? null : _liftHold,
              icon: const Icon(Icons.lock_open_rounded, size: 16),
              label: const Text('Lift Hold'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
            ))
          else
            SizedBox(width: double.infinity, child: ElevatedButton.icon(
              onPressed: _busy ? null : _placeHold,
              icon: const Icon(Icons.gpp_maybe_outlined, size: 16),
              label: const Text('Place Hold'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            )),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            onPressed: _busy ? null : _sendReset,
            icon: const Icon(Icons.mail_outline_rounded, size: 16),
            label: const Text('Send Password Reset'),
            style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary, side: const BorderSide(color: AppTheme.primary)),
          )),
        ],
        const SizedBox(height: 24),
        SectionHeader(
          title: 'Borrowing History',
          action: _txns.isEmpty ? null : 'Export',
          onAction: _txns.isEmpty ? null : _exportHistory,
        ),
        const SizedBox(height: 10),
        if (_loadingTxns)
          const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
        else if (_txns.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: const Center(child: Text('No borrowing records.',
                style: TextStyle(color: AppTheme.textMid, fontSize: 13))),
          )
        else
          ..._txns.map(_txnCard),
        const SizedBox(height: 20),
      ]),
    );
  }

  Widget _reliabilityCard() {
    final r = ApiService.studentReliability(_txns);
    final rating = '${r['rating']}';
    final color = rating == 'Good'
        ? AppTheme.success
        : rating == 'Fair'
            ? AppTheme.warning
            : AppTheme.danger;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Reliability',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
          const Spacer(),
          StatusBadge(label: rating, color: color),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _relStat('${r['loans']}', 'Loans', AppTheme.primary)),
          Expanded(child: _relStat('${r['late']}', 'Late', AppTheme.warning)),
          Expanded(child: _relStat('${r['overdue']}', 'Overdue', AppTheme.danger)),
          Expanded(child: _relStat('${r['damages']}', 'Damages', AppTheme.danger)),
        ]),
      ]),
    );
  }

  Widget _relStat(String value, String label, Color color) => Column(children: [
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textMid)),
      ]);

  Future<void> _exportHistory() async {
    final buf = StringBuffer();
    buf.writeln('LabTrack — Student Borrowing History');
    buf.writeln('=====================================');
    buf.writeln('Name        : ${_student['name'] ?? ''}');
    buf.writeln('Student No. : ${_student['student_number'] ?? ''}');
    buf.writeln('Program     : ${courseLabel('${_student['course'] ?? ''}')}');
    buf.writeln('Year Level  : ${_student['year_level'] ?? '-'}');
    final r = ApiService.studentReliability(_txns);
    buf.writeln('Reliability : ${r['rating']} '
        '(loans ${r['loans']}, late ${r['late']}, overdue ${r['overdue']}, damages ${r['damages']})');
    buf.writeln('Generated   : ${DateTime.now()}');
    buf.writeln('');
    buf.writeln('Transactions (${_txns.length}):');
    if (_txns.isEmpty) {
      buf.writeln('  (none)');
    } else {
      for (final e in _txns) {
        final name = '${e['equipment_name'] ?? 'Equipment'}';
        final status = '${e['status'] ?? ''}';
        final borrow = '${e['borrow_date'] ?? ''}'.split('T').first;
        final due = '${e['due_date'] ?? ''}'.split('T').first;
        buf.writeln('  - $name | $status | borrowed $borrow | due $due');
      }
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('History copied to clipboard. Paste into Notes or email.'),
      backgroundColor: AppTheme.success,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Widget _txnCard(dynamic e) {
    final status = '${e['status'] ?? ''}';
    // Approved items still at the lab, and overdue ones, say so (2026-10-06).
    final ready = ApiService.awaitingPickup(e);
    final overdue = ApiService.isOverdue(e);
    final color = ready ? AppTheme.primary
        : overdue ? AppTheme.danger
        : status == 'Approved' ? AppTheme.success
        : status == 'Pending' ? AppTheme.accent
        : status == 'Rejected' ? AppTheme.danger
        : AppTheme.textMid;
    final label = ready ? 'Ready for pick-up' : overdue ? 'Overdue' : status;
    final borrow = '${e['borrow_date'] ?? ''}'.split('T').first;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        const Icon(Icons.science_outlined, size: 18, color: AppTheme.textMid),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${e['equipment_name'] ?? 'Equipment'}',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textDark)),
          if (borrow.isNotEmpty)
            // The date is when the row was filed, which is only a borrow date
            // once staff approved it. Pending and Rejected rows used to read
            // "Borrowed:" for equipment the student never received
            // (QA 2026-09-19, low #12).
            Text(
                status == 'Pending' || status == 'Rejected' ||
                        status == 'Cancelled' || ready
                    ? 'Requested: $borrow'
                    : 'Borrowed: $borrow',
                style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
        ])),
        StatusBadge(label: label, color: color),
      ]),
    );
  }

  String _memberSince() {
    final raw = _student['created_at'];
    DateTime? dt;
    if (raw is Timestamp) {
      dt = raw.toDate();
    } else {
      dt = DateTime.tryParse('$raw');
    }
    if (dt == null) return '-';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
