// -----------------------------------------------------------------------------
// LabTrack - staff: staff accounts (super admin only)
//
// Added 2026-09-23. The senior account's one extra power: set another staff
// member's display name and access level. Everything else about staff
// provisioning stays out-of-band — no client, superadmin included, can create
// or delete a staff account (firestore.rules), so this screen manages the
// accounts that exist and nothing more.
//
// Your own row is deliberately not editable here. Your name belongs to My
// Profile, and your own access level can only be changed by another super
// admin — that is what stops the last one demoting itself and leaving the
// system with no senior account. The rules enforce both; this screen only
// explains them.
// -----------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../services/api_service.dart';
import '../../services/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ─── Staff Accounts Screen ────────────────────────────────────────────────────

class AdminStaffAccountsScreen extends StatefulWidget {
  const AdminStaffAccountsScreen({super.key});
  @override
  State<AdminStaffAccountsScreen> createState() => _AdminStaffAccountsScreenState();
}

class _AdminStaffAccountsScreenState extends State<AdminStaffAccountsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _staff = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  // Only the first load swaps the list for a spinner. A reload after a save,
  // or a pull-to-refresh, keeps the list on screen so it keeps its scroll
  // position — swapping it out sent the super admin back to the top after
  // every edit (QA 2026-09-23, F3). A failed reload keeps the list too and
  // says so in a snackbar.
  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final list = await ApiService.getStaffList();
      if (!mounted) return;
      setState(() { _staff = list; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      final msg = ApiService.friendlyError(e);
      setState(() {
        _loading = false;
        if (_staff.isEmpty) _error = msg;
      });
      if (_staff.isNotEmpty) _snack(msg, AppTheme.danger);
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'superadmin': return AppTheme.accent;
      case 'viewer':     return AppTheme.textLight;
      default:           return AppTheme.primary;
    }
  }

  // Edit sheet for ONE other staff member: their display name, their access
  // level, or both. Sent as a single update so the rules see one write.
  Future<void> _edit(Map<String, dynamic> member) async {
    final id        = '${member['staff_id']}';
    final nameCtrl  = TextEditingController(text: '${member['name'] ?? ''}');
    final startName = nameCtrl.text;
    var role        = '${member['role'] ?? 'staff'}';
    if (!kStaffRoles.contains(role)) role = 'staff';
    final startRole = role;
    var saving = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => StatefulBuilder(builder: (sheetCtx, setSheet) {
        Future<void> save() async {
          final name = nameCtrl.text.trim();
          if (name.length < 2) {
            _snack('Please enter a full name (at least 2 characters).', AppTheme.danger);
            return;
          }
          if (name.length > 60) {
            _snack('That name is too long (60 characters maximum).', AppTheme.danger);
            return;
          }
          if (name == startName && role == startRole) {
            Navigator.pop(sheetCtx);
            return;
          }
          setSheet(() => saving = true);
          final navigator = Navigator.of(sheetCtx);
          final res = await ApiService.updateStaffMember(
            staffId: id,
            name: name == startName ? null : name,
            role: role == startRole ? null : role,
          );
          if (!mounted) return;
          navigator.pop();
          if (res['success'] == true) {
            _snack('${member['email']} updated.', AppTheme.success);
            await _load();
          } else {
            _snack('${res['message'] ?? 'Update failed.'}', AppTheme.danger);
          }
        }

        return Padding(
          padding: EdgeInsets.only(
              left: 20, right: 20, top: 20,
              bottom: 20 + MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(color: AppTheme.divider, borderRadius: BorderRadius.circular(2))),
            ),
            Text('${member['email']}',
                style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
            const SizedBox(height: 16),
            FieldLabel('Display Name'),
            const SizedBox(height: 8),
            TextField(
              controller: nameCtrl,
              enabled: !saving,
              textCapitalization: TextCapitalization.words,
              maxLength: 60,
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.person_outline_rounded, color: AppTheme.textMid)),
            ),
            FieldLabel('Access Level'),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: role,
              decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  prefixIcon: Icon(Icons.shield_outlined, color: AppTheme.textMid)),
              isExpanded: true,
              items: kStaffRoles
                  .map((r) => DropdownMenuItem(value: r, child: Text(staffRoleName(r))))
                  .toList(),
              onChanged: saving ? null : (v) => setSheet(() => role = v ?? role),
            ),
            const SizedBox(height: 6),
            Text(kStaffRoleBlurbs[role] ?? '',
                style: const TextStyle(fontSize: 11, color: AppTheme.textMid, height: 1.4)),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: saving ? null : save,
              icon: saving
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.save_rounded),
              label: const Text('Save Changes'),
            ),
          ]),
        );
      }),
    );
    nameCtrl.dispose();
  }

  Widget _row(Map<String, dynamic> m) {
    final id     = '${m['staff_id']}';
    final isMe   = id == Session.staffId;
    final role   = '${m['role'] ?? 'staff'}';
    final name   = '${m['name'] ?? '(no name)'}';
    final inits  = Session.initialsOf(name);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: const Color(0x26F5A623),
          child: Text(inits,
              style: const TextStyle(color: AppTheme.accent, fontWeight: FontWeight.bold)),
        ),
        title: Row(children: [
          Flexible(
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.textDark)),
          ),
          if (isMe) ...[
            const SizedBox(width: 8),
            const StatusBadge(label: 'You', color: AppTheme.textLight),
          ],
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 2),
          Text('${m['email'] ?? ''}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
          const SizedBox(height: 6),
          StatusBadge(label: staffRoleName(role), color: _roleColor(role)),
        ]),
        trailing: isMe
            ? null
            : const Icon(Icons.edit_outlined, color: AppTheme.textLight, size: 20),
        onTap: isMe
            ? () => _snack('Change your own name in My Profile.', AppTheme.textMid)
            : () => _edit(m),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff Accounts'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading && _staff.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center,
                        style: const TextStyle(color: AppTheme.danger)),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: readablePadding(context, const EdgeInsets.all(20), maxWidth: 900),
                    children: [
                      const SectionDivider(
                          icon: Icons.manage_accounts_rounded,
                          label: 'Accounts',
                          color: AppTheme.primary),
                      const SizedBox(height: 12),
                      ..._staff.map(_row),
                      const SizedBox(height: 8),
                      const Text(
                        'New staff accounts are created by an administrator outside the app '
                        '(Firebase console, or scripts/create-admins.js) and cannot be deleted '
                        'from here. Sign-in emails are fixed for the same reason: the login '
                        'looks accounts up by them.',
                        style: TextStyle(fontSize: 11, color: AppTheme.textMid, height: 1.5),
                      ),
                    ],
                  ),
                ),
    );
  }
}
