// -----------------------------------------------------------------------------
// LabTrack - Firebase data layer
//
// Extracted from firstFile.dart on 2026-08-03 as step 3 of the module split.
// Contains every Firestore/Auth call the app makes. Deliberately free of any
// Flutter UI types - no Widget, BuildContext, Color or Icons appear here.
//
// The demo-mode flag and its grandfather clause live here rather than in
// constants.dart because _isLegacyAccount is only ever used by login() and can
// stay library-private alongside it.
// -----------------------------------------------------------------------------

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image/image.dart' as img;

import '../constants.dart';
import 'session.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DEMO MODE — CLOSED as of 2026-08-02.
//
// While true, account sign-up accepted ANY email address (not just @neu.edu.ph)
// and the email-verification step was skipped, so one demo student per program
// could be made without real NEU mailboxes. Now false, so registration requires
// an @neu.edu.ph address and Firebase sends a confirmation link that must be
// clicked before the account can sign in. It does NOT affect the Firestore
// security rules — only these convenience gates in the app.
// ─────────────────────────────────────────────────────────────────────────────
const bool kDemoMode = false;

// ─────────────────────────────────────────────────────────────────────────────
// Grandfather clause for the accounts made while demo mode was open.
//
// Those accounts were never sent a verification link, so Firebase reports
// `emailVerified == false` for every one of them — and their addresses are not
// @neu.edu.ph mailboxes anyone can actually receive mail at. Without this,
// flipping kDemoMode to false would lock all of them out permanently.
//
// So: an account whose Firestore profile was created BEFORE this instant skips
// the verification gate. Anything created after it must verify, which is what
// closes sign-up to new dummy accounts. A profile with no `created_at` at all
// is also treated as pre-existing — those predate the field entirely.
//
// This only relaxes a client-side convenience gate; the security rules are
// unchanged and never trusted email verification in the first place.
// ─────────────────────────────────────────────────────────────────────────────
final DateTime kLegacyAccountCutoff = DateTime.utc(2026, 8, 3);

/// True if [profile] belongs to an account created before demo mode was closed.
bool _isLegacyAccount(Map<String, dynamic>? profile) {
  final ts = profile?['created_at'];
  if (ts is! Timestamp) return true; // missing/unset → predates the field
  return ts.toDate().isBefore(kLegacyAccountCutoff);
}

// One line of a borrow request: an item type ("Beaker 1000 mL"), how many
// units, and optionally the unit the student was looking at, reserved first.
typedef BorrowLine = ({String name, int quantity, String preferId});

// ─── Firebase Service ─────────────────────────────────────────────────────────
class ApiService {
  static final _auth = FirebaseAuth.instance;
  static final _db   = FirebaseFirestore.instance;

  // Convert any thrown error into a message that is safe to show users. Raw
  // exceptions (e.g. "[cloud_firestore/permission-denied] …") leak
  // implementation details, so map the common cases and keep the rest generic.
  static String friendlyError(Object e) {
    if (e is FirebaseAuthException) {
      return e.message ?? 'Authentication error. Please try again.';
    }
    if (e is FirebaseException) {
      switch (e.code) {
        case 'permission-denied':
          return 'You do not have permission to do that.';
        // Cloud Storage reports a rules refusal as 'unauthorized' rather than
        // 'permission-denied'.
        case 'unauthorized':
          return 'You do not have permission to do that. '
              'If this is a photo upload, check that the Storage rules are published.';
        case 'unauthenticated':
          return 'Your session has expired. Please sign in again.';
        case 'unavailable':
          return 'Cannot reach the server. Check your internet connection.';
        case 'deadline-exceeded':
          return 'The request timed out. Please try again.';
        default:
          return 'Something went wrong. Please try again.';
      }
    }
    if (e is SocketException) return 'No internet connection.';
    return 'Something went wrong. Please try again.';
  }

  // ── Auth ──────────────────────────────────────────────────────────────────

  // The e-mail verification gate, shared by login() and the splash screen's
  // session restore so the two can never disagree. True when the signed-in
  // user may proceed: demo mode, a superadmin/admin/viewer staff account
  // (provisioned by an administrator — kProvisionedStaffRoles), an account
  // predating kLegacyAccountCutoff, or a verified e-mail address.
  static bool passesVerificationGate(Map<String, dynamic>? profile,
      {bool isStaff = false}) {
    if (kDemoMode) return true;
    if (isStaff) {
      final sRole = (profile?['role'] ?? 'staff').toString();
      if (kProvisionedStaffRoles.contains(sRole)) return true;
    }
    if (_isLegacyAccount(profile)) return true;
    return _auth.currentUser?.emailVerified == true;
  }

  // A failed login must never leave anyone signed in. Sign-in can succeed
  // before a later step fails — e.g. a student account used on the Lab Staff
  // tab — and the splash screen restores whatever session is left behind on
  // the next launch, which used to skip the verification gate entirely
  // (QA 2026-09-19, H3).
  static Future<void> _signOutQuietly() async {
    try {
      if (_auth.currentUser != null) await _auth.signOut();
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> login(
      String identifier, String password, String role) async {
    try {
      if (role == 'student') {
        // The field is labelled "Student ID / Email", so both have to work. An
        // address used to be sent to the lookup index and bounce with "Student
        // ID not found." (QA 2026-09-19, M7); anything containing '@' is now
        // taken as the e-mail itself and skips the lookup.
        String email;
        if (identifier.contains('@')) {
          email = identifier;
        } else {
          // Students sign in with their student number. Resolve it to an email
          // via the public lookup index — this works BEFORE authentication,
          // unlike a query on the protected `students` collection (see
          // firestore.rules).
          final lookup =
              await _db.collection('student_lookup').doc(identifier).get();
          if (!lookup.exists) {
            return {'success': false, 'message': 'Student ID not found.'};
          }
          email = lookup.data()!['email'] as String;
        }
        await _auth.signInWithEmailAndPassword(email: email, password: password);
        final uid = _auth.currentUser!.uid;
        // Profile is read BEFORE the verification gate: the grandfather check
        // needs `created_at`, so the gate cannot run until the doc is in hand.
        final doc = await _db.collection('students').doc(uid).get();
        if (!doc.exists) {
          await _auth.signOut();
          return {'success': false, 'message': 'Student profile not found.'};
        }
        if (!passesVerificationGate(doc.data())) {
          await _auth.signOut();
          return {'success': false, 'message': 'email_not_verified', 'email': email};
        }
        final user = {...doc.data()!, 'student_id': uid};
        return {'success': true, 'role': 'student', 'user': user};
      } else {
        // Staff login with email
        await _auth.signInWithEmailAndPassword(
            email: identifier, password: password);
        final uid = _auth.currentUser!.uid;

        // Fetch Firestore doc first so we can check role before email check
        final snap = await _db.collection('staff').doc(uid).get();
        Map<String, dynamic> staffData;
        String staffDocId;
        if (!snap.exists) {
          final QuerySnapshot<Map<String, dynamic>> q;
          try {
            q = await _db
                .collection('staff')
                .where('email', isEqualTo: identifier)
                .limit(1)
                .get();
          } on FirebaseException catch (e) {
            // Only staff may query this collection, so a non-staff account
            // (e.g. a student on the Lab Staff tab) is refused here rather
            // than finding no match. Say so plainly instead of "permission".
            if (e.code != 'permission-denied') rethrow;
            await _auth.signOut();
            return {'success': false, 'message': 'Staff account not found.'};
          }
          if (q.docs.isEmpty) {
            await _auth.signOut();
            return {'success': false, 'message': 'Staff account not found.'};
          }
          staffData  = Map<String, dynamic>.from(q.docs.first.data());
          staffDocId = q.docs.first.id;
        } else {
          staffData  = Map<String, dynamic>.from(snap.data()!);
          staffDocId = uid;
        }

        // Admin / viewer accounts are provisioned by an administrator and skip
        // the email-verification gate; regular staff must still verify, unless
        // the account predates the closing of demo mode (see kLegacyAccountCutoff).
        if (!passesVerificationGate(staffData, isStaff: true)) {
          await _auth.signOut();
          return {'success': false, 'message': 'email_not_verified', 'email': identifier};
        }

        return {'success': true, 'role': 'staff', 'user': {...staffData, 'staff_id': staffDocId}};
      }
    } on FirebaseAuthException catch (e) {
      await _signOutQuietly();
      String msg = 'Login failed.';
      if (e.code == 'wrong-password' || e.code == 'invalid-credential')
        msg = 'Incorrect password.';
      else if (e.code == 'user-not-found') msg = 'Account not found.';
      else if (e.code == 'too-many-requests')
        msg = 'Too many attempts. Try again later.';
      return {'success': false, 'message': msg};
    } catch (e) {
      await _signOutQuietly();
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // Change the signed-in user's password. Firebase only accepts a password
  // change shortly after a sign-in, so re-authenticate with the current
  // password first — which is also the "current password is correct" check
  // the screen promises. (Until 2026-09-19 the screen only waited 700 ms and
  // showed a success dialog; nothing was ever changed — QA H1.)
  static Future<Map<String, dynamic>> changePassword(
      String currentPassword, String newPassword) async {
    final user  = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      return {'success': false, 'message': 'Your session has expired. Please sign in again.'};
    }
    try {
      await user.reauthenticateWithCredential(
          EmailAuthProvider.credential(email: email, password: currentPassword));
      await user.updatePassword(newPassword);
      return {'success': true, 'message': 'Password changed.'};
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'wrong-password':
        case 'invalid-credential':
          return {'success': false, 'message': 'Current password is incorrect.'};
        case 'weak-password':
          return {'success': false, 'message': 'New password is too weak.'};
        case 'too-many-requests':
          return {'success': false, 'message': 'Too many attempts. Try again later.'};
        case 'requires-recent-login':
          return {'success': false, 'message': 'Please sign out, sign in again, then retry.'};
        default:
          return {'success': false, 'message': e.message ?? 'Could not change password.'};
      }
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  static Future<Map<String, dynamic>> registerStudent(
      Map<String, dynamic> data) async {
    // One spelling of the address everywhere: Auth, the lookup and the
    // profile. The rules compare the stored address with the account's own
    // (firestore.rules), so a mixed-case entry must not reach them in two
    // different forms.
    final email    = (data['email'] as String).trim().toLowerCase();
    final password = data['password'] as String;
    final name     = '${data['first_name']} ${data['last_name']}';
    final studentNumber = data['student_number'] as String;
    final lookupRef = _db.collection('student_lookup').doc(studentNumber);

    UserCredential? cred;
    try {
      // Step 1: Create Firebase Auth user first
      try {
        cred = await _auth.createUserWithEmailAndPassword(
            email: email, password: password);
      } on FirebaseAuthException catch (e) {
        if (e.code == 'email-already-in-use')
          return {'success': false, 'message': 'Email is already registered.'};
        if (e.code == 'weak-password')
          return {'success': false, 'message': 'Password must be at least 6 characters.'};
        return {'success': false, 'message': e.message ?? 'Registration failed.'};
      }

      final uid = cred.user!.uid;

      // Send verification email before Firestore write (skipped in demo mode)
      if (!kDemoMode) await cred.user!.sendEmailVerification();

      // Step 2: Claim the student number AND save the profile, in one batch.
      // The rules accept a student_lookup entry only together with the
      // profile that carries the same number, so an account can hold one
      // number and no more (QA 2026-10-03, R1). Both writes land or neither
      // does, so there is no half-finished registration to roll back.
      //
      // The claim is still race-proof: the rules only allow CREATE on
      // student_lookup (never update), so if the number is already taken the
      // whole batch is rejected by the server. (The old read-then-check could
      // let two simultaneous registrations of the same number both pass.)
      final batch = _db.batch()
        ..set(lookupRef, {'email': email, 'uid': uid})
        ..set(_db.collection('students').doc(uid), {
          'name':           name,
          'email':          email,
          'student_number': studentNumber,
          'course':         data['course'] ?? '',
          'year_level':     data['year_level'] ?? 1,
          'hold':           false,
          'hold_reason':    '',
          'created_at':     FieldValue.serverTimestamp(),
        });
      try {
        await batch.commit();
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
        // Refused. The usual reason is a number someone already registered,
        // but the rules also check the profile itself, so only say "already
        // registered" when that is actually true.
        await cred.user!.delete();
        final taken = await lookupRef.get().then((d) => d.exists, onError: (_) => false);
        return {
          'success': false,
          'message': taken
              ? 'Student ID is already registered.'
              : 'Registration was refused. Please check your details and try again.',
        };
      }

      // Step 3: Sign out after registration so they go back to login screen
      await _auth.signOut();

      return {
        'success':    true,
        'message':    'Account created successfully.',
        'student_id': uid,
      };
    } catch (e) {
      // Roll back the Auth account so the same address can register again.
      // Firestore needs no clean-up: the batch wrote everything or nothing.
      try { await cred?.user?.delete(); } catch (_) {}
      return {'success': false, 'message': friendlyError(e)};
    }
  }
  static Future<Map<String, dynamic>> registerStaff(
    Map<String, dynamic> data) async {
  try {
    final email    = data['email'] as String;
    final password = data['password'] as String;
    final name     = data['name'] as String;
    final role     = data['role'] ?? 'staff';

    // Step 1: Create Firebase Auth account
    final cred = await _auth.createUserWithEmailAndPassword(
        email: email, password: password);

    final uid = cred.user!.uid;

    await cred.user!.sendEmailVerification();

    // Step 2: Save staff profile using UID as document ID
    await _db.collection('staff').doc(uid).set({
      'name':       name,
      'email':      email,
      'role':       role,
      'created_at': FieldValue.serverTimestamp(),
    });

    await _auth.signOut();

    return {'success': true, 'message': 'Staff account created.', 'staff_id': uid};
  } on FirebaseAuthException catch (e) {
    if (e.code == 'email-already-in-use')
      return {'success': false, 'message': 'Email is already registered.'};
    return {'success': false, 'message': e.message ?? 'Registration failed.'};
  } catch (e) {
    return {'success': false, 'message': friendlyError(e)};
  }
}
  static Future<Map<String, dynamic>> resendVerificationEmail(
      String email, String password) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(
          email: email, password: password);
      if (cred.user?.emailVerified == true) {
        await _auth.signOut();
        return {'success': false, 'message': 'Your email is already verified. Try signing in again.'};
      }
      await cred.user!.sendEmailVerification();
      await _auth.signOut();
      return {'success': true};
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'message': e.message ?? 'Failed to resend verification email.'};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // Send a Firebase password-reset email.
  static Future<Map<String, dynamic>> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
      return {'success': true};
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') {
        return {'success': false, 'message': 'No account found for that email.'};
      }
      if (e.code == 'invalid-email') {
        return {'success': false, 'message': 'Please enter a valid email address.'};
      }
      return {'success': false, 'message': e.message ?? 'Could not send reset email.'};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // End the session properly.
  //
  // `Session.clear()` on its own only drops the in-memory user — it leaves
  // `FirebaseAuth.instance.currentUser` set, and the splash screen restores
  // that on the next launch whenever "Remember me" is on (which is the
  // default). Signing out and relaunching would therefore drop straight back
  // into the account that just signed out — including a staff ADMIN account on
  // a shared lab phone. Always go through here.
  static Future<void> signOut() async {
    // Close every live stream first. A screen still on the widget tree (the
    // Requests tab, My Borrowings) would otherwise keep its listener open past
    // the sign-out, the rules would refuse it, and Firestore logged a
    // PERMISSION_DENIED warning (QA 2026-09-19 section 9; 2026-09-23, F6).
    await _closeLiveStreams();
    try {
      await _auth.signOut();
    } catch (_) {
      // Even if the network call fails, drop the local session so the UI
      // cannot keep acting as the signed-in user.
    }
    Session.clear();
  }

  // ── Equipment ─────────────────────────────────────────────────────────────
  static Future<List<dynamic>> getEquipment(
      {String search = '', String category = ''}) async {
    Query q = _db.collection('equipment').orderBy('equipment_name');
    final snap = await q.get();
    List<dynamic> items = snap.docs.map((d) {
      final data = d.data() as Map<String, dynamic>;
      return {...data, 'equipment_id': d.id};
    }).toList();
    if (search.isNotEmpty)
      items = items
          .where((e) => (e['equipment_name'] as String)
              .toLowerCase()
              .contains(search.toLowerCase()))
          .toList();
    if (category.isNotEmpty)
      items = items.where((e) => e['category'] == category).toList();
    return items;
  }

  // Cursor-paginated equipment, ordered by name. Firestore bills reads per
  // document, so pulling a screenful at a time keeps the cost of opening the
  // catalog flat no matter how large the inventory grows — getEquipment()
  // above reads the entire collection every call.
  //
  // Only the ordering is done server-side: the catalog's filters are a
  // multi-select category set, a case-insensitive substring search, and a
  // course rule that matches items with no course set, none of which Firestore
  // can express as a query. They stay on the client, over the loaded pages.
  static Future<
      ({
        List<Map<String, dynamic>> items,
        DocumentSnapshot? cursor,
        bool hasMore,
      })> getEquipmentPage({int limit = 20, DocumentSnapshot? startAfter}) async {
    Query q = _db.collection('equipment').orderBy('equipment_name').limit(limit);
    if (startAfter != null) q = q.startAfterDocument(startAfter);
    final snap = await q.get();
    final items = snap.docs
        .map((d) => {...d.data() as Map<String, dynamic>, 'equipment_id': d.id})
        .toList();
    return (
      items: items,
      cursor: snap.docs.isEmpty ? null : snap.docs.last,
      hasMore: snap.docs.length == limit,
    );
  }

  static Future<Map<String, dynamic>?> getEquipmentById(String id) async {
    if (id.isEmpty) return null;
    final doc = await _db.collection('equipment').doc(id).get();
    if (!doc.exists) return null;
    return {...doc.data() as Map<String, dynamic>, 'equipment_id': doc.id};
  }

  // Inventory header counts via aggregation queries: the server returns only
  // the number, billed per ~1000 documents scanned rather than per document
  // read. This keeps the summary accurate over the whole inventory while the
  // list below it is paginated.
  // `borrowed` is counted on its own rather than inferred as "everything that
  // is not Available": the Inventory header used to show total − available
  // under a "Borrowed" label, which silently folded in Under Repair and For
  // Disposal items and read 6 when 3 things were out (QA 2026-09-19, low #6).
  static Future<({int total, int available, int borrowed})>
      getEquipmentCounts() async {
    final col = _db.collection('equipment');
    final totalSnap = await col.count().get();
    final availSnap =
        await col.where('status', isEqualTo: 'Available').count().get();
    final borrowSnap =
        await col.where('status', isEqualTo: 'Borrowed').count().get();
    return (
      total:     totalSnap.count ?? 0,
      available: availSnap.count ?? 0,
      borrowed:  borrowSnap.count ?? 0,
    );
  }

  static Future<Map<String, dynamic>> getEquipmentByQr(String qrCode) async {
    final snap = await _db
        .collection('equipment')
        .where('qr_code', isEqualTo: qrCode)
        .limit(1)
        .get();
    if (snap.docs.isEmpty)
      return {'success': false, 'message': 'Equipment not found.'};
    final data = {
      ...snap.docs.first.data(),
      'equipment_id': snap.docs.first.id
    };
    return {'success': true, 'data': data};
  }

  // ── Registering equipment ─────────────────────────────────────────────────
  // Every physical unit is its own equipment record, with its own QR code and
  // status, because a loan, a return scan and a damage report are each about
  // one particular unit. A Quantity of N on Register Equipment therefore makes
  // N records named "<name> #1" … "<name> #N", the same shape as the
  // 2026-10-02 inventory import (Flask 500 mL #1 … #9). Until then the
  // Quantity box was validated and then thrown away: one record stood in for
  // the whole lot.
  //
  // It takes two calls so that what staff confirm is what gets stored:
  // planEquipmentUnits picks the names and QR codes for the preview, and
  // addEquipmentUnits writes exactly those.

  // Names for [quantity] new units of [base], given names already in the
  // inventory. Numbering carries on after the highest "<base> #n" there, so
  // registering three more flasks gives #10 … #12, never a second #1. A lone
  // unit with no numbered siblings keeps the plain name, as before. Numbers
  // are zero-padded to the width of the highest one (#01 … #10), as the import
  // did, and never narrower than the padding already in use.
  // Public and pure so it is unit-testable (see test/).
  static List<String> unitNames(
      String base, int quantity, Iterable<String> existing) {
    final prefix = '$base #';
    var highest = 0;
    var width = 1;
    for (final name in existing) {
      if (!name.startsWith(prefix)) continue;
      final digits = name.substring(prefix.length);
      if (!RegExp(r'^\d+$').hasMatch(digits)) continue;
      final n = int.tryParse(digits);
      if (n == null) continue;
      if (n > highest) highest = n;
      if (digits.length > width) width = digits.length;
    }
    if (quantity == 1 && highest == 0) return [base];
    final last = highest + quantity;
    if ('$last'.length > width) width = '$last'.length;
    return [
      for (var n = highest + 1; n <= last; n++)
        '$prefix${'$n'.padLeft(width, '0')}',
    ];
  }

  static String _qrPrefix(String category) => category.length >= 3
      ? category.substring(0, 3).toUpperCase()
      : category.toUpperCase();

  // [count] QR codes in the app's scheme: the category's first three letters
  // and the last six digits of the clock ([seed], in ms), stepping by one per
  // unit and skipping any code in [taken].
  // Public and pure so it is unit-testable (see test/).
  static List<String> qrCodesFor(
      String category, int count, int seed, Set<String> taken) {
    final prefix = _qrPrefix(category);
    var s = seed % 1000000;
    final codes = <String>[];
    while (codes.length < count) {
      final code = '$prefix-${'$s'.padLeft(6, '0')}';
      s = (s + 1) % 1000000;
      if (!taken.contains(code)) codes.add(code);
    }
    return codes;
  }

  // Picks the names and QR codes for registering [quantity] units of [name].
  // A clock-based code can land on one already in use (the import took runs
  // of consecutive codes) and a scan only ever finds the first match, so the
  // codes already in use just ahead of the clock are fetched and skipped.
  static Future<Map<String, dynamic>> planEquipmentUnits({
    required String name,
    required String category,
    required int quantity,
  }) async {
    try {
      final prefix = '$name #';
      final siblings = await _db
          .collection('equipment')
          .where('equipment_name', isGreaterThanOrEqualTo: prefix)
          .where('equipment_name', isLessThan: '$prefix')
          .get();
      final names = unitNames(name, quantity,
          siblings.docs.map((d) => '${d.data()['equipment_name']}'));

      final seed = DateTime.now().millisecondsSinceEpoch % 1000000;
      // Room to step past codes in use without leaving the checked stretch.
      final span = quantity + 1000;
      final taken = await _qrCodesInUse(_qrPrefix(category), seed, span);
      final codes = qrCodesFor(category, quantity, seed, taken);
      final lastStep =
          (int.parse(codes.last.split('-').last) - seed) % 1000000;
      if (lastStep >= span) {
        return {
          'success': false,
          'message': 'Could not find unused QR codes. Please try again.',
        };
      }
      return {
        'success': true,
        'units': <Map<String, String>>[
          for (var i = 0; i < quantity; i++)
            {'equipment_name': names[i], 'qr_code': codes[i]},
        ],
      };
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // The codes already in use from <prefix>-<from> through the next [span]
  // codes, wrapping past 999999. The digits are fixed-width, so text order is
  // number order and each stretch is a single range query.
  static Future<Set<String>> _qrCodesInUse(
      String prefix, int from, int span) async {
    String code(int n) => '$prefix-${'$n'.padLeft(6, '0')}';
    final to = from + span - 1;
    final stretches = to <= 999999
        ? [(from, to)]
        : [(from, 999999), (0, to - 1000000)];
    final taken = <String>{};
    for (final (lo, hi) in stretches) {
      final snap = await _db
          .collection('equipment')
          .where('qr_code', isGreaterThanOrEqualTo: code(lo))
          .where('qr_code', isLessThanOrEqualTo: code(hi))
          .get();
      taken.addAll(snap.docs.map((d) => '${d.data()['qr_code']}'));
    }
    return taken;
  }

  // Writes the units planned above, all sharing the details in [data]. Eight
  // to a batch: each write's rule check reads the caller's staff record twice,
  // and a batch may make at most 20 such reads. If a batch fails part-way, the
  // units already saved come back with the error so the caller can say how far
  // it got.
  static Future<Map<String, dynamic>> addEquipmentUnits(
      Map<String, dynamic> data, List<Map<String, String>> units) async {
    // The condition chosen at registration decides the starting status, so an
    // item registered as Under Repair / For Disposal is not immediately
    // borrowable (QA 2026-09-19, M1 — this used to be hard-coded Available).
    // 'Borrowed' is never a valid starting status: a brand-new item is not on
    // loan, so anything unrecognised falls back to Available.
    final condition = (data['condition'] as String?)?.trim() ?? '';
    final requested = (data['status'] as String?)?.trim() ?? '';
    final status = kStatuses.contains(requested) && requested != 'Borrowed'
        ? requested
        : equipmentStatusForCondition(condition);
    final saved = <Map<String, dynamic>>[];
    try {
      for (var i = 0; i < units.length; i += 8) {
        final batch = _db.batch();
        final part = <Map<String, dynamic>>[];
        for (final unit in units.skip(i).take(8)) {
          final ref = _db.collection('equipment').doc();
          batch.set(ref, {
            'equipment_name': unit['equipment_name'],
            'category':       data['category'],
            'location':       data['location'] ?? '',
            'qr_code':        unit['qr_code'],
            'status':         status,
            if (condition.isNotEmpty) 'condition': condition,
            'courses':        (data['courses'] as List?)?.cast<String>() ?? [],
            'description':    data['description'] ?? '',
            'brand':          data['brand'] ?? '',
            'model':          data['model'] ?? '',
            'serial_number':  data['serial_number'] ?? '',
            // The lab's Item Identification Number and acquisition date, as on
            // the custodian's inventory sheet (prof's comment, 2026-10-05). One
            // sheet line covers the whole lot, so every unit gets the same.
            'iin':            (data['iin'] as String?)?.trim() ?? '',
            if (data['date_acquired'] is DateTime)
              'date_acquired': Timestamp.fromDate(data['date_acquired'] as DateTime),
            // Photos are written separately by saveEquipmentPhotos once the
            // documents exist and their ids are known.
            'created_at':     FieldValue.serverTimestamp(),
            // Who added it, shown with the date added.
            'created_by':      Session.staffId,
            'created_by_name': Session.name,
          });
          part.add({...unit, 'equipment_id': ref.id});
        }
        await batch.commit();
        saved.addAll(part);
      }
      return {'success': true, 'units': saved, 'status': status};
    } catch (e) {
      return {
        'success': false,
        'units':   saved,
        'status':  status,
        'message': friendlyError(e),
      };
    }
  }

  static Future<Map<String, dynamic>> updateEquipment(
      String equipmentId, Map<String, dynamic> data) async {
    try {
      // An item that is out on an approved loan has to stay 'Borrowed'.
      // Setting it back to Available let staff approve a SECOND loan for the
      // same physical unit; the QR return then found two active loans and
      // refused to complete either, stranding both (QA 2026-09-19, M5).
      final status = data['status'] as String?;
      if (status != null && status != 'Borrowed') {
        // Single-field query (no composite index needed); filter in Dart.
        final snap = await _db
            .collection('borrow_transactions')
            .where('equipment_id', isEqualTo: equipmentId)
            .get();
        final active = snap.docs
            .where((d) => (d.data())['status'] == 'Approved')
            .toList();
        if (active.isNotEmpty) {
          final who = '${active.first.data()['borrower_name'] ?? ''}'.trim();
          return {
            'success': false,
            'on_loan': true,
            'message': 'This item is still out on loan'
                '${who.isEmpty ? '' : ' to $who'}. Mark it as returned from '
                'the Dashboard before changing its status.',
          };
        }
      }
      // Screens hand over a DateTime (or null to clear it); Firestore stores
      // a Timestamp.
      final fields = Map<String, dynamic>.from(data);
      final acquired = fields['date_acquired'];
      if (acquired is DateTime) {
        fields['date_acquired'] = Timestamp.fromDate(acquired);
      }
      await _db.collection('equipment').doc(equipmentId).update(fields);
      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // Permanently remove an equipment record. Blocked while the item is on an
  // active loan so history stays consistent. Completes the CRUD "Delete".
  static Future<Map<String, dynamic>> deleteEquipment(String equipmentId) async {
    try {
      final txSnap = await _db
          .collection('borrow_transactions')
          .where('equipment_id', isEqualTo: equipmentId)
          .get();
      final hasActive = txSnap.docs.any((d) {
        final s = d.data()['status'];
        return s == 'Approved' || s == 'Pending';
      });
      if (hasActive) {
        return {
          'success': false,
          'message': 'Cannot delete: this equipment has a pending or active loan.'
        };
      }
      await _db.collection('equipment').doc(equipmentId).delete();
      // Best-effort cleanup of the full-size photo; ignore if there is none.
      try {
        await _db.collection('equipment_photos').doc(equipmentId).delete();
      } catch (_) {}
      return {'success': true, 'message': 'Equipment deleted.'};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // ── Equipment photos ──────────────────────────────────────────────────────
  // Photos are kept in Firestore, not Cloud Storage: Storage requires the paid
  // Blaze plan, and this project stays on the free Spark plan. Each photo is
  // written twice —
  //   • `photo_thumb` (~192px) on the equipment document itself, so every list
  //     screen shows it with no extra read; a page of 20 costs roughly 160 KB;
  //   • a ~800px copy in equipment_photos/{equipmentId}, read only when the
  //     detail screen opens.
  // Firestore caps a document at 1 MiB and both sizes land far below that.
  static const int _thumbWidth = 192;
  static const int _fullWidth  = 800;

  // Runs on a background isolate via compute() — decoding a multi-megapixel
  // camera photo would otherwise stutter the UI.
  static ({Uint8List thumb, Uint8List full})? _encodePhoto(Uint8List raw) {
    final decoded = img.decodeImage(raw);
    if (decoded == null) return null;
    final thumb = img.copyResize(decoded, width: _thumbWidth);
    final full  = decoded.width > _fullWidth
        ? img.copyResize(decoded, width: _fullWidth)
        : decoded;
    return (
      thumb: Uint8List.fromList(img.encodeJpg(thumb, quality: 60)),
      full:  Uint8List.fromList(img.encodeJpg(full, quality: 70)),
    );
  }

  // Stores both sizes. Returns the thumbnail so the caller can show it at once,
  // or a message explaining what went wrong — a silent failure here would
  // leave equipment with no photo and give staff no hint of it.
  static Future<({Uint8List? thumb, String? error})> saveEquipmentPhoto(
          String equipmentId, Uint8List raw) =>
      saveEquipmentPhotos([equipmentId], raw);

  // The same photo on several records: the units of one registration share
  // it. Encoded once, then written four units to a batch (two writes each, and
  // each write's rule check makes two of the 20 reads a batch allows).
  static Future<({Uint8List? thumb, String? error})> saveEquipmentPhotos(
      List<String> equipmentIds, Uint8List raw) async {
    try {
      final encoded = await compute(_encodePhoto, raw);
      if (encoded == null) {
        return (thumb: null, error: 'That image could not be read.');
      }
      for (var i = 0; i < equipmentIds.length; i += 4) {
        final batch = _db.batch();
        for (final id in equipmentIds.skip(i).take(4)) {
          batch.set(_db.collection('equipment_photos').doc(id), {
            'image':      Blob(encoded.full),
            'updated_at': FieldValue.serverTimestamp(),
          });
          batch.update(_db.collection('equipment').doc(id),
              {'photo_thumb': Blob(encoded.thumb)});
        }
        await batch.commit();
      }
      return (thumb: encoded.thumb, error: null);
    } catch (e) {
      return (thumb: null, error: friendlyError(e));
    }
  }

  // Full-size photo for the detail screen. Null when none was uploaded.
  static Future<Uint8List?> getEquipmentPhoto(String equipmentId) async {
    if (equipmentId.isEmpty) return null;
    final doc = await _db.collection('equipment_photos').doc(equipmentId).get();
    if (!doc.exists) return null;
    final blob = doc.data()?['image'];
    return blob is Blob ? blob.bytes : null;
  }

  // ── Borrow / Return ───────────────────────────────────────────────────────
  // ── Borrowing by item type ────────────────────────────────────────────────
  // Students ask for an item TYPE and a quantity ("Beaker 1000 mL × 2"); the
  // app picks the units. These helpers are public and pure so they are
  // unit-testable (see test/).

  // "Beaker 1000 mL #3" → "Beaker 1000 mL". A name without a unit number is
  // a type of its own. A trailing "#<number>" is ALWAYS read as a unit number
  // (Register Equipment and the import name units that way), so a size must
  // not be written like one: "Sieve No. 200", not a lone "Sieve #200". The
  // lab's sheet already keeps sizes in their own column (checked 2026-10-05).
  static String baseNameOf(String name) =>
      name.trim().replaceFirst(RegExp(r'\s+#\d+$'), '');

  // The unit number in "Beaker 1000 mL #3" (3), or 0 for an unnumbered name.
  static int unitNumberOf(String name) {
    final m = RegExp(r'#(\d+)$').firstMatch(name.trim());
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  // Which [quantity] units of one type to reserve: Available ones only, the
  // unit the student was looking at ([preferId]) first, then by unit number.
  // Returns fewer than asked when not enough are free.
  static List<Map<String, dynamic>> pickUnits(
      List<Map<String, dynamic>> units, int quantity, {String preferId = ''}) {
    final free = units.where((u) => u['status'] == 'Available').toList()
      ..sort((a, b) {
        final ap = preferId.isNotEmpty && '${a['equipment_id']}' == preferId ? 0 : 1;
        final bp = preferId.isNotEmpty && '${b['equipment_id']}' == preferId ? 0 : 1;
        if (ap != bp) return ap.compareTo(bp);
        return unitNumberOf('${a['equipment_name']}')
            .compareTo(unitNumberOf('${b['equipment_name']}'));
      });
    return free.take(quantity).toList();
  }

  // The records of one request share their student and their server-stamped
  // borrow_date (they are written in one batch). Older one-item requests are
  // simply requests of one.
  static String requestKey(dynamic t) => '${t['student_id']}|${t['borrow_date']}';

  // [txns] grouped into requests, in order of first appearance (the lists
  // arrive newest first).
  static List<List<dynamic>> groupRequests(List<dynamic> txns) {
    final groups = <String, List<dynamic>>{};
    for (final t in txns) {
      groups.putIfAbsent(requestKey(t), () => []).add(t);
    }
    return groups.values.toList();
  }

  // "Beaker 1000 mL × 2, Flask 500 mL" for a request's records (or units).
  static String requestSummary(List<dynamic> records) {
    final counts = <String, int>{};
    for (final t in records) {
      final base = baseNameOf('${t['equipment_name'] ?? 'Equipment'}');
      counts[base] = (counts[base] ?? 0) + 1;
    }
    return counts.entries
        .map((e) => e.value > 1 ? '${e.key} × ${e.value}' : e.key)
        .join(', ');
  }

  // The item types a student can borrow right now, for the borrow form's
  // picker: every Available unit, grouped by type, with how many are free.
  // One read per available unit. At the lab's size (90 units on 2026-10-05)
  // that is simpler than paging a grouped list; if the inventory grows into
  // the thousands, keep a per-type count instead.
  static Future<List<Map<String, dynamic>>> getAvailableTypes() async {
    final snap = await _db
        .collection('equipment')
        .where('status', isEqualTo: 'Available')
        .get();
    final types = <String, Map<String, dynamic>>{};
    for (final d in snap.docs) {
      final data = d.data();
      final base = baseNameOf('${data['equipment_name'] ?? ''}');
      if (base.isEmpty) continue;
      final t = types.putIfAbsent(base, () => {
            'name':     base,
            'category': data['category'] ?? '',
            'count':    0,
          });
      t['count'] = (t['count'] as int) + 1;
      // The first unit with a photo stands for the type.
      if (t['photo_thumb'] == null && data['photo_thumb'] != null) {
        t['photo_thumb'] = data['photo_thumb'];
      }
    }
    return types.values.toList()
      ..sort((a, b) =>
          '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
  }

  // A borrow request: one or more item types, each with a quantity. Each unit
  // reserved becomes its own borrow_transactions record (a loan, a return scan
  // and a damage report are each about one unit), and all of them are written
  // in ONE batch, so they share the server-stamped borrow_date. That shared
  // timestamp, with the student, is what groups them back into one request on
  // the student and staff screens (see requestKey) — no new field, so the
  // security rules are unchanged.
  //
  // Students used to pick one numbered unit and a quantity that reserved
  // nothing: "Qty 3" on Beaker #1 left #2 and #3 Available while they were
  // physically out (prof's comment on a confusing flow, 2026-10-05).
  static Future<Map<String, dynamic>> borrowEquipment(
      Map<String, dynamic> data, List<BorrowLine> lines) async {
    try {
      final sid = data['student_id'].toString();

      // Read the student profile once — used for both the hold gate and the
      // identity fields written below.
      Map<String, dynamic>? stuData;
      if (sid.isNotEmpty) {
        final stuDoc = await _db.collection('students').doc(sid).get();
        if (stuDoc.exists) stuData = stuDoc.data();
      }

      // ── Penalty / hold gate (Prof recommendation #3) ──
      // A student on hold (overdue or staff-imposed penalty) cannot borrow.
      if (stuData?['hold'] == true) {
        return {
          'success': false,
          'on_hold': true,
          'message': (stuData?['hold_reason'] ?? '').toString().isNotEmpty
              ? stuData!['hold_reason']
              : 'Your borrowing privileges are on hold. Please settle the '
                  'penalty with the laboratory staff before borrowing again.',
        };
      }

      // The student's own records, read once for both the overdue gate and the
      // duplicate check below (these used to be two identical queries).
      final mine = sid.isEmpty
          ? <Map<String, dynamic>>[]
          : (await _db
                  .collection('borrow_transactions')
                  .where('student_id', isEqualTo: sid)
                  .get())
              .docs
              .map((d) => d.data())
              .toList();

      // ── Overdue gate (QA 2026-09-19, M6) ──
      // The Home banner ("…before borrowing again") and the Lab Policies screen
      // ("Late returns lose borrowing privileges") both promise this, but until
      // now only a staff-placed hold blocked anything, so a student could sit
      // on two overdue items and keep borrowing. Holding an item past its due
      // date now closes new loans until it is back.
      {
        final late = overdueLoans(mine);
        if (late.isNotEmpty) {
          final names =
              late.map((t) => '${t['equipment_name'] ?? 'an item'}').toSet();
          final listed = names.take(3).join(', ');
          final one = late.length == 1;
          return {
            'success': false,
            'overdue': true,
            'overdue_count': late.length,
            'message': 'You have ${late.length} overdue '
                '${one ? 'item' : 'items'} ($listed'
                '${names.length > 3 ? ', …' : ''}). Please return '
                '${one ? 'it' : 'them'} to the laboratory before borrowing '
                'again.',
          };
        }
      }

      final wanted = lines.where((l) => l.quantity > 0).toList();
      if (wanted.isEmpty) {
        return {'success': false, 'message': 'Add at least one item to borrow.'};
      }
      final total = wanted.fold<int>(0, (n, l) => n + l.quantity);
      if (total > kMaxUnitsPerRequest) {
        return {
          'success': false,
          'message': 'At most $kMaxUnitsPerRequest items per request. Send '
              'the rest as a second request.',
        };
      }

      // ── One pending request per item type per student (QA 2026-09-19,
      // low #3; per type since 2026-10-05) ──
      // Tapping Submit twice, or coming back to the form later, used to file a
      // second Pending request for the same thing, and staff saw the same
      // student queued twice. A student cannot withdraw a request themselves —
      // the rules only let staff update a transaction — so the duplicate had to
      // be rejected by hand.
      final pendingTypes = mine
          .where((t) => t['status'] == 'Pending')
          .map((t) => baseNameOf('${t['equipment_name'] ?? ''}'))
          .toSet();
      for (final l in wanted) {
        if (pendingTypes.contains(l.name)) {
          return {
            'success': false,
            'duplicate': true,
            'message': 'You already have a pending request for ${l.name}. '
                'Please wait for laboratory staff to act on it.',
          };
        }
      }

      // Reserve the units: for each type, its Available units, the one the
      // student was looking at first, then by unit number (pickUnits).
      final picked = <Map<String, dynamic>>[];
      for (final l in wanted) {
        final snap = await _db
            .collection('equipment')
            .where('equipment_name', isGreaterThanOrEqualTo: l.name)
            .where('equipment_name', isLessThan: '${l.name}')
            .get();
        final units = [
          for (final d in snap.docs)
            if (baseNameOf('${d.data()['equipment_name'] ?? ''}') == l.name)
              {...d.data(), 'equipment_id': d.id},
        ];
        final chosen = pickUnits(units, l.quantity, preferId: l.preferId);
        if (chosen.length < l.quantity) {
          return {
            'success': false,
            'message': chosen.isEmpty
                ? '${l.name} is no longer available.'
                : 'Only ${chosen.length} ${l.name} available right now. '
                    'Lower the quantity, or try again later.',
          };
        }
        picked.addAll(chosen);
      }

      // NOTE (2026-09-20): the program/course restriction that used to sit here
      // was removed by decision — any student may borrow any item. The
      // `courses` field is kept and still shown (catalog badge, Equipment
      // Detail, the staff registration picker), but it is advisory now: it says
      // which programs an item is intended for, and no longer gates a borrow.
      // The catalog's "My program only / Show all" chip is likewise only a
      // convenience filter, which is all it ever was.
      //
      // This also closes QA probe P06 — a student editing their own course can
      // no longer reach anything they could not reach already.

      // Honour the student's requested return time, enforcing the same-day
      // 5:00 PM laboratory policy as the latest possible deadline.
      final now = DateTime.now();
      final dueDate =
          computeDueDate(now, DateTime.tryParse('${data['due_date'] ?? ''}'));

      // One batch: every record gets the same borrow_date, which is what ties
      // them together as one request. At most kMaxUnitsPerRequest writes, each
      // checked by the rules with two document reads (the student's profile
      // and the unit), inside a batch's limit of 20.
      final batch = _db.batch();
      for (final u in picked) {
        batch.set(_db.collection('borrow_transactions').doc(), {
          'student_id':     sid,
          'equipment_id':   u['equipment_id'],
          'equipment_name': u['equipment_name'],
          'qr_code':        u['qr_code'],
          // Thumbnail copied onto the transaction so the borrower's list shows
          // the photo without a second read per row, and keeps showing the
          // item as it looked when borrowed. ~8 KB.
          if (u['photo_thumb'] != null) 'photo_thumb': u['photo_thumb'],
          'category':       u['category'] ?? '',
          // Identity comes from the student's own profile, never from form
          // input: staff read these on every request, penalty and hold screen,
          // and a typed-in name/ID let a student file under a forged identity
          // (QA 2026-09-19, H5). The form values are only a fallback for a
          // profile that could not be read.
          'borrower_name':  stuData?['name'] ?? data['borrower_name'] ?? '',
          'student_number': stuData?['student_number'] ?? data['student_number'] ?? '',
          'subject':        data['subject'] ?? '',
          // One unit per record; the request's size is how many records
          // share its borrow_date.
          'quantity':       1,
          'purpose':        data['purpose'] ?? '',
          'borrow_date':    FieldValue.serverTimestamp(),
          'due_date':       Timestamp.fromDate(dueDate),
          'return_date':    null,
          'status':         'Pending',
        });
      }
      try {
        await batch.commit();
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
        // The rules re-check that every unit is still Available, so the
        // usual cause is someone else taking one in the last few seconds.
        return {
          'success': false,
          'message': 'The request was refused. One of the items may have '
              'just been taken. Please try again.',
        };
      }
      return {
        'success': true,
        'message': 'Borrow request submitted successfully.',
        'count':   picked.length,
        'summary': requestSummary(picked),
      };
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // Same-day 5:00 PM due-date policy: a requested time at or before 17:00 is
  // honoured (on today's date); anything later — or no request — clamps to
  // 17:00. Public and pure so the policy is unit-testable (see test/).
  //
  // A requested time that has already passed is not a deadline at all, so it
  // falls back to the 17:00 default instead of being stored as-is. The form
  // refuses one up front with a clear message; this is the backstop that keeps
  // a loan from being overdue the instant it is approved (QA 2026-09-19, M3).
  static DateTime computeDueDate(DateTime now, DateTime? requested) {
    if (requested != null &&
        !(requested.hour > 17 ||
            (requested.hour == 17 && requested.minute > 0))) {
      final sameDay = DateTime(
          now.year, now.month, now.day, requested.hour, requested.minute, 0);
      if (sameDay.isAfter(now)) return sameDay;
    }
    return DateTime(now.year, now.month, now.day, 17, 0, 0);
  }

  // Equipment status for a given condition. Used both when an item is returned
  // and when one is registered, so a "For Disposal" item is never borrowable
  // whichever door it came through. Public and pure so the mapping is
  // unit-testable (see test/).
  static String equipmentStatusForCondition(String condition) {
    switch (condition) {
      case 'Damaged':
      case 'Under Repair':
        return 'Under Repair';
      case 'For Disposal':
        return 'For Disposal';
      default:
        return 'Available';
    }
  }

  // Return a loan by its transaction id. Runs in a Firestore transaction so the
  // transaction record and the equipment status are updated atomically.
  static Future<Map<String, dynamic>> returnEquipment(
      dynamic transactionId, String condition) async {
    try {
      final txRef = _db.collection('borrow_transactions').doc('$transactionId');
      return await _db.runTransaction((tx) async {
        final txDoc = await tx.get(txRef);
        if (!txDoc.exists) {
          return {'success': false, 'message': 'Transaction not found.'};
        }
        final data = txDoc.data() as Map<String, dynamic>;
        if (data['status'] == 'Returned') {
          return {'success': false, 'message': 'This item was already returned.'};
        }
        // Only an active loan can be returned. A stale list could otherwise
        // "return" a request that was rejected meanwhile, freeing an item
        // that is out on someone else's loan.
        if (data['status'] != 'Approved') {
          return {
            'success': false,
            'message': 'This request is ${data['status'] ?? 'unknown'}, not an '
                'active loan. Refresh to see the latest.'
          };
        }
        final equipId = data['equipment_id'] as String;
        tx.update(txRef, {
          'status':             'Returned',
          'return_date':        FieldValue.serverTimestamp(),
          'condition_returned': condition,
          // Audit trail: which staff member processed this return.
          'returned_by':        Session.staffId,
          'returned_by_name':   Session.name,
        });
        tx.update(_db.collection('equipment').doc(equipId),
            {'status': equipmentStatusForCondition(condition)});
        return {'success': true, 'message': 'Equipment returned successfully.'};
      });
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // Return a loan by scanning the equipment's QR code. Looks up the active
  // (Approved) loan for that equipment, then returns it atomically. This is the
  // flagship staff return workflow — previously it passed an equipment id to
  // returnEquipment (which expects a transaction id) and silently failed.
  static Future<Map<String, dynamic>> returnEquipmentByQr(
      String equipmentId, String condition) async {
    try {
      // Single-field query (no composite index needed); filter in Dart.
      final snap = await _db
          .collection('borrow_transactions')
          .where('equipment_id', isEqualTo: equipmentId)
          .get();
      final active = snap.docs
          .where((d) => (d.data())['status'] == 'Approved')
          .toList();
      if (active.isEmpty) {
        return {
          'success': false,
          'message': 'No active loan found for this equipment.'
        };
      }
      if (active.length > 1) {
        // Data inconsistency — one physical item should never have two
        // Approved loans. Surface it instead of silently returning one.
        return {
          'success': false,
          // The Requests screen has no return action — only the Dashboard's
          // Active Loans list does (QA 2026-09-19, M5).
          'message': 'Multiple active loans found for this equipment. Please '
              'return them one at a time from the Dashboard\'s Active Loans.',
        };
      }
      final activeDoc = active.first;
      final result = await returnEquipment(activeDoc.id, condition);
      if (result['success'] == true) {
        final d = activeDoc.data();
        result['student_id']     = d['student_id'] ?? '';
        result['borrower_name']  = d['borrower_name'] ?? d['student_number'] ?? '';
        result['student_number'] = d['student_number'] ?? '';
        result['transaction_id'] = activeDoc.id;
      }
      return result;
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // ── Transactions ──────────────────────────────────────────────────────────
  // A stored date as an ISO-8601 string, or '' when the field is missing or is
  // not a Timestamp. Every list maps all of its documents through this, and the
  // old `as Timestamp?` cast threw on a value of any other type — one such
  // record stopped the whole list from loading (QA 2026-10-03). The rules now
  // refuse those values on create; this keeps any that exist from doing harm.
  // Public and pure so it is unit-testable (see test/).
  static String isoDate(dynamic v) =>
      v is Timestamp ? v.toDate().toIso8601String() : '';

  // Shared doc → map conversion for borrow transactions (timestamps to ISO
  // strings, doc id in, newest first). Used by both the one-shot getters and
  // the live streams below.
  static List<dynamic> _mapTransactionDocs(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final results = docs.map((d) {
      final data = d.data();
      return {
        ...data,
        'transaction_id': d.id,
        'due_date':    isoDate(data['due_date']),
        'borrow_date': isoDate(data['borrow_date']),
      };
    }).toList();

    // Sort by borrow_date descending in Dart — no composite index needed
    results.sort((a, b) {
      final aDate = DateTime.tryParse('${a['borrow_date']}') ?? DateTime(2000);
      final bDate = DateTime.tryParse('${b['borrow_date']}') ?? DateTime(2000);
      return bDate.compareTo(aDate);
    });
    return results;
  }

  static Future<List<dynamic>> getMyBorrowings(
      {dynamic studentId = 0, String studentNumber = ''}) async {
    final sid = Session.currentUser?['student_id']?.toString() ?? '';
    if (sid.isEmpty) return [];
    final snap = await _db
        .collection('borrow_transactions')
        .where('student_id', isEqualTo: sid)
        .get();
    return _mapTransactionDocs(snap.docs);
  }

  static Future<List<dynamic>> getRequests({String status = ''}) async {
    Query<Map<String, dynamic>> q = _db.collection('borrow_transactions');
    if (status.isNotEmpty && status != 'All') {
      q = q.where('status', isEqualTo: status);
    }
    final snap = await q.get();
    return _mapTransactionDocs(snap.docs);
  }

  // Staff dashboard summary.
  //
  // Anything that is only ever shown as a number is counted server-side with an
  // aggregation query, which is billed per ~1000 documents scanned rather than
  // per document read. Only the pending and approved transactions are fetched
  // as documents, because the dashboard lists them — and both are naturally
  // small (items currently requested or out on loan), unlike the collections
  // they used to be filtered out of. This screen previously read the whole of
  // equipment, borrow_transactions, damage_reports and students on every open
  // and after every approve/reject.
  static Future<
      ({
        Map<String, dynamic> stats,
        List<dynamic> pending,
        List<dynamic> approved,
      })> getDashboardData() async {
    // All issued before any is awaited, so they run concurrently.
    final equipF    = getEquipmentCounts();
    final pendingF  = getRequests(status: 'Pending');
    final approvedF = getRequests(status: 'Approved');
    final damageF   = openDamageReportCount();
    final studentsF = _db.collection('students').count().get();
    final heldF     = _db
        .collection('students')
        .where('hold', isEqualTo: true)
        .count()
        .get();

    final equip    = await equipF;
    final pending  = await pendingF;
    final approved = await approvedF;
    final damage   = await damageF;
    final students = await studentsF;
    final held     = await heldF;

    final now = DateTime.now();
    final overdue = approved.where((e) {
      final due = DateTime.tryParse('${e['due_date']}'.replaceAll(' ', 'T'));
      return due != null && due.isBefore(now);
    }).length;

    return (
      stats: {
        // Requests, not records: one request can hold several units.
        'pending_requests':    groupRequests(pending).length,
        'active_loans':        approved.length,
        'overdue_loans':       overdue,
        'total_equipment':     equip.total,
        'available_equipment': equip.available,
        'damage_reports':      damage,
        'total_students':      students.count ?? 0,
        'held_students':       held.count ?? 0,
      },
      pending: pending,
      approved: approved,
    );
  }

  // Transactions from a cutoff date onward. borrow_transactions is the one
  // collection that grows without bound — equipment and students plateau, but
  // every borrow adds a row forever — so the reports screen scopes itself to a
  // period instead of reading the entire history on every open. The inequality
  // is on a single field, so Firestore's automatic index covers it.
  static Future<List<dynamic>> getRequestsSince(DateTime cutoff) async {
    final snap = await _db
        .collection('borrow_transactions')
        .where('borrow_date', isGreaterThanOrEqualTo: Timestamp.fromDate(cutoff))
        .get();
    return _mapTransactionDocs(snap.docs);
  }

  static Future<int> damageReportCount() async {
    final snap = await _db.collection('damage_reports').count().get();
    return snap.count ?? 0;
  }

  // ── Live streams (real-time UI) ───────────────────────────────────────────
  // Firestore pushes changes as they happen, so screens built on these update
  // by themselves — a student sees an approval the moment staff taps it, with
  // no pull-to-refresh.
  //
  // Every live stream goes through _untilSignOut, so signOut() can end them all
  // before the account goes away. A closed stream simply stops: the screen
  // keeps its last data until the login page replaces it.
  static final Set<Future<void> Function()> _liveStreams = {};

  static Stream<T> _untilSignOut<T>(Stream<T> source) {
    late final StreamController<T> out;
    StreamSubscription<T>? sub;
    Future<void> close() async {
      _liveStreams.remove(close);
      final s = sub;
      sub = null;
      await s?.cancel();
      if (!out.isClosed) await out.close();
    }

    out = StreamController<T>(
      onListen: () {
        _liveStreams.add(close);
        sub = source.listen(out.add, onError: out.addError, onDone: close);
      },
      onCancel: close,
    );
    return out.stream;
  }

  static Future<void> _closeLiveStreams() async {
    final live = _liveStreams.toList();
    _liveStreams.clear();
    await Future.wait(live.map((close) => close()));
  }

  static Stream<List<dynamic>> myBorrowingsStream() {
    final sid = Session.currentUser?['student_id']?.toString() ?? '';
    if (sid.isEmpty) return Stream.value(const []);
    return _untilSignOut(_db
        .collection('borrow_transactions')
        .where('student_id', isEqualTo: sid)
        .snapshots()
        .map((snap) => _mapTransactionDocs(snap.docs)));
  }

  // The staff Requests tab's Pending and Approved lists: naturally small, so
  // they are listened to directly. This used to listen to the WHOLE
  // borrow_transactions collection, which grows forever; after a busy
  // semester every open of the tab would have cost thousands of reads against
  // the free plan's 50,000 a day.
  static Stream<List<dynamic>> requestsStream() => _untilSignOut(_db
      .collection('borrow_transactions')
      .where('status', whereIn: ['Pending', 'Approved'])
      .snapshots()
      .map((snap) => _mapTransactionDocs(snap.docs)));

  // The Requests tab's "All" list: everything from the last [days] days, the
  // same window as Reports. A single-field inequality, so Firestore's
  // automatic index covers it.
  static Stream<List<dynamic>> recentRequestsStream({int days = 90}) {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return _untilSignOut(_db
        .collection('borrow_transactions')
        .where('borrow_date', isGreaterThanOrEqualTo: Timestamp.fromDate(cutoff))
        .snapshots()
        .map((snap) => _mapTransactionDocs(snap.docs)));
  }

  // Approve or reject a borrow request. Runs in a transaction so that, on
  // approval, the equipment is only locked to Borrowed if it is still Available
  // — preventing two staff from approving the same item (double-booking).
  static Future<Map<String, dynamic>> updateRequestStatus(
      dynamic transactionId, String action, {String reason = ''}) async {
    try {
      final txRef = _db.collection('borrow_transactions').doc('$transactionId');
      return await _db.runTransaction((tx) async {
        final txDoc = await tx.get(txRef);
        if (!txDoc.exists) {
          return {'success': false, 'message': 'Transaction not found.'};
        }
        final txData = txDoc.data() as Map<String, dynamic>;

        // Only a request that is still Pending can be decided. Staff lists can
        // be stale (the Dashboard's is a one-shot read), and without this a
        // second phone could Deny a request another staff member had already
        // approved — the loan became Rejected while the item stayed Borrowed
        // with no loan behind it (QA 2026-09-19, H4).
        final current = (txData['status'] ?? '').toString();
        if (current != 'Pending') {
          final by = current == 'Approved'
              ? '${txData['approved_by_name'] ?? ''}'
              : current == 'Rejected'
                  ? '${txData['rejected_by_name'] ?? ''}'
                  : '';
          return {
            'success': false,
            'already_decided': true,
            'message': 'This request was already ${current.toLowerCase()}'
                '${by.isNotEmpty ? ' by $by' : ''}.',
          };
        }

        final equipId = txData['equipment_id'] as String;
        final eqRef = _db.collection('equipment').doc(equipId);

        if (action == 'approve') {
          final eqDoc = await tx.get(eqRef);
          final eqStatus = eqDoc.exists
              ? (eqDoc.data() as Map<String, dynamic>)['status']
              : null;
          if (eqStatus != 'Available') {
            return {
              'success': false,
              // approveRequest() takes this as its cue to offer the request
              // another free unit of the same type.
              'unavailable': true,
              'equipment_name': txData['equipment_name'] ?? '',
              'message':
                  'Equipment is no longer available (${eqStatus ?? 'missing'}).'
            };
          }
          tx.update(txRef, {
            'status': 'Approved',
            // Audit trail: which staff member approved this request.
            'approved_by': Session.staffId,
            'approved_by_name': Session.name,
            'approved_at': FieldValue.serverTimestamp(),
          });
          tx.update(eqRef, {'status': 'Borrowed'});
          return {'success': true, 'message': 'Request approved.'};
        } else {
          tx.update(txRef, {
            'status': 'Rejected',
            'rejected_by': Session.staffId,
            'rejected_by_name': Session.name,
            'rejected_at': FieldValue.serverTimestamp(),
            if (reason.trim().isNotEmpty) 'reject_reason': reason.trim(),
          });
          return {'success': true, 'message': 'Request rejected.'};
        }
      });
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // Approve one record of a request. If the unit it reserved was taken
  // meanwhile (two students can ask for the same type at once, and a student
  // cannot see the other's pending request), approve it with another free
  // unit of the same type instead of failing: the student asked for "a
  // beaker", not for beaker #1.
  static Future<Map<String, dynamic>> approveRequest(String txId) async {
    final first = await updateRequestStatus(txId, 'approve');
    if (first['success'] == true || first['unavailable'] != true) return first;
    try {
      final base = baseNameOf('${first['equipment_name'] ?? ''}');
      if (base.isEmpty) return first;
      final snap = await _db
          .collection('equipment')
          .where('equipment_name', isGreaterThanOrEqualTo: base)
          .where('equipment_name', isLessThan: '$base')
          .get();
      final candidates = pickUnits([
        for (final d in snap.docs)
          if (baseNameOf('${d.data()['equipment_name'] ?? ''}') == base)
            {...d.data(), 'equipment_id': d.id},
      ], snap.docs.length);
      for (final unit in candidates) {
        final res = await _approveAs(txId, unit);
        // Done, or another staff member decided it meanwhile.
        if (res['success'] == true || res['retry'] != true) return res;
      }
      return {
        'success': false,
        'message': 'No $base is available any more. Reject the request, or '
            'approve it once one is returned.',
      };
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // Approve record [txId] with [unit] in place of the unit it reserved, in one
  // transaction: still Pending, and the new unit still Available.
  static Future<Map<String, dynamic>> _approveAs(
      String txId, Map<String, dynamic> unit) {
    final txRef = _db.collection('borrow_transactions').doc(txId);
    final eqRef = _db.collection('equipment').doc('${unit['equipment_id']}');
    return _db.runTransaction((tx) async {
      final txDoc = await tx.get(txRef);
      final txData = txDoc.data();
      if (txData == null) {
        return {'success': false, 'message': 'Transaction not found.'};
      }
      if (txData['status'] != 'Pending') {
        return {
          'success': false,
          'already_decided': true,
          'message': 'This request was already ${'${txData['status']}'.toLowerCase()}.',
        };
      }
      final eqDoc = await tx.get(eqRef);
      if (eqDoc.data()?['status'] != 'Available') {
        return {'success': false, 'retry': true};
      }
      final e = eqDoc.data()!;
      tx.update(txRef, {
        'equipment_id':   eqRef.id,
        'equipment_name': e['equipment_name'],
        'qr_code':        e['qr_code'],
        'category':       e['category'] ?? '',
        'photo_thumb':    e['photo_thumb'] ?? FieldValue.delete(),
        'status':           'Approved',
        'approved_by':      Session.staffId,
        'approved_by_name': Session.name,
        'approved_at':      FieldValue.serverTimestamp(),
      });
      tx.update(eqRef, {'status': 'Borrowed'});
      return {
        'success': true,
        'message': 'Approved with ${e['equipment_name']} (the unit first '
            'reserved was taken).',
      };
    });
  }

  // Approve or reject every record of one request. Returns how many went
  // through and the first refusal, if any.
  static Future<Map<String, dynamic>> decideRequest(
      List<String> txIds, String action, {String reason = ''}) async {
    var done = 0;
    String? firstError;
    for (final id in txIds) {
      final res = action == 'approve'
          ? await approveRequest(id)
          : await updateRequestStatus(id, 'reject', reason: reason);
      if (res['success'] == true) {
        done++;
      } else {
        firstError ??= '${res['message'] ?? 'Action failed.'}';
      }
    }
    return {
      'success': firstError == null,
      'done':    done,
      'total':   txIds.length,
      'message': firstError == null
          ? null
          : done == 0
              ? firstError
              : '$done of ${txIds.length} done. $firstError',
    };
  }

  // ── Damage Report ─────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> submitDamageReport(
      Map<String, dynamic> data) async {
    try {
      final ref = await _db.collection('damage_reports').add({
        ...data,
        'status':      'Open',
        'reported_at': FieldValue.serverTimestamp(),
      });
      return {
        'success':   true,
        'message':   'Damage report submitted successfully.',
        'report_id': ref.id,
      };
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // Fetch damage reports for staff review (newest first). Sorted in Dart to
  // avoid requiring a composite index.
  static Future<List<dynamic>> getDamageReports({String status = ''}) async {
    final snap = await _db.collection('damage_reports').get();
    final results = snap.docs.map((d) {
      final data = d.data();
      return {
        ...data,
        'report_id': d.id,
        'reported_at': isoDate(data['reported_at']),
      };
    }).where((r) {
      if (status.isEmpty || status == 'All') return true;
      return (r['status'] ?? 'Open') == status;
    }).toList();
    results.sort((a, b) {
      final ad = DateTime.tryParse('${a['reported_at']}') ?? DateTime(2000);
      final bd = DateTime.tryParse('${b['reported_at']}') ?? DateTime(2000);
      return bd.compareTo(ad);
    });
    return results;
  }

  // Number of damage reports still needing attention.
  //
  // Counted as everything minus the two triaged states, NOT as
  // `where('status', isEqualTo: 'Open')`. A Firestore equality filter cannot
  // match a document that has no `status` field at all, and reports created
  // before triage started stamping `status: 'Open'` have none — so the old
  // query returned 0 while the Damage Reports screen listed those same reports
  // as "Open" (it defaults a missing status to Open, as does the filter in
  // getDamageReports). The dashboard and the list disagreed on live data.
  //
  // Subtracting is what matches the UI: `whereNotIn` would not work either,
  // because a missing field never satisfies an inequality. The triage
  // vocabulary is closed — Open / Reviewed / Resolved — so this is exact.
  // Still counted server-side; three aggregations are billed per ~1000
  // documents scanned, not per document read.
  static Future<int> openDamageReportCount() async {
    final col = _db.collection('damage_reports');
    final totalF    = col.count().get();
    final resolvedF = col.where('status', isEqualTo: 'Resolved').count().get();
    final reviewedF = col.where('status', isEqualTo: 'Reviewed').count().get();
    final total    = (await totalF).count ?? 0;
    final resolved = (await resolvedF).count ?? 0;
    final reviewed = (await reviewedF).count ?? 0;
    final open = total - resolved - reviewed;
    return open < 0 ? 0 : open;
  }

  // Update a damage report's triage status (Open → Reviewed / Resolved) and
  // optionally set the related equipment's condition in the same pass.
  static Future<Map<String, dynamic>> updateDamageReport(
      String reportId, String status, {String? equipmentId, String? equipmentStatus}) async {
    try {
      await _db.collection('damage_reports').doc(reportId).update({
        'status': status,
        'reviewed_at': FieldValue.serverTimestamp(),
      });
      if (equipmentId != null && equipmentId.isNotEmpty && equipmentStatus != null) {
        await _db.collection('equipment').doc(equipmentId)
            .update({'status': equipmentStatus});
      }
      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // ── Borrowing holds / penalties (Prof recommendation #3) ────────────────────
  // Place or lift a hold on a student. While on hold, the student cannot submit
  // new borrow requests and sees a penalty alert.
  static Future<Map<String, dynamic>> setStudentHold(
      String studentId, bool hold, {String reason = ''}) async {
    try {
      await _db.collection('students').doc(studentId).update({
        'hold': hold,
        'hold_reason': hold ? reason : '',
        'hold_at': hold ? FieldValue.serverTimestamp() : null,
      });
      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // Students currently under a staff-imposed hold.
  static Future<List<dynamic>> getHeldStudents() async {
    final snap = await _db
        .collection('students')
        .where('hold', isEqualTo: true)
        .get();
    return snap.docs.map((d) => {...d.data(), 'student_id': d.id}).toList();
  }

  // Re-read a single student profile (used to refresh the live hold flag).
  static Future<Map<String, dynamic>?> getStudent(String studentId) async {
    final doc = await _db.collection('students').doc(studentId).get();
    if (!doc.exists) return null;
    return {...doc.data()!, 'student_id': doc.id};
  }

  // All students (staff directory), sorted by name and optionally filtered by
  // name or student number. Firestore has no substring search, so we fetch and
  // filter in Dart — fine at a lab's scale. Staff-only: the security rules only
  // let a signed-in staff member read the students collection.
  static Future<List<dynamic>> getStudents({String search = ''}) async {
    final snap = await _db.collection('students').get();
    var items =
        snap.docs.map((d) => {...d.data(), 'student_id': d.id}).toList();
    items.sort((a, b) => '${a['name'] ?? ''}'
        .toLowerCase()
        .compareTo('${b['name'] ?? ''}'.toLowerCase()));
    final q = search.trim().toLowerCase();
    if (q.isNotEmpty) {
      items = items.where((s) {
        final name = '${s['name'] ?? ''}'.toLowerCase();
        final number = '${s['student_number'] ?? ''}'.toLowerCase();
        return name.contains(q) || number.contains(q);
      }).toList();
    }
    return items;
  }

  // A single student's borrow transactions (newest first) for the staff
  // student-detail view. Reuses the shared transaction mapper.
  static Future<List<dynamic>> getStudentTransactions(String studentId) async {
    if (studentId.isEmpty) return [];
    final snap = await _db
        .collection('borrow_transactions')
        .where('student_id', isEqualTo: studentId)
        .get();
    return _mapTransactionDocs(snap.docs);
  }

  // Parse a transaction date field that may be an ISO string (borrow/due, as
  // mapped) or a raw Firestore Timestamp (return_date isn't pre-converted).
  // Public because the student Home screen needs the same parsing to work out
  // how old an alert card is, and screens do not import cloud_firestore.
  static DateTime? asDate(dynamic v) {
    if (v == null) return null;
    if (v is Timestamp) return v.toDate();
    return DateTime.tryParse('$v'.replaceAll(' ', 'T'));
  }

  // Summarises a student's borrowing behaviour into counts + a rating, so staff
  // can decide at a glance whether to trust or hold them. Pure (takes an
  // optional [now] for testability). Counts:
  //   • loans   — approved or returned transactions (actual lends)
  //   • late    — returned after the due date
  //   • overdue — still out and past due right now
  //   • damages — returned in a damaged / repair / disposal condition
  // Rating: Good (no issues) → Fair (1–2) → Watch (3+).
  static Map<String, dynamic> studentReliability(List<dynamic> txns,
      {DateTime? now}) {
    final ref = now ?? DateTime.now();
    var loans = 0, late = 0, overdue = 0, damages = 0, active = 0;
    for (final t in txns) {
      final status = '${t['status'] ?? ''}';
      final due = asDate(t['due_date']);
      if (status == 'Approved' || status == 'Returned') loans++;
      if (status == 'Approved') active++;
      if (status == 'Returned') {
        final ret = asDate(t['return_date']);
        if (due != null && ret != null && ret.isAfter(due)) late++;
        final cond = '${t['condition_returned'] ?? ''}';
        if (cond == 'Damaged' ||
            cond == 'Under Repair' ||
            cond == 'For Disposal') {
          damages++;
        }
      } else if (status == 'Approved') {
        if (due != null && due.isBefore(ref)) overdue++;
      }
    }
    final flags = late + overdue + damages;
    final rating = flags == 0 ? 'Good' : (flags <= 2 ? 'Fair' : 'Watch');
    return {
      'loans': loans,
      'active': active,
      'late': late,
      'overdue': overdue,
      'damages': damages,
      'rating': rating,
    };
  }

  // Aggregates a reporting period's transactions into the numbers the staff
  // Reports screen shows. Pure (takes an optional [now]) so the arithmetic is
  // unit-testable (see test/).
  //
  // What counts as a borrowing is the whole point here, and it used to be wrong
  // (QA 2026-09-19, M2):
  //   • borrowings   — Approved or Returned only. A Pending request is not a
  //     loan yet and a Rejected one never became one, so neither is counted and
  //     neither can rank in Most Borrowed. (A rejected-only item used to place
  //     second.) Same definition as studentReliability's `loans`.
  //   • onTimeRate   — returns made on or before the due date, over the number
  //     of RETURNS. The old formula was returns ÷ every request and never once
  //     compared a return date with a due date, so it sank when a request was
  //     filed and rose when one was rejected.
  //   • overdue      — still out (Approved) and past due right now.
  static Map<String, dynamic> reportMetrics(List<dynamic> txns,
      {DateTime? now}) {
    final ref = now ?? DateTime.now();
    var borrowings = 0, returned = 0, onTime = 0, overdue = 0;
    final Map<String, int> perItem = {};
    for (final t in txns) {
      final status = '${t['status'] ?? ''}';
      if (status != 'Approved' && status != 'Returned') continue;
      borrowings++;
      final name = '${t['equipment_name'] ?? 'Unknown'}';
      perItem[name] = (perItem[name] ?? 0) + 1;
      final due = asDate(t['due_date']);
      if (status == 'Returned') {
        returned++;
        final ret = asDate(t['return_date']);
        // A return with no recorded date cannot be shown to be late, so it is
        // not held against the student.
        if (due == null || ret == null || !ret.isAfter(due)) onTime++;
      } else if (due != null && due.isBefore(ref)) {
        overdue++;
      }
    }
    final sorted = perItem.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {
      'borrowings':   borrowings,
      'returned':     returned,
      'onTime':       onTime,
      'overdue':      overdue,
      'onTimeRate':   returned > 0 ? onTime / returned * 100 : 0.0,
      'mostBorrowed': Map<String, int>.fromEntries(sorted.take(4)),
    };
  }

  // Loans a student still has out past their due date. Pure so the overdue
  // borrowing gate can be unit-tested (see test/ and borrowEquipment).
  static List<dynamic> overdueLoans(List<dynamic> txns, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    return txns.where((t) {
      if ('${t['status'] ?? ''}' != 'Approved') return false;
      final due = asDate(t['due_date']);
      return due != null && due.isBefore(ref);
    }).toList();
  }

  // ── Update Profile ────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> updateProfile({
    required String studentId,
    required String name,
    required String course,
    required int yearLevel,
  }) async {
    if (studentId.isEmpty) {
      return {'success': false, 'message': 'Your session has expired. Please sign in again.'};
    }
    try {
      await _db.collection('students').doc(studentId).update({
        'name':       name,
        'course':     course,
        'year_level': yearLevel,
      });
      return {'success': true, 'message': 'Profile updated successfully.'};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // The staff side's one self-service write. `staff/{uid}` is otherwise closed
  // to the client (firestore.rules), so this changes the display name and
  // nothing else: role and email stay with whoever provisioned the account.
  //
  // `staffId` is the staff DOCUMENT id, which is normally the caller's Auth
  // UID. Login has a legacy fallback that finds the doc by its `email` field
  // when the id is something else (api_service.dart, login → staff branch);
  // for such an account the rules refuse the write, because the uid does not
  // match the document. Say so plainly rather than "permission denied".
  static Future<Map<String, dynamic>> updateStaffName({
    required String staffId,
    required String name,
  }) async {
    if (staffId.isEmpty) {
      return {'success': false, 'message': 'Your session has expired. Please sign in again.'};
    }
    try {
      await _db.collection('staff').doc(staffId).update({'name': name});
      return {'success': true, 'message': 'Profile updated successfully.'};
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        return {
          'success': false,
          'message': 'This staff account cannot be renamed from the app. '
              'Ask an administrator to change it.',
        };
      }
      return {'success': false, 'message': friendlyError(e)};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // The staff directory behind the superadmin's Staff Accounts screen. Any
  // staff member may read this collection (firestore.rules), so the read is not
  // gated here — the screen that opens it is.
  static Future<List<Map<String, dynamic>>> getStaffList() async {
    final snap = await _db.collection('staff').get();
    final list = snap.docs.map((d) => {...d.data(), 'staff_id': d.id}).toList();
    list.sort((a, b) =>
        '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
    return list;
  }

  // The signed-in staff member's own document, live, for the staff portal to
  // follow access-level changes (QA 2026-09-23, F2). The rules let an account
  // read its own staff document whatever its level, so this stays readable
  // for as long as the session lasts. Null means the server confirmed the
  // document is gone; a "missing" served from the offline cache proves
  // nothing, so it is skipped rather than reported.
  static Stream<Map<String, dynamic>?> staffSelfStream(String staffId) =>
      _untilSignOut(_db
          .collection('staff')
          .doc(staffId)
          .snapshots()
          .where((s) => s.exists || !s.metadata.isFromCache)
          .map((s) => s.exists ? s.data() : null));

  // A superadmin editing ANOTHER staff member: display name, access level, or
  // both. The rules refuse it for everyone else, and refuse it on your own
  // document — a superadmin cannot change its own role, which is what stops the
  // last one demoting itself and leaving the system with no senior account.
  static Future<Map<String, dynamic>> updateStaffMember({
    required String staffId,
    String? name,
    String? role,
  }) async {
    if (staffId.isEmpty) {
      return {'success': false, 'message': 'That staff account is missing an id.'};
    }
    if (staffId == Session.staffId) {
      return {
        'success': false,
        'message': 'Change your own name in My Profile. Your own access level '
            'can only be changed by another super admin.',
      };
    }
    final patch = <String, dynamic>{};
    if (name != null) patch['name'] = name;
    if (role != null) patch['role'] = role;
    if (patch.isEmpty) return {'success': false, 'message': 'Nothing to change.'};
    try {
      await _db.collection('staff').doc(staffId).update(patch);
      return {'success': true, 'message': 'Staff account updated.'};
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        return {
          'success': false,
          'message': 'Only a super admin can change another staff account.',
        };
      }
      return {'success': false, 'message': friendlyError(e)};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }
}

// Pulls the stored thumbnail out of an equipment (or transaction) record.
// Firestore hands back a Blob; anything else means no photo. Takes dynamic so
// call sites reading from List<dynamic> need no casts.
Uint8List? photoThumbOf(dynamic record) {
  if (record is! Map) return null;
  final v = record['photo_thumb'];
  return v is Blob ? v.bytes : null;
}
