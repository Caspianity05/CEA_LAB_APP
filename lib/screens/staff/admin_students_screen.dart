// -----------------------------------------------------------------------------
// LabTrack - staff: admin students screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 7 of the module split.
// -----------------------------------------------------------------------------


import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'admin_student_detail_screen.dart';

// ─── Admin Students Directory ─────────────────────────────────────────────────
// Staff-only, searchable list of registered students. Tapping one opens their
// detail view. Viewers can browse it read-only. The security rules already let
// any staff member read the students collection while blocking student-to-
// student reads, so this exposes no more than staff already handle on every
// borrow request.
class AdminStudentsScreen extends StatefulWidget {
  const AdminStudentsScreen({super.key});
  @override
  State<AdminStudentsScreen> createState() => _AdminStudentsScreenState();
}

class _AdminStudentsScreenState extends State<AdminStudentsScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _loading = true;
  List<dynamic> _all = [];

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getStudents();
      if (!mounted) return;
      setState(() { _all = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<dynamic> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all.where((s) {
      final name = '${s['name'] ?? ''}'.toLowerCase();
      final number = '${s['student_number'] ?? ''}'.toLowerCase();
      return name.contains(q) || number.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Students')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Search by name or student number',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () { _searchCtrl.clear(); setState(() => _query = ''); },
                    ),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
            ),
          ),
        ),
        if (!_loading)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('${_filtered.length} student${_filtered.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _filtered.isEmpty
                      ? ListView(children: [
                          const SizedBox(height: 80),
                          Center(child: Text(
                            _query.isEmpty
                                ? 'No students registered yet.'
                                : 'No students match "$_query".',
                            style: const TextStyle(color: AppTheme.textMid))),
                        ])
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _filtered.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (_, i) => _studentTile(_filtered[i]),
                        ),
                ),
        ),
      ]),
    );
  }

  Widget _studentTile(dynamic s) {
    final name = '${s['name'] ?? 'Student'}';
    final onHold = s['hold'] == true;
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(
              builder: (_) => AdminStudentDetailScreen(student: Map<String, dynamic>.from(s))));
          _load(); // reflect any hold change made in the detail view
        },
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: const Color(0x141B3A8C),
          child: Text(Session.initialsOf(name),
              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        ),
        title: Text(name,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
        subtitle: Text('${s['student_number'] ?? ''}  •  ${courseLabel('${s['course'] ?? ''}')}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
        trailing: onHold
            ? StatusBadge(label: 'On Hold', color: AppTheme.danger)
            : const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppTheme.textLight),
      ),
    );
  }
}

