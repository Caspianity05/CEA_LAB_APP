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
  // The student's Firebase Auth UID — also their `students/{uid}` doc id. It
  // is alphanumeric: this getter used to int.parse it (a PHP/MySQL leftover),
  // which always gave 0, so Edit Profile wrote to `students/0` and was refused
  // for every student (QA 2026-09-19, H2).
  static String get studentId => '${currentUser?['student_id'] ?? ''}';
  static String get course => currentUser?['course'] ?? '';
  static String get initials => initialsOf(name, fallback: 'U');

  // Up to two initials from a display name. Splits on any run of whitespace:
  // splitting on a single ' ' turned "ce  demo" into ['ce', '', 'demo'] and
  // ''[0] threw, which red-screened every avatar for that user — and the name
  // lives in Firestore, so it survived a restart (QA 2026-09-23, F1).
  static String initialsOf(String name, {String fallback = '?'}) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return fallback;
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  // ── Staff permission level ──────────────────────────────────────────────────
  // A staff account's `role` field is one of: 'superadmin', 'admin', 'staff' or
  // 'viewer'. Viewers (e.g. the Supervising Minister) can see everything but
  // cannot make changes (Prof recommendation #2 — view-only admin). A superadmin
  // is an admin that may also manage the other staff accounts (2026-09-23).
  //
  // There is deliberately no isAdmin. 'admin' and 'staff' have the same
  // permissions — the paper's "full-access administrators or staff" — so
  // nothing may branch on the difference; an unused isAdmin only suggested a
  // hierarchy the system does not have (QA 2026-09-23, F4). The one place the
  // two differ is the e-mail gate at sign-in (kProvisionedStaffRoles).
  static String get staffRole => (currentUser?['role'] ?? 'staff').toString();
  static bool get isViewer => role == 'staff' && staffRole == 'viewer';
  static bool get isSuper  => role == 'staff' && staffRole == 'superadmin';
  // What the badge prints: 'SUPER ADMIN' reads better than 'SUPERADMIN'.
  static String get staffRoleLabel =>
      isSuper ? 'SUPER ADMIN' : staffRole.toUpperCase();
  // Whether the current user may perform write actions in the staff portal.
  static bool get canManage => role == 'staff' && staffRole != 'viewer';
  // The signed-in staff member's document id — stamped onto transactions they
  // approve/reject/return so there's an audit trail of who did what.
  static String get staffId => (currentUser?['staff_id'] ?? '').toString();

  // Folds a fresh copy of the signed-in staff member's own document into the
  // session. The staff portal listens to that document (QA 2026-09-23, F2), so
  // a level changed by a super admin reaches this device at once instead of at
  // the next sign-in. Login and the splash restore both build the session as
  // that document plus `staff_id`, so a fresh copy replaces it, not merges.
  // `narrowed` means something this account could do a moment ago is gone.
  static ({bool nameChanged, bool roleChanged, bool narrowed}) refreshStaff(
      Map<String, dynamic> doc) {
    if (role != 'staff') {
      return (nameChanged: false, roleChanged: false, narrowed: false);
    }
    final id = staffId, oldName = name, oldRole = staffRole;
    final couldManage = canManage, wasSuper = isSuper;
    currentUser = {...doc, 'staff_id': id};
    return (
      nameChanged: name != oldName,
      roleChanged: staffRole != oldRole,
      narrowed: (couldManage && !canManage) || (wasSuper && !isSuper),
    );
  }

  // ── Borrowing hold / penalty (students) ────────────────────────────────────
  static bool get isOnHold => currentUser?['hold'] == true;
  static String get holdReason =>
      (currentUser?['hold_reason'] ?? '').toString();
}
