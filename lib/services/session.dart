// -----------------------------------------------------------------------------
// LabTrack - in-memory session state
//
// Extracted from firstFile.dart on 2026-08-03 as step 3 of the module split.
// Pure Dart: holds the signed-in user map and derives role/permission getters,
// so it needs no Flutter or Firebase imports.
// -----------------------------------------------------------------------------

// ─── Session (simple in-memory user state) ───────────────────────────────────
class Session {
  static Map<String, dynamic>? currentUser;
  static String? role; // 'student' or 'staff'

  static void set(Map<String, dynamic> user, String r) {
    currentUser = user;
    role = r;
  }

  static void clear() {
    currentUser = null;
    role = null;
  }

  static String get name => currentUser?['name'] ?? 'User';
  static String get studentNumber => currentUser?['student_number'] ?? '';
  static int get studentId => int.tryParse('${currentUser?['student_id'] ?? 0}') ?? 0;
  static String get course => currentUser?['course'] ?? '';
  static String get initials {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : 'U';
  }

  // ── Staff permission level ──────────────────────────────────────────────────
  // A staff account's `role` field is one of: 'admin', 'staff', or 'viewer'.
  // Viewers (e.g. the Supervising Minister) can see everything but cannot make
  // changes (Prof recommendation #2 — view-only admin).
  static String get staffRole => (currentUser?['role'] ?? 'staff').toString();
  static bool get isViewer => role == 'staff' && staffRole == 'viewer';
  static bool get isAdmin  => role == 'staff' && staffRole == 'admin';
  // Whether the current user may perform write actions in the staff portal.
  static bool get canManage => role == 'staff' && staffRole != 'viewer';
  // The signed-in staff member's document id — stamped onto transactions they
  // approve/reject/return so there's an audit trail of who did what.
  static String get staffId => (currentUser?['staff_id'] ?? '').toString();

  // ── Borrowing hold / penalty (students) ────────────────────────────────────
  static bool get isOnHold => currentUser?['hold'] == true;
  static String get holdReason =>
      (currentUser?['hold_reason'] ?? '').toString();
}
