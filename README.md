# LabTrack — CEA Laboratory Equipment Borrowing System

A QR code-integrated Android application for real-time laboratory equipment
borrowing and return monitoring, built for the College of Engineering and
Architecture (CEA) Laboratory at New Era University.

**BSIT Capstone Project** — Bello · Loterte · Duero

## What it does

- **Students** browse the equipment catalog (filtered by their program), submit
  borrow requests, track active/pending loans in real time, file damage
  reports, and see due-date / overdue alerts. Same-day borrowing with a
  5:00 PM return policy.
- **Lab staff** approve or reject requests, process returns by scanning the
  equipment's QR code, manage inventory (with photos and per-program
  restrictions), review damage reports, and place penalty holds on students.
- **Viewer accounts** (e.g. the supervising minister) see everything,
  read-only — enforced by security rules, not just the UI.

## Tech stack

| Layer | Technology |
|---|---|
| App | Flutter (Dart) — Android |
| Auth | Firebase Authentication (email/password + email verification) |
| Database | Cloud Firestore (real-time listeners for requests/borrowings) |
| Files | Cloud Firestore `Blob`s (equipment photos — no Cloud Storage, stays on the free Spark plan) |
| QR | `qr_flutter` (generation) + `mobile_scanner` (scanning) |

Authorization is enforced **server-side** in `firestore.rules`
(role-based: student, staff, admin, viewer; deny-by-default).
See `BACKEND_SETUP.md` for deployment, account provisioning, and the demo-mode
flag.

## Project layout

```
lib/
  main.dart            entry point (Firebase init)
  app.dart             root MaterialApp widget
  theme.dart           colours, text styles, NeuLogo
  constants.dart       courses, categories, statuses
  firebase_options.dart
  services/            api_service.dart (Firestore access), session.dart, notif_prefs.dart
  widgets/             common.dart (shared widgets)
  screens/
    auth/              splash, login, signup, legal
    student/           home, catalog, detail, borrow, my borrowings, damage
                       report, profile, edit profile, change password,
                       notifications, lab policies, help & FAQ, about
    staff/             dashboard, inventory, registration, requests, QR scan,
                       damage reports, penalties, students, student detail, reports
firestore.rules        Firestore security rules   ← deploy these
BACKEND_SETUP.md       backend setup + roles + demo mode
test/                  unit + widget tests (flutter test)
load_test.js           Firestore load/stress probe (node load_test.js)
```

Photos are stored in Cloud Firestore, not Cloud Storage, so the project stays on
the free Spark plan and there is no `storage.rules` to deploy.

## Running

```bash
flutter pub get
flutter run          # device/emulator with Google Play services
flutter test         # unit + widget tests, no Firebase needed
```

> `kDemoMode` in `lib/services/api_service.dart` is now **`false`** — sign-up
> requires an `@neu.edu.ph` address and a confirmed verification email. Accounts
> created before `kLegacyAccountCutoff` (2026-08-03) skip the verification gate,
> so the existing demo accounts still sign in.
