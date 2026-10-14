// -----------------------------------------------------------------------------
// LabTrack - student: damage report screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../widgets/common.dart';

// ─── Damage Report Screen ─────────────────────────────────────────────────────

class DamageReportScreen extends StatefulWidget {
  const DamageReportScreen({super.key});
  @override
  State<DamageReportScreen> createState() => _DamageReportScreenState();
}

class _DamageReportScreenState extends State<DamageReportScreen> {
  String? _severity;
  String? _selectedEquipmentId;
  String? _selectedEquipmentName;
  bool _loading = false;
  bool _loadingEquipment = true;
  final _descCtrl = TextEditingController();

  // Only equipment the student currently has borrowed (Approved status)
  List<Map<String, dynamic>> _borrowedItems = [];

  @override
  void initState() {
    super.initState();
    _loadBorrowedEquipment();
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBorrowedEquipment() async {
    setState(() => _loadingEquipment = true);
    try {
      final loans = await ApiService.getMyBorrowings(
        studentId: Session.currentUser?['student_id'],
        studentNumber: Session.studentNumber,
      );
      // Only Approved (currently borrowed) items
      final active = loans
          .where((e) => e['status'] == 'Approved')
          .map<Map<String, dynamic>>((e) => {
                'equipment_id':   '${e['equipment_id'] ?? ''}',
                'equipment_name': '${e['equipment_name'] ?? 'Unknown'}',
                'qr_code':        '${e['qr_code'] ?? ''}',
                'transaction_id': '${e['transaction_id'] ?? ''}',
              })
          .toList();

      // Remove duplicates by equipment_id
      final seen = <String>{};
      final unique = active.where((e) => seen.add(e['equipment_id']!)).toList();

      setState(() {
        _borrowedItems = unique;
        _loadingEquipment = false;
      });
    } catch (_) {
      setState(() => _loadingEquipment = false);
    }
  }

  Future<void> _submit() async {
    if (_selectedEquipmentId == null || _selectedEquipmentId!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please select the damaged equipment.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating));
      return;
    }
    if (_severity == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please select the damage severity.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating));
      return;
    }
    if (_descCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please describe the damage.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating));
      return;
    }

    setState(() => _loading = true);
    try {
      final res = await ApiService.submitDamageReport({
        'equipment_id':   _selectedEquipmentId ?? '',
        'equipment_name': _selectedEquipmentName ?? '',
        'student_id':     Session.currentUser?['student_id']?.toString() ?? '',
        'student_number': Session.studentNumber,
        'borrower_name':  Session.name,
        'severity':       _severity ?? 'Minor',
        'description':    '${_severity ?? 'Minor'}: ${_descCtrl.text.trim()}',
      });
      if (!mounted) return;
      if (res['success'] == true) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            icon: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 52),
            title: const Text('Report Submitted'),
            content: const Text(
                'Your damage report has been submitted. Lab staff will review it shortly.',
                textAlign: TextAlign.center),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context); // close dialog
                  Navigator.pop(context); // go back
                },
                child: const Text('OK'),
              )
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(res['message'] ?? 'Submission failed.'),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ApiService.friendlyError(e)),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Damage Report')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Warning banner
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: const Color(0x14EF4444),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0x40EF4444))),
              child: const Row(children: [
                Icon(Icons.warning_amber_rounded, color: AppTheme.danger),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Report any damage immediately. Unreported damage may result in clearance issues.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textDark),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 20),

            // Equipment selector — live from borrowed items
            FieldLabel('Equipment (Your Active Loans)'),
            const SizedBox(height: 8),
            _loadingEquipment
                ? Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.divider)),
                    child: const Row(children: [
                      SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text('Loading your borrowed equipment...',
                          style: TextStyle(color: AppTheme.textMid, fontSize: 13)),
                    ]),
                  )
                : _borrowedItems.isEmpty
                    ? Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppTheme.divider)),
                        child: const Row(children: [
                          Icon(Icons.inventory_2_outlined,
                              color: AppTheme.textLight, size: 20),
                          SizedBox(width: 10),
                          Text('No active loans found.',
                              style: TextStyle(
                                  color: AppTheme.textMid, fontSize: 13)),
                        ]),
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 4),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: _selectedEquipmentId != null
                                    ? AppTheme.primary
                                    : AppTheme.divider)),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: _selectedEquipmentId,
                            hint: const Text(
                                'Select borrowed equipment to report',
                                style: TextStyle(
                                    color: AppTheme.textLight, fontSize: 13)),
                            items: _borrowedItems.map((e) {
                              return DropdownMenuItem<String>(
                                value: e['equipment_id'],
                                child: Row(children: [
                                  const Icon(Icons.science_outlined,
                                      size: 16, color: AppTheme.primary),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(e['equipment_name']!,
                                            style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: AppTheme.textDark)),
                                        Text(e['qr_code']!,
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: AppTheme.textMid)),
                                      ],
                                    ),
                                  ),
                                ]),
                              );
                            }).toList(),
                            onChanged: (val) {
                              final item = _borrowedItems
                                  .firstWhere((e) => e['equipment_id'] == val);
                              setState(() {
                                _selectedEquipmentId   = val;
                                _selectedEquipmentName = item['equipment_name'];
                              });
                            },
                          ),
                        ),
                      ),

            // Total borrowed count info
            if (!_loadingEquipment && _borrowedItems.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'You currently have ${_borrowedItems.length} item(s) borrowed.',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMid),
                ),
              ),
            const SizedBox(height: 20),

            // Severity selector
            FieldLabel('Damage Severity'),
            const SizedBox(height: 10),
            Row(
              children: ['Minor', 'Moderate', 'Severe'].map((s) {
                final colors = {
                  'Minor':    AppTheme.success,
                  'Moderate': AppTheme.warning,
                  'Severe':   AppTheme.danger,
                };
                final c = colors[s]!;
                final selected = _severity == s;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _severity = s),
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: selected ? c.withValues(alpha: 0.12) : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: selected ? c : AppTheme.divider,
                            width: selected ? 2 : 1),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            s == 'Minor'    ? Icons.info_outline_rounded :
                            s == 'Moderate' ? Icons.warning_amber_rounded :
                                              Icons.report_rounded,
                            color: selected ? c : AppTheme.textLight,
                            size: 20,
                          ),
                          const SizedBox(height: 4),
                          Text(s,
                              style: TextStyle(
                                  color: selected ? c : AppTheme.textMid,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // Description
            FieldLabel('Description of Damage'),
            const SizedBox(height: 8),
            TextField(
              controller: _descCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                  hintText: 'Describe the damage in detail. Be specific about what is broken, missing, or not working...'),
            ),
            const SizedBox(height: 28),

            // Submit button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _submit,
                icon: _loading
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.send_rounded),
                label: Text(_loading ? 'Submitting...' : 'Submit Report'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.danger,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
