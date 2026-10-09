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
  static Future<Map<String, dynamic>> login(
      String identifier, String password, String role) async {
    try {
      if (role == 'student') {
        // Students sign in with their student number. Resolve it to an email via
        // the public lookup index — this works BEFORE authentication, unlike a
        // query on the protected `students` collection (see firestore.rules).
        final lookup =
            await _db.collection('student_lookup').doc(identifier).get();
        if (!lookup.exists) {
          return {'success': false, 'message': 'Student ID not found.'};
        }
        final email = lookup.data()!['email'] as String;
        await _auth.signInWithEmailAndPassword(email: email, password: password);
        final uid = _auth.currentUser!.uid;
        // Profile is read BEFORE the verification gate: the grandfather check
        // needs `created_at`, so the gate cannot run until the doc is in hand.
        final doc = await _db.collection('students').doc(uid).get();
        if (!doc.exists) {
          await _auth.signOut();
          return {'success': false, 'message': 'Student profile not found.'};
        }
        if (!kDemoMode &&
            !_isLegacyAccount(doc.data()) &&
            _auth.currentUser?.emailVerified != true) {
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
          final q = await _db
              .collection('staff')
              .where('email', isEqualTo: identifier)
              .limit(1)
              .get();
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
        final sRole = (staffData['role'] ?? 'staff').toString();
        if (!kDemoMode && sRole != 'admin' && sRole != 'viewer' &&
            !_isLegacyAccount(staffData) &&
            _auth.currentUser?.emailVerified != true) {
          await _auth.signOut();
          return {'success': false, 'message': 'email_not_verified', 'email': identifier};
        }

        return {'success': true, 'role': 'staff', 'user': {...staffData, 'staff_id': staffDocId}};
      }
    } on FirebaseAuthException catch (e) {
      String msg = 'Login failed.';
      if (e.code == 'wrong-password' || e.code == 'invalid-credential')
        msg = 'Incorrect password.';
      else if (e.code == 'user-not-found') msg = 'Account not found.';
      else if (e.code == 'too-many-requests')
        msg = 'Too many attempts. Try again later.';
      return {'success': false, 'message': msg};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  static Future<Map<String, dynamic>> registerStudent(
      Map<String, dynamic> data) async {
    final email    = data['email'] as String;
    final password = data['password'] as String;
    final name     = '${data['first_name']} ${data['last_name']}';
    final studentNumber = data['student_number'] as String;
    final lookupRef = _db.collection('student_lookup').doc(studentNumber);

    UserCredential? cred;
    var lookupWritten = false;
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

      // Step 2: Claim the student number. The security rules only allow
      // CREATE on student_lookup (never update), so if the number is already
      // taken this write is rejected by the server — a race-proof uniqueness
      // check. (The old read-then-check could let two simultaneous
      // registrations of the same number both pass.)
      try {
        await lookupRef.set({'email': email, 'uid': uid});
        lookupWritten = true;
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied') {
          await cred.user!.delete();
          return {'success': false, 'message': 'Student ID is already registered.'};
        }
        rethrow;
      }

      // Step 3: Save student profile to Firestore
      await _db.collection('students').doc(uid).set({
        'name':           name,
        'email':          email,
        'student_number': studentNumber,
        'course':         data['course'] ?? '',
        'year_level':     data['year_level'] ?? 1,
        'hold':           false,
        'hold_reason':    '',
        'created_at':     FieldValue.serverTimestamp(),
      });

      // Step 4: Sign out after registration so they go back to login screen
      await _auth.signOut();

      return {
        'success':    true,
        'message':    'Account created successfully.',
        'student_id': uid,
      };
    } catch (e) {
      // Roll back so a half-finished registration doesn't orphan an Auth
      // account or squat the student number (which would show "already
      // registered" forever with no working profile behind it).
      try { if (lookupWritten) await lookupRef.delete(); } catch (_) {}
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
  static Future<({int total, int available})> getEquipmentCounts() async {
    final col = _db.collection('equipment');
    final totalSnap = await col.count().get();
    final availSnap =
        await col.where('status', isEqualTo: 'Available').count().get();
    return (total: totalSnap.count ?? 0, available: availSnap.count ?? 0);
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

  static Future<Map<String, dynamic>> addEquipment(
      Map<String, dynamic> data) async {
    try {
      final name     = data['equipment_name'] as String;
      final category = data['category'] as String;
      final location = data['location'] ?? '';
      // Use a caller-supplied QR code when present so the code previewed during
      // registration matches what is stored; otherwise auto-generate one.
      final provided = (data['qr_code'] as String?)?.trim() ?? '';
      final prefix  = category.length >= 3
          ? category.substring(0, 3).toUpperCase()
          : category.toUpperCase();
      final suffix  = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
      final qrCode  = provided.isNotEmpty ? provided : '$prefix-$suffix';
      final ref = await _db.collection('equipment').add({
        'equipment_name': name,
        'category':       category,
        'location':       location,
        'qr_code':        qrCode,
        'status':         'Available',
        'courses':        (data['courses'] as List?)?.cast<String>() ?? [],
        'description':    data['description'] ?? '',
        'brand':          data['brand'] ?? '',
        'model':          data['model'] ?? '',
        'serial_number':  data['serial_number'] ?? '',
        // Photos are written separately by saveEquipmentPhoto once the document
        // exists and its id is known.
        'created_at':     FieldValue.serverTimestamp(),
      });
      return {
        'success':      true,
        'message':      'Equipment added successfully.',
        'equipment_id': ref.id,
        'qr_code':      qrCode,
      };
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  static Future<Map<String, dynamic>> updateEquipment(
      String equipmentId, Map<String, dynamic> data) async {
    try {
      await _db.collection('equipment').doc(equipmentId).update(data);
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
      String equipmentId, Uint8List raw) async {
    try {
      final encoded = await compute(_encodePhoto, raw);
      if (encoded == null) {
        return (thumb: null, error: 'That image could not be read.');
      }
      await _db.collection('equipment_photos').doc(equipmentId).set({
        'image':      Blob(encoded.full),
        'updated_at': FieldValue.serverTimestamp(),
      });
      await _db
          .collection('equipment')
          .doc(equipmentId)
          .update({'photo_thumb': Blob(encoded.thumb)});
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
  static Future<Map<String, dynamic>> borrowEquipment(
      Map<String, dynamic> data) async {
    try {
      final equipId = data['equipment_id'].toString();
      final sid     = data['student_id'].toString();

      // Read the student profile once — used for both the hold gate and the
      // program/course restriction below.
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

      // Check equipment is Available
      final eqDoc = await _db.collection('equipment').doc(equipId).get();
      if (!eqDoc.exists) {
        return {'success': false, 'message': 'Equipment not found.'};
      }
      final eqData = eqDoc.data() as Map<String, dynamic>;
      if (eqData['status'] != 'Available') {
        return {
          'success': false,
          'message': 'Equipment is currently ${eqData['status']}.'
        };
      }

      // ── Program / course restriction (Prof recommendation #1) ──
      // Equipment can be tagged with the programs allowed to borrow it. An empty
      // or absent list means the item is open to every program. Otherwise, a
      // student may only borrow it if their program is in the allowed list. This
      // is the authoritative gate — the catalog also hides restricted items, but
      // this stops a borrow even if the item is reached some other way.
      final allowedCourses =
          (eqData['courses'] as List?)?.map((c) => '$c').toList() ?? [];
      if (allowedCourses.isNotEmpty) {
        final studentCourse =
            '${stuData?['course'] ?? data['course'] ?? ''}';
        if (!allowedCourses.contains(studentCourse)) {
          return {
            'success': false,
            'course_restricted': true,
            'message': 'This equipment is reserved for '
                '${allowedCourses.map((c) => courseLabel(c)).join(', ')} '
                'students and is not available to your program'
                '${studentCourse.isNotEmpty ? ' (${courseLabel(studentCourse)})' : ''}.',
          };
        }
      }

      // Honour the student's requested return time, enforcing the same-day
      // 5:00 PM laboratory policy as the latest possible deadline.
      final now = DateTime.now();
      final dueDate =
          computeDueDate(now, DateTime.tryParse('${data['due_date'] ?? ''}'));

      final ref = await _db.collection('borrow_transactions').add({
        'student_id':     sid,
        'equipment_id':   equipId,
        'equipment_name': eqData['equipment_name'],
        'qr_code':        eqData['qr_code'],
        // Thumbnail copied onto the transaction so the borrower's list shows
        // the photo without a second read per row, and keeps showing the item
        // as it looked when borrowed. ~8 KB.
        if (eqData['photo_thumb'] != null) 'photo_thumb': eqData['photo_thumb'],
        'category':       eqData['category'] ?? '',
        'borrower_name':  data['borrower_name'] ?? '',
        'student_number': data['student_number'] ?? '',
        'subject':        data['subject'] ?? '',
        'quantity':       data['quantity'] ?? 1,
        'purpose':        data['purpose'] ?? '',
        'borrow_date':    FieldValue.serverTimestamp(),
        'due_date':       Timestamp.fromDate(dueDate),
        'return_date':    null,
        'status':         'Pending',
      });
      return {
        'success':        true,
        'message':        'Borrow request submitted successfully.',
        'transaction_id': ref.id,
      };
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }

  // Same-day 5:00 PM due-date policy: a requested time at or before 17:00 is
  // honoured (on today's date); anything later — or no request — clamps to
  // 17:00. Public and pure so the policy is unit-testable (see test/).
  static DateTime computeDueDate(DateTime now, DateTime? requested) {
    if (requested != null &&
        !(requested.hour > 17 ||
            (requested.hour == 17 && requested.minute > 0))) {
      return DateTime(
          now.year, now.month, now.day, requested.hour, requested.minute, 0);
    }
    return DateTime(now.year, now.month, now.day, 17, 0, 0);
  }

  // Equipment status to set when an item is returned in a given condition.
  // Public and pure so the mapping is unit-testable (see test/).
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
          'message': 'Multiple active loans found for this equipment. '
              'Please resolve them from the Requests screen.',
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
        'due_date': (data['due_date'] as Timestamp?)
                ?.toDate()
                .toIso8601String() ??
            '',
        'borrow_date': (data['borrow_date'] as Timestamp?)
                ?.toDate()
                .toIso8601String() ??
            '',
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
    final damageF   = _db
        .collection('damage_reports')
        .where('status', isEqualTo: 'Open')
        .count()
        .get();
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
        'pending_requests':    pending.length,
        'active_loans':        approved.length,
        'overdue_loans':       overdue,
        'total_equipment':     equip.total,
        'available_equipment': equip.available,
        'damage_reports':      damage.count ?? 0,
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
  static Stream<List<dynamic>> myBorrowingsStream() {
    final sid = Session.currentUser?['student_id']?.toString() ?? '';
    if (sid.isEmpty) return Stream.value(const []);
    return _db
        .collection('borrow_transactions')
        .where('student_id', isEqualTo: sid)
        .snapshots()
        .map((snap) => _mapTransactionDocs(snap.docs));
  }

  static Stream<List<dynamic>> requestsStream() => _db
      .collection('borrow_transactions')
      .snapshots()
      .map((snap) => _mapTransactionDocs(snap.docs));

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
        final equipId =
            (txDoc.data() as Map<String, dynamic>)['equipment_id'] as String;
        final eqRef = _db.collection('equipment').doc(equipId);

        if (action == 'approve') {
          final eqDoc = await tx.get(eqRef);
          final eqStatus = eqDoc.exists
              ? (eqDoc.data() as Map<String, dynamic>)['status']
              : null;
          if (eqStatus != 'Available') {
            return {
              'success': false,
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
        'reported_at': (data['reported_at'] as Timestamp?)
                ?.toDate()
                .toIso8601String() ??
            '',
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

  // Number of damage reports still needing attention (status == Open).
  // Counted server-side rather than by reading every damage report.
  static Future<int> openDamageReportCount() async {
    final snap = await _db
        .collection('damage_reports')
        .where('status', isEqualTo: 'Open')
        .count()
        .get();
    return snap.count ?? 0;
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
  static DateTime? _asDate(dynamic v) {
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
    var loans = 0, late = 0, overdue = 0, damages = 0;
    for (final t in txns) {
      final status = '${t['status'] ?? ''}';
      final due = _asDate(t['due_date']);
      if (status == 'Approved' || status == 'Returned') loans++;
      if (status == 'Returned') {
        final ret = _asDate(t['return_date']);
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
      'late': late,
      'overdue': overdue,
      'damages': damages,
      'rating': rating,
    };
  }

  // ── Update Profile ────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> updateProfile({
    required dynamic studentId,
    required String name,
    required String course,
    required int yearLevel,
  }) async {
    try {
      await _db.collection('students').doc('$studentId').update({
        'name':       name,
        'course':     course,
        'year_level': yearLevel,
      });
      return {'success': true, 'message': 'Profile updated successfully.'};
    } catch (e) {
      return {'success': false, 'message': friendlyError(e)};
    }
  }
}
