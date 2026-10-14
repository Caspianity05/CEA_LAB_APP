// -----------------------------------------------------------------------------
// LabTrack - staff: admin penalties screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------


import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ─── Admin Penalties / Holds Screen (Prof recommendation #3) ──────────────────
// Surfaces students on a borrowing hold and students with overdue loans, and
// lets staff place or lift holds.
class AdminPenaltiesScreen extends StatefulWidget {
  const AdminPenaltiesScreen({super.key});
  @override
  State<AdminPenaltiesScreen> createState() => _AdminPenaltiesScreenState();
}

class _AdminPenaltiesScreenState extends State<AdminPenaltiesScreen> {
  bool _loading = true;
  List<dynamic> _held = [];
  List<dynamic> _overdue = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final held = await ApiService.getHeldStudents();
      final reqs = await ApiService.getRequests();
      final now = DateTime.now();
      final overdue = reqs.where((e) {
        if (e['status'] != 'Approved') return false;
        final due = DateTime.tryParse('${e['due_date']}'.replaceAll(' ', 'T'));
        return due != null && due.isBefore(now);
      }).toList();
      if (!mounted) return;
      setState(() { _held = held; _overdue = overdue; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setHold(String sid, bool hold, {String reason = ''}) async {
    if (sid.isEmpty) return;
    final res = await ApiService.setStudentHold(sid, hold, reason: reason);
    if (!mounted) return;
    if (res['success'] == true) _load();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] == true
          ? (hold ? 'Hold placed.' : 'Hold lifted.')
          : (res['message'] ?? 'Failed.')),
      backgroundColor: res['success'] == true ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Penalties & Holds')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                const SectionHeader(title: 'Students on Hold'),
                const SizedBox(height: 10),
                if (_held.isEmpty)
                  _penaltyEmpty('No students are currently on hold.')
                else
                  ..._held.map(_holdCard),
                const SizedBox(height: 24),
                const SectionHeader(title: 'Overdue Loans'),
                const SizedBox(height: 10),
                if (_overdue.isEmpty)
                  _penaltyEmpty('No overdue loans.')
                else
                  ..._overdue.map(_overdueCard),
                const SizedBox(height: 20),
              ]),
            ),
    );
  }

  Widget _penaltyEmpty(String msg) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Center(
            child: Text(msg,
                style: const TextStyle(color: AppTheme.textMid, fontSize: 13))),
      );

  Widget _holdCard(dynamic s) {
    final sid = '${s['student_id'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: AppTheme.danger, width: 4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.gpp_bad_outlined, color: AppTheme.danger, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('${s['name'] ?? s['student_number'] ?? 'Student'}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14,
                  color: AppTheme.textDark))),
          StatusBadge(label: 'On Hold', color: AppTheme.danger),
        ]),
        const SizedBox(height: 6),
        Text('${s['hold_reason'] ?? ''}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
        if (Session.canManage) ...[
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: () => _setHold(sid, false),
            icon: const Icon(Icons.lock_open_rounded, size: 16),
            label: const Text('Lift Hold'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
          )),
        ],
      ]),
    );
  }

  Widget _overdueCard(dynamic e) {
    final sid = '${e['student_id'] ?? ''}';
    final due = '${e['due_date'] ?? ''}'.split('T').first;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: AppTheme.warning, width: 4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.schedule_rounded, color: AppTheme.warning, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('${e['borrower_name'] ?? e['student_number'] ?? 'Student'}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14,
                  color: AppTheme.textDark))),
          StatusBadge(label: 'Overdue', color: AppTheme.warning),
        ]),
        const SizedBox(height: 6),
        Text('${e['equipment_name'] ?? ''}  •  Due: $due',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
        if (Session.canManage) ...[
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            onPressed: sid.isEmpty
                ? null
                : () => _setHold(sid, true,
                    reason: 'Overdue: "${e['equipment_name'] ?? 'equipment'}" not returned by $due.'),
            icon: const Icon(Icons.gpp_maybe_outlined, size: 16),
            label: const Text('Place Hold'),
            style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.danger,
                side: const BorderSide(color: AppTheme.danger)),
          )),
        ],
      ]),
    );
  }
}

