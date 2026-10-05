# LabTrack — Backend Setup & Security

This note covers the Firebase setup the app now depends on: security rules,
staff/admin/viewer accounts, and the data fields added for the penalty/hold and
damage-review features.

> Project ID: **cea-lab-system**

---

## 1. Deploy the security rules

The repo now contains real rules (previously the database was in open/test
mode). Deploy them before the defense:

```bash
# one-time, if the CLI isn't installed
npm install -g firebase-tools
firebase login

# from the project root (where firebase.json lives)
firebase deploy --only firestore:rules,storage
```

- `firestore.rules` — collection-level authorization (students, staff,
  equipment, borrow_transactions, damage_reports, student_lookup).
- `storage.rules` — equipment images: signed-in users read; only non-viewer
  staff write.

You can also paste the file contents into **Firebase Console → Firestore →
Rules** and **Storage → Rules** and click *Publish*.

---

## 2. Roles

A staff account is a document in the **`staff`** collection keyed by the user's
Auth UID, with a `role` field:

| role     | can view | can approve / edit / delete / scan-return |
|----------|:--------:|:-----------------------------------------:|
| `admin`  | ✅       | ✅                                        |
| `staff`  | ✅       | ✅                                        |
| `viewer` | ✅       | ❌ (read-only — e.g. Sir Owen)            |

`admin` and `viewer` accounts skip email verification; `staff` must verify.

### Create the view-only account (Sir Owen)

Accounts are provisioned out-of-band (the app never writes the `staff`
collection — see rules). Two options:

**A. Firebase Console (simplest)**
1. **Authentication → Users → Add user** → email + password. Copy the **UID**.
2. **Firestore → `staff` →** add document with **Document ID = that UID**:
   ```
   name:  "Ed Owen P. Gutierrez"
   email: "owen@neu.edu.ph"
   role:  "viewer"
   created_at: (server timestamp)
   ```
3. Sign in on the Staff tab — the dashboard shows a **VIEW ONLY** badge and all
   write actions (approve, edit, delete, scan-return, holds) are hidden.

Repeat with `role: "admin"` (or `"staff"`) for the lab staff accounts.

**B. From code** — `ApiService.registerStaff({name,email,password,role})` exists
for seeding from a throwaway script; it is intentionally not exposed in the UI
because creating a user from the client signs you in as that new user.

---

## 2b. Demo mode (creating dummy students per program)

To demo the "equipment per program/course" feature you can create one student
per program. A flag in `lib/firstFile.dart` makes this painless:

```dart
const bool kDemoMode = true;   // ⚠️ set to false before the final defense
```

While `kDemoMode == true`:
- Sign-up accepts **any** email (not just `@neu.edu.ph`), e.g. `ce@demo.com`.
- **Email verification is skipped**, so a new student can sign in immediately.

It does **not** touch the Firestore security rules — only those two app-side
convenience gates.

**To create the demo students:** run the app → **Sign Up** → fill in name, a
student number in `##-#####-###` format (unique per student), any email, pick a
**Course/Program**, set a password. Repeat per program:

| Student #     | Email         | Program |
|---------------|---------------|---------|
| 26-00001-001  | ce@demo.com   | CE      |
| 26-00002-001  | me@demo.com   | ME      |
| 26-00003-001  | ece@demo.com  | ECE     |
| 26-00004-001  | arch@demo.com | Arch    |

Then, as staff, tag equipment with programs (**Inventory → Add/Edit Equipment →
"Available to Courses"**), leaving a few items untagged (they show to all
programs). Log in as each student to show the catalog filtering by program.

> **Before the final defense:** set `kDemoMode = false` and rebuild, so the
> app re-enforces NEU-email + verification (matches the paper's scope).

## 3. Data fields added

These are created automatically by the app going forward; listed here so the
data dictionary stays accurate.

- **students**: `hold` (bool), `hold_reason` (string), `hold_at` (timestamp) —
  borrowing penalty/hold.
- **borrow_transactions**: `reject_reason` (string, optional) — shown to the
  student; `condition_returned` already existed.
- **damage_reports**: `status` ('Open' | 'Reviewed' | 'Resolved'),
  `reviewed_at` (timestamp).
- **student_lookup** *(new collection)*: doc id = student number,
  `{ email, uid }`. Public-read index so a student can sign in with their
  student number (the `students` collection itself is now locked).

### Backfill for students registered *before* this change

Older student accounts won't have a `student_lookup` doc, so they couldn't sign
in by student number. Either re-register the test students, or run this once in
the Firebase Console (**Firestore → Rules Playground isn't needed — use a small
script** or add docs manually):

```
student_lookup / <student_number>  →  { email: <their email>, uid: <their UID> }
```

New registrations create this automatically.

---

## 4. Quick verification checklist

- [ ] Rules deployed (`firebase deploy --only firestore:rules,storage`).
- [ ] At least one `admin`/`staff` account and one `viewer` account seeded.
- [ ] Register a new student → confirm a `student_lookup` doc appears.
- [ ] Student login by student number works.
- [ ] Viewer login shows **VIEW ONLY** and no action buttons.
- [ ] Approve a request, then scan its QR to return it → status flips to
      Returned and equipment back to Available.
- [ ] Mark a scanned return as *Damaged* → damage report appears under
      **Dashboard → Damage**, and a hold is placed on the borrower.
- [ ] A held student sees the penalty banner and cannot submit a new request.
