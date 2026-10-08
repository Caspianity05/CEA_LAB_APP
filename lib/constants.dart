// -----------------------------------------------------------------------------
// LabTrack - shared constants
//
// Extracted from firstFile.dart on 2026-08-03 as step 2 of the module split.
// The _k-prefixed names were library-private; they are public here because they
// are now read from several libraries. No values changed.
// -----------------------------------------------------------------------------

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
