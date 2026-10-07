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
| Files | Firebase Storage (equipment photos) |
| QR | `qr_flutter` (generation) + `mobile_scanner` (scanning) |

Authorization is enforced **server-side** in `firestore.rules` /
`storage.rules` (role-based: student, staff, admin, viewer; deny-by-default).
See `BACKEND_SETUP.md` for deployment, account provisioning, and the demo-mode
flag.

## Project layout

```
lib/
  main.dart            entry point (Firebase init)
  firstFile.dart       app code (services, session, all screens)
  firebase_options.dart
firestore.rules        Firestore security rules   ← deploy these
storage.rules          Storage security rules     ← deploy these
BACKEND_SETUP.md       backend setup + roles + demo mode
test/                  unit + widget tests (flutter test)
load_test.js           Firestore load/stress probe (node load_test.js)
```

## Running

```bash
flutter pub get
flutter run          # device/emulator with Google Play services
flutter test         # unit + widget tests, no Firebase needed
```

> ⚠️ `kDemoMode` in `lib/firstFile.dart` relaxes sign-up (any email, no
> verification) for demos. Set it to `false` for production builds.
