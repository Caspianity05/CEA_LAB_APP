// -----------------------------------------------------------------------------
// LabTrack - staff: admin damage reports screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------


import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ─── Admin Damage Reports Screen (staff review) ───────────────────────────────
// Lets laboratory staff review damage reports filed by students (and logged on
// QR returns), mark them resolved, and place a hold on the borrower.
class AdminDamageReportsScreen extends StatefulWidget {
  const AdminDamageReportsScreen({super.key});
  @override
  State<AdminDamageReportsScreen> createState() =>
      _AdminDamageReportsScreenState();
}

class _AdminDamageReportsScreenState extends State<AdminDamageReportsScreen> {
  bool _loading = true;
  List<dynamic> _reports = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getDamageReports();
      if (!mounted) return;
      setState(() { _reports = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'Resolved': return AppTheme.success;
      case 'Reviewed': return AppTheme.primary;
      default:         return AppTheme.warning; // Open
    }
  }

  // Resolving a report used to do exactly one thing: flip its status. The item
  // stayed Under Repair and the borrower stayed on hold, so "resolved" meant
  // staff still had two more screens to visit and it was easy to forget one
  // (QA 2026-09-19, low #7). `updateDamageReport` already accepted the
  // equipment status — nothing ever passed it. Both follow-ups are offered
  // here, ticked by default, and staff can untick either.
  Future<void> _resolve(Map<String, dynamic> r) async {
    final equipId = '${r['equipment_id'] ?? ''}';
    final sid     = '${r['student_id'] ?? ''}';
    final eqName  = '${r['equipment_name'] ?? 'the equipment'}';
    final who     = '${r['borrower_name'] ?? 'the borrower'}';
    var freeEquipment = equipId.isNotEmpty;
    var liftHold      = sid.isNotEmpty;

    final go = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (_, setLocal) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Resolve Damage Report'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Mark this report as resolved. You can also finish '
                  'the clean-up in the same step:',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              if (equipId.isNotEmpty)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  value: freeEquipment,
                  onChanged: (v) => setLocal(() => freeEquipment = v ?? false),
                  title: Text('Return $eqName to Available',
                      style: const TextStyle(fontSize: 13)),
                ),
              if (sid.isNotEmpty)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  value: liftHold,
                  onChanged: (v) => setLocal(() => liftHold = v ?? false),
                  title: Text("Lift $who's borrowing hold",
                      style: const TextStyle(fontSize: 13)),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(dctx, true),
                child: const Text('Resolve')),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;

    final res = await ApiService.updateDamageReport(
      '${r['report_id']}',
      'Resolved',
      equipmentId: freeEquipment ? equipId : null,
      equipmentStatus: freeEquipment ? 'Available' : null,
    );
    // The hold is a separate document, so a failure there must not be hidden
    // behind the report's own success.
    String? holdError;
    if (res['success'] == true && liftHold) {
      final h = await ApiService.setStudentHold(sid, false);
      if (h['success'] != true) holdError = '${h['message'] ?? 'unknown error'}';
    }
    if (!mounted) return;
    if (res['success'] == true) _load();

    final done = <String>[
      'Report resolved',
      if (freeEquipment && res['success'] == true) '$eqName is Available',
      if (liftHold && holdError == null && res['success'] == true)
        "$who's hold lifted",
    ];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] != true
          ? '${res['message'] ?? 'Failed.'}'
          : holdError != null
              ? '${done.join(' · ')}, but the hold could not be lifted: $holdError'
              : '${done.join(' · ')}.'),
      backgroundColor: res['success'] == true && holdError == null
          ? AppTheme.success
          : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 5),
    ));
  }

  Future<void> _holdBorrower(Map<String, dynamic> r) async {
    final sid = '${r['student_id'] ?? ''}';
    if (sid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No linked student account for this report.'),
        backgroundColor: AppTheme.danger, behavior: SnackBarBehavior.floating));
      return;
    }
    final res = await ApiService.setStudentHold(sid, true,
        reason: 'Damaged equipment "${r['equipment_name'] ?? ''}" pending settlement.');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] == true
          ? 'Hold placed on borrower.'
          : (res['message'] ?? 'Failed.')),
      backgroundColor: AppTheme.danger, behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Damage Reports')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _reports.isEmpty
              ? const Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.verified_outlined, size: 52, color: AppTheme.textLight),
                    SizedBox(height: 12),
                    Text('No damage reports', style: TextStyle(color: AppTheme.textMid)),
                  ]),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _reports.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final r = _reports[i];
                      final status = '${r['status'] ?? 'Open'}';
                      final sc = _statusColor(status);
                      final date = '${r['reported_at'] ?? ''}'.split('T').first;
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border(left: BorderSide(color: sc, width: 4)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            const Icon(Icons.report_problem_outlined,
                                color: AppTheme.warning, size: 20),
                            const SizedBox(width: 8),
                            Expanded(child: Text('${r['equipment_name'] ?? 'Equipment'}',
                                style: const TextStyle(fontWeight: FontWeight.bold,
                                    fontSize: 14, color: AppTheme.textDark))),
                            StatusBadge(label: status, color: sc),
                          ]),
                          const SizedBox(height: 8),
                          Text('${r['description'] ?? ''}',
                              style: const TextStyle(fontSize: 13,
                                  color: AppTheme.textMid, height: 1.5)),
                          const SizedBox(height: 8),
                          Row(children: [
                            const Icon(Icons.person_outline_rounded, size: 13, color: AppTheme.textLight),
                            const SizedBox(width: 4),
                            Expanded(child: Text(
                                '${r['borrower_name'] ?? r['student_number'] ?? '—'}',
                                style: const TextStyle(fontSize: 12, color: AppTheme.textMid))),
                            const Icon(Icons.calendar_today_rounded, size: 12, color: AppTheme.textLight),
                            const SizedBox(width: 4),
                            Text(date, style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
                          ]),
                          if (Session.canManage && status != 'Resolved') ...[
                            const SizedBox(height: 12),
                            const Divider(height: 1, color: AppTheme.divider),
                            const SizedBox(height: 10),
                            Row(children: [
                              Expanded(child: OutlinedButton.icon(
                                onPressed: () => _holdBorrower(r),
                                icon: const Icon(Icons.gpp_maybe_outlined, size: 16),
                                label: const Text('Hold'),
                                style: OutlinedButton.styleFrom(
                                    foregroundColor: AppTheme.danger,
                                    side: const BorderSide(color: AppTheme.danger)),
                              )),
                              const SizedBox(width: 10),
                              Expanded(child: ElevatedButton.icon(
                                onPressed: () => _resolve(r),
                                icon: const Icon(Icons.check_rounded, size: 16),
                                label: const Text('Resolve'),
                                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
                              )),
                            ]),
                          ],
                        ]),
                      );
                    },
                  ),
                ),
    );
  }
}

