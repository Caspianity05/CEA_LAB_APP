// -----------------------------------------------------------------------------
// LabTrack - shared constants
//
// Extracted from firstFile.dart on 2026-08-03 as step 2 of the module split.
// The _k-prefixed names were library-private; they are public here because they
// are now read from several libraries. No values changed.
// -----------------------------------------------------------------------------

// ─── Build identity ───────────────────────────────────────────────────────────
// Shown on the student About screen. Until 2026-08-04 that screen carried a
// hardcoded 'Version 1.0.0' while pubspec.yaml sat at 1.0.0+1 through every
// build ever installed — so no two builds could be told apart on a phone, and
// "it still shows the old behaviour" was impossible to diagnose.
//
// ⚠️ BUMP kAppBuild ON EVERY RELEASE BUILD, and keep pubspec.yaml's
// `version: <kAppVersion>+<kAppBuild>` in step. Dart cannot read pubspec at
// runtime without adding the package_info_plus plugin, which is not worth a new
// native dependency this close to the defense.
const kAppVersion = '1.0.7';
const kAppBuild = 8;

// What the About screen prints, e.g. "Version 1.0.1 (build 2)".
const kAppVersionLabel = 'Version $kAppVersion (build $kAppBuild)';

// ─── Shared constants ─────────────────────────────────────────────────────────
// Engineering programs/courses offered by CEA. Equipment can be tagged with the
// programs allowed to borrow it (Prof recommendation #1 — categorize by program).
// The short code is what gets stored on the student/equipment records; the full
// program name (see kCourseNames) is what we show in the UI.
const kCourses = ['CE', 'ME', 'ECE', 'EE', 'IE', 'Arch'];

// Human-readable program names, keyed by the stored course code.
const kCourseNames = {
  'CE':   'Civil Engineering',
  'ME':   'Mechanical Engineering',
  'ECE':  'Electronics Engineering',
  'EE':   'Electrical Engineering',
  'IE':   'Industrial Engineering',
  'Arch': 'Architecture',
};

// Friendly label for a course code, e.g. 'CE' → 'Civil Engineering'.
// Falls back to the raw code for any legacy/unknown value.
String courseLabel(String code) => kCourseNames[code] ?? code;

// Equipment categories — single source of truth shared by the catalog, inventory
// filter, registration and edit screens so the lists never drift apart.
const kCategories = [
  'Electronics', 'Optics', 'Measurement', 'Tools',
  'Microcontroller', 'Safety', 'Other',
];

// Equipment availability / condition statuses.
const kStatuses = ['Available', 'Borrowed', 'Under Repair', 'For Disposal'];

// ─── Staff access levels ──────────────────────────────────────────────────────
// Mirrors the roles firestore.rules knows about. 'superadmin' was added on
// 2026-09-23: an admin that may also manage the other staff accounts (rename
// them, change their level) from the Staff Accounts screen. Creating and
// deleting staff accounts is still out-of-band — console or
// scripts/create-admins.js — for every level, superadmin included.
const kStaffRoles = ['superadmin', 'admin', 'staff', 'viewer'];

const kStaffRoleNames = {
  'superadmin': 'Super Admin',
  'admin':      'Admin',
  'staff':      'Lab Staff',
  'viewer':     'View Only',
};

// Friendly label for a stored role, e.g. 'superadmin' → 'Super Admin'.
String staffRoleName(String role) => kStaffRoleNames[role] ?? role;

// Levels treated as set up by an administrator, so they skip the e-mail
// verification gate at sign-in (ApiService.passesVerificationGate). A Lab
// Staff account needs a verified address instead, unless it predates
// kLegacyAccountCutoff — the ONE enforced difference between Admin and Lab
// Staff. 'superadmin' was missing until 2026-09-24, so an unverified Admin
// promoted to Super Admin would have been locked out at its next sign-in
// (found while settling QA 2026-09-23, F4).
const kProvisionedStaffRoles = {'superadmin', 'admin', 'viewer'};

// One line per level, shown under the picker so the choice is not a guess.
// Admin and Lab Staff have the same permissions — the paper's "full-access
// administrators or staff" — and saying so is better than implying a
// hierarchy the code does not have (QA 2026-09-23, F4).
const kStaffRoleBlurbs = {
  'superadmin': 'Everything an Admin can do, plus managing these staff accounts.',
  'admin':      'Full day-to-day access: requests, returns, inventory, penalties.',
  'staff':      'The same day-to-day access as an Admin. The one difference: '
      'this account needs a verified email address to sign in.',
  'viewer':     'Can see everything, but cannot change anything.',
};
