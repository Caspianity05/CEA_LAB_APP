// -----------------------------------------------------------------------------
// LabTrack - student: edit profile screen
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../widgets/common.dart';

// ─── Edit Profile Screen ──────────────────────────────────────────────────────

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});
  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late TextEditingController _nameCtrl;
  String? _selectedCourse;
  late TextEditingController _yearCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: Session.name);
    final stored = Session.currentUser?['course'] as String?;
    _selectedCourse = kCourses.contains(stored) ? stored : null;
    _yearCtrl = TextEditingController(text: '${Session.currentUser?['year_level'] ?? ''}');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name   = _nameCtrl.text.trim();
    final course = _selectedCourse ?? '';
    final yearLevel = int.tryParse(_yearCtrl.text.trim()) ?? 1;

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name cannot be empty.'), backgroundColor: AppTheme.danger));
      return;
    }

    setState(() => _saving = true);
    try {
      final res = await ApiService.updateProfile(
        studentId: Session.studentId, // the UID — see Session.studentId
        name:      name,
        course:    course,
        yearLevel: yearLevel,
      );
      if (!mounted) return;

      if (res['success'] == true) {
        // Update local session so UI reflects changes immediately
        if (Session.currentUser != null) {
          Session.currentUser!['name']       = name;
          Session.currentUser!['course']     = course;
          Session.currentUser!['year_level'] = yearLevel;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile updated successfully!'),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res['message'] ?? 'Update failed.'),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot connect to server.'),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Avatar
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 48,
                    backgroundColor: const Color(0x26F5A623),
                    child: Text(Session.initials,
                        style: const TextStyle(
                            color: AppTheme.accent,
                            fontSize: 34,
                            fontWeight: FontWeight.bold)),
                  ),
                  // A camera badge used to sit here with no handler behind it,
                  // offering a profile photo the app has never supported —
                  // students are identified by their initials and student
                  // number (QA 2026-09-19, low #1). Removed rather than wired
                  // up: student avatars are not part of the system.
                ],
              ),
            ),
            const SizedBox(height: 28),

            // Student ID (read-only)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.divider)),
              child: Row(children: [
                const Icon(Icons.badge_outlined, color: AppTheme.textMid, size: 20),
                const SizedBox(width: 12),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Student ID', style: TextStyle(fontSize: 11, color: AppTheme.textMid)),
                  Text(Session.studentNumber,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
                ]),
                const Spacer(),
                const StatusBadge(label: 'Read-only', color: AppTheme.textLight),
              ]),
            ),
            const SizedBox(height: 16),

            FieldLabel('Full Name'),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  hintText: 'e.g. Juan Santos',
                  prefixIcon: Icon(Icons.person_outline_rounded, color: AppTheme.textMid)),
            ),
            const SizedBox(height: 16),

            FieldLabel('Course'),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedCourse,
              decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  prefixIcon: Icon(Icons.school_outlined, color: AppTheme.textMid)),
              hint: const Text('Select course'),
              isExpanded: true,
              items: kCourses.map((c) => DropdownMenuItem(value: c, child: Text(courseLabel(c)))).toList(),
              onChanged: (v) => setState(() => _selectedCourse = v),
            ),
            const SizedBox(height: 16),

            FieldLabel('Year Level'),
            const SizedBox(height: 8),
            TextField(
              controller: _yearCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  hintText: 'e.g. 3',
                  prefixIcon: Icon(Icons.calendar_today_outlined, color: AppTheme.textMid)),
            ),
            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.save_rounded),
                label: const Text('Save Changes'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
