import 'dart:io';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';

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
  static String _friendlyError(Object e) {
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
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
    return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
    }
  }

  static Future<Map<String, dynamic>> updateEquipment(
      String equipmentId, Map<String, dynamic> data) async {
    try {
      await _db.collection('equipment').doc(equipmentId).update(data);
      return {'success': true};
    } catch (e) {
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return (thumb: null, error: _friendlyError(e));
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
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
      return {'success': false, 'message': _friendlyError(e)};
    }
  }
}

// ─── Shared constants ─────────────────────────────────────────────────────────
// Engineering programs/courses offered by CEA. Equipment can be tagged with the
// programs allowed to borrow it (Prof recommendation #1 — categorize by program).
// The short code is what gets stored on the student/equipment records; the full
// program name (see _kCourseNames) is what we show in the UI.
const _kCourses = ['CE', 'ME', 'ECE', 'EE', 'IE', 'Arch'];

// Human-readable program names, keyed by the stored course code.
const _kCourseNames = {
  'CE':   'Civil Engineering',
  'ME':   'Mechanical Engineering',
  'ECE':  'Electronics Engineering',
  'EE':   'Electrical Engineering',
  'IE':   'Industrial Engineering',
  'Arch': 'Architecture',
};

// Friendly label for a course code, e.g. 'CE' → 'Civil Engineering'.
// Falls back to the raw code for any legacy/unknown value.
String courseLabel(String code) => _kCourseNames[code] ?? code;

// Equipment categories — single source of truth shared by the catalog, inventory
// filter, registration and edit screens so the lists never drift apart.
const _kCategories = [
  'Electronics', 'Optics', 'Measurement', 'Tools',
  'Microcontroller', 'Safety', 'Other',
];

// Equipment availability / condition statuses.
const _kStatuses = ['Available', 'Borrowed', 'Under Repair', 'For Disposal'];

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

// ─── Notification preferences ────────────────────────────────────────────────
// Persisted in shared_preferences and honoured by the student dashboard's
// notification cards (previously the settings toggles were cosmetic — they
// were never saved and nothing read them).
class NotifPrefs {
  static bool approved        = true;
  static bool rejected        = true;
  static bool dueSoon         = true;
  static bool overdue         = true;
  static bool returnConfirmed = true;
  static bool damageUpdate    = false;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    approved        = p.getBool('notif_approved')  ?? true;
    rejected        = p.getBool('notif_rejected')  ?? true;
    dueSoon         = p.getBool('notif_due_soon')  ?? true;
    overdue         = p.getBool('notif_overdue')   ?? true;
    returnConfirmed = p.getBool('notif_return')    ?? true;
    damageUpdate    = p.getBool('notif_damage')    ?? false;
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('notif_approved', approved);
    await p.setBool('notif_rejected', rejected);
    await p.setBool('notif_due_soon', dueSoon);
    await p.setBool('notif_overdue', overdue);
    await p.setBool('notif_return', returnConfirmed);
    await p.setBool('notif_damage', damageUpdate);
  }
}

// ─── App Entry ───────────────────────────────────────────────────────────────
// (The real main() lives in lib/main.dart — this library only exports the app.)

class LabBorrowApp extends StatelessWidget {
  const LabBorrowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LabTrack',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const SplashScreen(),
    );
  }
}

// ─── Shared Widgets ───────────────────────────────────────────────────────────

class StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  const StatusBadge({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

IconData equipmentIcon(String category) {
  switch (category.toLowerCase()) {
    case 'electronics':     return Icons.electric_bolt_rounded;
    case 'tools':           return Icons.build_rounded;
    case 'measurement':     return Icons.straighten_rounded;
    case 'optics':          return Icons.remove_red_eye_rounded;
    case 'microcontroller': return Icons.memory_rounded;
    default:                return Icons.science_outlined;
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

// Equipment photo thumbnail. Students rely on the photo to confirm they are
// requesting — and being handed — the right item, so every list that names a
// piece of equipment should show it. Falls back to a category icon when no
// photo was uploaded or the bytes cannot be decoded.
class EquipmentThumb extends StatelessWidget {
  final Uint8List? bytes;
  final String category;
  final Color color;
  final double size;
  const EquipmentThumb({
    super.key,
    required this.bytes,
    required this.category,
    required this.color,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    final radius = size / 4;
    final fallback = Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(equipmentIcon(category), color: color, size: size / 2),
    );
    final data = bytes;
    if (data == null || data.isEmpty) return fallback;
    // Decode straight to the display size rather than the stored 192px: a list
    // of these otherwise holds full-resolution bitmaps in memory.
    final cachePx =
        (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.memory(
        data,
        width: size, height: size, fit: BoxFit.cover,
        cacheWidth: cachePx,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionHeader({super.key, required this.title, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.textDark)),
        if (action != null)
          GestureDetector(
            onTap: onAction,
            child: Text(action!,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.accent,
                    fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}

// ─── Splash Screen ────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _ctrl.forward();
    Future.delayed(const Duration(seconds: 2), _checkSession);
  }

  void _goLogin() {
    if (!mounted) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  Future<void> _checkSession() async {
    if (!mounted) return;
    try {
      final firebaseUser = FirebaseAuth.instance.currentUser;

      // Respect the "Remember me" choice. If it was off (or there's no session),
      // go straight to login — and sign out any lingering session so it isn't
      // silently restored.
      final prefs = await SharedPreferences.getInstance();
      final remember = prefs.getBool('remember_me') ?? true;
      if (firebaseUser == null || !remember) {
        if (firebaseUser != null && !remember) {
          await FirebaseAuth.instance.signOut();
        }
        _goLogin();
        return;
      }

      final uid = firebaseUser.uid;
      final db  = FirebaseFirestore.instance;
      const limit = Duration(seconds: 8); // never hang on the splash

      // Try to restore as student
      final studentDoc =
          await db.collection('students').doc(uid).get().timeout(limit);
      if (!mounted) return;
      if (studentDoc.exists) {
        Session.set({...studentDoc.data()!, 'student_id': uid}, 'student');
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => const StudentHomeScreen()));
        return;
      }

      // Try to restore as staff
      final staffDoc =
          await db.collection('staff').doc(uid).get().timeout(limit);
      if (!mounted) return;
      if (staffDoc.exists) {
        Session.set({...staffDoc.data()!, 'staff_id': uid}, 'staff');
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => const AdminDashboardScreen()));
        return;
      }

      // Auth token exists but no Firestore profile — sign out cleanly.
      await FirebaseAuth.instance.signOut();
      _goLogin();
    } catch (_) {
      // Any failure (offline, timeout, permission, etc.) → fall back to login
      // so the app never gets stuck on the splash screen.
      _goLogin();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      body: FadeTransition(
        opacity: _fade,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppTheme.primaryDark, AppTheme.primary],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo
                Container(
                  width: 100, height: 100,
                  decoration: BoxDecoration(
                    color: const Color(0x1AFFFFFF),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                        color: const Color(0x33FFFFFF), width: 1.5),
                  ),
                  child: const Icon(Icons.science_rounded,
                      color: AppTheme.accent, size: 52),
                ),
                const SizedBox(height: 24),
                // App name
                const Text('LabTrack',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2)),
                const SizedBox(height: 10),
                // Full system title
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    'Mobile Equipment Borrowing\n& Return Monitoring System',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppTheme.accent,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.4),
                  ),
                ),
                const SizedBox(height: 6),
                const Text('for School Laboratories',
                    style: TextStyle(
                        color: AppTheme.textLight,
                        fontSize: 12,
                        letterSpacing: 0.5)),
                const SizedBox(height: 8),
                const Text('CEA · New Era University',
                    style: TextStyle(
                        color: AppTheme.textLight,
                        fontSize: 11,
                        letterSpacing: 0.5)),
                const SizedBox(height: 56),
                const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        color: AppTheme.accent, strokeWidth: 2)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Login Screen ─────────────────────────────────────────────────────────────

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isStudent = true;
  bool _obscure = true;
  bool _loading = false;
  bool _rememberMe = true;
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl   = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadRemembered();
  }

  // Restore the "remember me" choice and the saved identifier (never the
  // password) so a returning user finds their student number / email pre-filled.
  Future<void> _loadRemembered() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final remember = prefs.getBool('remember_me') ?? true;
      final savedId  = prefs.getString('saved_identifier') ?? '';
      final savedIsStudent = prefs.getBool('saved_is_student') ?? true;
      if (!mounted) return;
      setState(() {
        _rememberMe = remember;
        if (remember && savedId.isNotEmpty) {
          _isStudent = savedIsStudent;
          _identifierCtrl.text = savedId;
        }
      });
    } catch (_) {/* ignore — just start with defaults */}
  }

  Future<void> _saveRemembered(String identifier) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('remember_me', _rememberMe);
      if (_rememberMe) {
        await prefs.setString('saved_identifier', identifier);
        await prefs.setBool('saved_is_student', _isStudent);
      } else {
        await prefs.remove('saved_identifier');
        await prefs.remove('saved_is_student');
      }
    } catch (_) {/* non-fatal */}
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // Clear fields and reset obscure when switching tabs
  void _switchRole(bool toStudent) {
    setState(() {
      _isStudent = toStudent;
      _identifierCtrl.clear();
      _passwordCtrl.clear();
      _obscure = true;
    });
  }

  Future<void> _forgotPassword() async {
    final emailCtrl = TextEditingController(
        text: _isStudent ? '' : _identifierCtrl.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Reset Password'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Enter your registered email address and we will send you a link '
            'to reset your password.',
            style: TextStyle(fontSize: 13, color: AppTheme.textMid, height: 1.5),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: emailCtrl,
            keyboardType: TextInputType.emailAddress,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'name@neu.edu.ph',
              prefixIcon: Icon(Icons.email_outlined, color: AppTheme.textMid),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
              onPressed: () => Navigator.pop(dialogCtx, emailCtrl.text.trim()),
              child: const Text('Send Link')),
        ],
      ),
    );
    if (email == null || email.isEmpty || !mounted) return;
    final res = await ApiService.sendPasswordReset(email);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] == true
          ? 'Password reset link sent to $email. Check your inbox and spam folder.'
          : (res['message'] ?? 'Could not send reset email.')),
      backgroundColor:
          res['success'] == true ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _login() async {
    final id = _identifierCtrl.text.trim();
    final pw = _passwordCtrl.text.trim();
    if (id.isEmpty || pw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.'), backgroundColor: AppTheme.danger));
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ApiService.login(id, pw, _isStudent ? 'student' : 'staff');
      if (!mounted) return;
      if (res['success'] == true) {
        await _saveRemembered(id);
        if (!mounted) return;
        Session.set(res['user'] as Map<String, dynamic>, res['role'] as String);
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (_) => _isStudent ? const StudentHomeScreen() : const AdminDashboardScreen()));
      } else if (res['message'] == 'email_not_verified') {
        _showVerificationDialog(res['email'] as String);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res['message'] ?? 'Login failed.'), backgroundColor: AppTheme.danger));
      }
    } catch (e) {
      // Never surface a raw exception to the user.
      final userMsg = ApiService._friendlyError(e);
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(children: [
              Icon(Icons.wifi_off_rounded, color: AppTheme.danger),
              SizedBox(width: 10),
              Text('Connection Error'),
            ]),
            content: Text(userMsg, style: const TextStyle(fontSize: 13, height: 1.6)),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showVerificationDialog(String email) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: const BoxDecoration(color: Color(0x1FFFFB70), shape: BoxShape.circle),
            child: const Icon(Icons.mark_email_unread_outlined, color: AppTheme.accent, size: 40),
          ),
          const SizedBox(height: 20),
          const Text('Email Not Verified',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
          const SizedBox(height: 10),
          Text('Please verify your email ($email) before signing in. Check your inbox for a verification link.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () async {
                // Show loading spinner first, THEN await — so we can show
                // the result even if something goes wrong.
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const Center(child: CircularProgressIndicator()),
                );
                final res = await ApiService.resendVerificationEmail(
                    email, _passwordCtrl.text.trim());
                if (!mounted) return;
                Navigator.pop(context); // close loading spinner
                Navigator.pop(context); // close verification dialog
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(res['success'] == true
                      ? 'Verification email sent! Check your inbox and spam folder.'
                      : (res['message'] ?? 'Failed to send. Please try again.')),
                  backgroundColor:
                      res['success'] == true ? AppTheme.success : AppTheme.danger,
                  duration: const Duration(seconds: 6),
                ));
              },
              child: const Text('Resend Verification Email'),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 40),
            const NeuLogo(size: 60),
            const SizedBox(height: 12),
            const Text('LabTrack',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5)),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Mobile Equipment Borrowing\n& Return Monitoring System',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.4),
              ),
            ),
            const SizedBox(height: 4),
            const Text('for School Laboratories · CEA · NEU',
                style: TextStyle(
                    color: AppTheme.textLight,
                    fontSize: 11)),
            const SizedBox(height: 28),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                padding: const EdgeInsets.all(28),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      // Role Toggle
                      Container(
                        decoration: BoxDecoration(
                          color: AppTheme.divider,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          children: [
                            _RoleTab(
                                label: 'Student',
                                icon: Icons.school_rounded,
                                selected: _isStudent,
                                onTap: () => _switchRole(true)),
                            _RoleTab(
                                label: 'Lab Staff',
                                icon: Icons.admin_panel_settings_rounded,
                                selected: !_isStudent,
                                onTap: () => _switchRole(false)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      const Text('Welcome back',
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.textDark)),
                      const SizedBox(height: 4),
                      Text(
                          _isStudent
                              ? 'Sign in to borrow lab equipment'
                              : 'Sign in to manage the lab',
                          style: const TextStyle(
                              color: AppTheme.textMid, fontSize: 14)),
                      const SizedBox(height: 24),
                      Text(
                          _isStudent ? 'Student ID / Email' : 'Email Address',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textDark)),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _identifierCtrl,
                        keyboardType: _isStudent
                            ? TextInputType.text
                            : TextInputType.emailAddress,
                        autocorrect: false,
                        decoration: InputDecoration(
                          hintText: _isStudent
                              ? 'e.g. 26-12345-123'
                              : 'staff@neu.edu.ph',
                          prefixIcon: Icon(
                              _isStudent
                                  ? Icons.person_outline_rounded
                                  : Icons.email_outlined,
                              color: AppTheme.textMid),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text('Password',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textDark)),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _passwordCtrl,
                        obscureText: _obscure,
                        decoration: InputDecoration(
                          // NOT a row of bullets: "remember me" restores the
                          // identifier but never the password, so a bullet hint
                          // over an empty field is indistinguishable from a
                          // filled obscured one — users tapped Sign In and got
                          // "Please fill in all fields" on a form that looked complete.
                          hintText: 'Enter your password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded,
                              color: AppTheme.textMid),
                          suffixIcon: GestureDetector(
                            onTap: () => setState(() => _obscure = !_obscure),
                            child: Icon(
                                _obscure
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                color: AppTheme.textMid),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Remember me
                          GestureDetector(
                            onTap: () => setState(() => _rememberMe = !_rememberMe),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              SizedBox(
                                width: 22, height: 22,
                                child: Checkbox(
                                  value: _rememberMe,
                                  onChanged: (v) =>
                                      setState(() => _rememberMe = v ?? true),
                                  activeColor: AppTheme.primary,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text('Remember me',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textMid,
                                      fontWeight: FontWeight.w500)),
                            ]),
                          ),
                          // Forgot password
                          GestureDetector(
                            onTap: _forgotPassword,
                            child: const Text('Forgot password?',
                                style: TextStyle(
                                    color: AppTheme.accent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _login,
                          child: _loading
                              ? const SizedBox(width: 20, height: 20,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              : const Text('Sign In'),
                        ),
                      ),
                      // ── Sign Up Link (students only) ──
                      if (_isStudent) ...[
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text("Don't have an account? ",
                                style: TextStyle(
                                    fontSize: 13, color: AppTheme.textMid)),
                            GestureDetector(
                              onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const SignUpScreen())),
                              child: const Text('Sign Up',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.accent,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Terms and Conditions Screen ─────────────────────────────────────────────

class TermsAndConditionsScreen extends StatelessWidget {
  const TermsAndConditionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terms and Conditions')),
      body: Column(children: [
        // Header
        Container(
          width: double.infinity,
          color: AppTheme.primary,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                  color: Colors.white.withAlpha(25),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.gavel_rounded,
                  color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            const Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Terms and Conditions',
                  style: TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 15)),
              SizedBox(height: 2),
              Text('LabTrack — CEA Laboratory · New Era University',
                  style: TextStyle(color: AppTheme.textLight, fontSize: 11)),
            ])),
          ]),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TermsSection(
                  number: '1',
                  title: 'Acceptance of Terms',
                  body: 'By creating an account and using the LabTrack Mobile Equipment Borrowing and Return Monitoring System, you agree to be bound by these Terms and Conditions. This system is exclusively for enrolled students and authorized laboratory staff of the College of Engineering and Architecture (CEA) at New Era University.',
                ),
                _TermsSection(
                  number: '2',
                  title: 'Eligibility',
                  body: 'Registration is limited to currently enrolled students of New Era University. You must provide a valid NEU institutional email address (ending in @neu.edu.ph) and your official student ID number in the format ##-#####-###. Providing false or misleading information during registration is a violation of these terms and may result in account suspension.',
                ),
                _TermsSection(
                  number: '3',
                  title: 'Equipment Borrowing Responsibilities',
                  body: 'By borrowing equipment through LabTrack, you acknowledge that:\n\n• You are responsible for the safe custody of all borrowed equipment from the time of check-out until it is returned and confirmed by laboratory staff.\n\n• Equipment must be returned in the same condition it was borrowed. Any damage, loss, or missing parts must be reported immediately through the Damage Report feature.\n\n• Damaged or missing equipment must be replaced with an item of the same type or equivalent condition acceptable to laboratory staff.\n\n• Failure to replace damaged or missing equipment may result in your academic clearance not being signed or approved.',
                ),
                _TermsSection(
                  number: '4',
                  title: 'Return Policy',
                  body: 'All borrowed equipment must be returned to the CEA laboratory on the same day of borrowing, before 5:00 PM. Equipment not returned by the agreed return time will be marked as overdue. Repeated late returns may result in temporary suspension of your borrowing privileges for a period determined by laboratory staff.',
                ),
                _TermsSection(
                  number: '5',
                  title: 'Reservation Policy',
                  body: 'Equipment reservations are valid for the same day only. Reservations are subject to equipment availability and must be approved by laboratory staff. Unapproved or pending reservations do not guarantee equipment availability.',
                ),
                _TermsSection(
                  number: '6',
                  title: 'Off-Campus Equipment Use',
                  body: 'The use of laboratory equipment outside of the university campus requires prior written approval from laboratory staff. A formal request stating the purpose and location of external use must be submitted and approved before equipment is released for off-campus use.',
                ),
                _TermsSection(
                  number: '7',
                  title: 'Account Security',
                  body: 'You are responsible for maintaining the confidentiality of your account credentials. You must not share your login information with other students or unauthorized individuals. Any activity performed under your account is your responsibility. If you suspect unauthorized access to your account, notify laboratory staff immediately.',
                ),
                _TermsSection(
                  number: '8',
                  title: 'System Use',
                  body: 'The LabTrack system must be used solely for its intended purpose of laboratory equipment management at CEA, New Era University. Any attempt to misuse, manipulate, or exploit the system for unauthorized purposes is strictly prohibited and may result in disciplinary action.',
                ),
                _TermsSection(
                  number: '9',
                  title: 'Modifications',
                  body: 'Laboratory staff reserves the right to modify these Terms and Conditions at any time. Continued use of the system after any changes constitutes your acceptance of the revised terms.',
                ),
                _TermsSection(
                  number: '10',
                  title: 'Governing Policy',
                  body: 'These Terms and Conditions are governed by the existing policies of New Era University and the College of Engineering and Architecture. In cases not covered by these terms, the university\'s student handbook and laboratory policies shall apply.',
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0x0F1B3A8C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x1F1B3A8C)),
                  ),
                  child: const Text(
                    'Last updated: May 2026 · LabTrack v1.0 · CEA Laboratory · New Era University',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMid),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),

        // Bottom button
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          color: Colors.white,
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.check_rounded),
              label: const Text('I Understand — Go Back'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─── Privacy Policy Screen ────────────────────────────────────────────────────

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: Column(children: [
        // Header
        Container(
          width: double.infinity,
          color: AppTheme.primary,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                  color: Colors.white.withAlpha(25),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.privacy_tip_rounded,
                  color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            const Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Privacy Policy',
                  style: TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 15)),
              SizedBox(height: 2),
              Text('LabTrack — CEA Laboratory · New Era University',
                  style: TextStyle(color: AppTheme.textLight, fontSize: 11)),
            ])),
          ]),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TermsSection(
                  number: '1',
                  title: 'Information We Collect',
                  body: 'When you register for a LabTrack account, we collect the following personal information:\n\n• Full name\n• NEU institutional email address\n• Student ID number\n• Degree program (course)\n• Year level\n• Password (stored securely through Firebase Authentication — never stored in plain text)',
                ),
                _TermsSection(
                  number: '2',
                  title: 'How We Use Your Information',
                  body: 'Your personal information is used solely for the operation of the LabTrack equipment borrowing system. Specifically:\n\n• Your name and student ID are used to identify you in borrowing transactions and records.\n• Your email address is used for account authentication and login.\n• Your borrowing history is recorded to maintain accountability for laboratory equipment.\n• Your information is used by laboratory staff to verify your identity when you borrow equipment.',
                ),
                _TermsSection(
                  number: '3',
                  title: 'Data Storage',
                  body: 'All personal data and transaction records are stored securely in Google Firebase Cloud Firestore, a cloud-based database service provided by Google LLC. Firebase applies industry-standard security measures including data encryption in transit (HTTPS/TLS) and at rest. Your password is managed exclusively by Firebase Authentication and is never accessible to laboratory staff or system administrators.',
                ),
                _TermsSection(
                  number: '4',
                  title: 'Who Can See Your Information',
                  body: 'Your personal information is accessible only to:\n\n• Laboratory staff with authorized admin accounts, who can view your name, student ID, and borrowing history for the purpose of managing equipment transactions.\n• No third parties outside of New Era University have access to your data.\n• Your password is not visible to anyone, including laboratory staff and system developers.',
                ),
                _TermsSection(
                  number: '5',
                  title: 'Data We Do Not Collect',
                  body: 'LabTrack does not collect:\n\n• Financial information or payment details\n• Device location or GPS data\n• Phone contacts or media files\n• Biometric data of any kind\n• Any data unrelated to laboratory equipment borrowing',
                ),
                _TermsSection(
                  number: '6',
                  title: 'Your Rights',
                  body: 'You have the right to:\n\n• View and update your personal information through the Edit Profile screen in the app.\n• Request correction of inaccurate information by contacting laboratory staff.\n• Request deletion of your account by contacting the laboratory staff directly.',
                ),
                _TermsSection(
                  number: '7',
                  title: 'Data Retention',
                  body: 'Your account information and borrowing records are retained for the duration of your enrollment at New Era University and for a reasonable period thereafter, as required for institutional record-keeping purposes. Borrowing transaction records may be retained indefinitely to maintain a complete audit trail of laboratory equipment usage.',
                ),
                _TermsSection(
                  number: '8',
                  title: 'Security',
                  body: 'We take the security of your data seriously. The system uses Firebase Authentication for secure login, Firestore Security Rules to prevent unauthorized data access, and HTTPS encryption for all data transmission. However, no system is completely immune to security risks. You are responsible for keeping your login credentials confidential.',
                ),
                _TermsSection(
                  number: '9',
                  title: 'Contact',
                  body: 'If you have questions or concerns about this Privacy Policy or how your data is handled, please contact the CEA Laboratory staff at New Era University or reach out through the Help & FAQ section of the application.',
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0x0F1B3A8C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x1F1B3A8C)),
                  ),
                  child: const Text(
                    'Last updated: May 2026 · LabTrack v1.0 · CEA Laboratory · New Era University',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMid),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),

        // Bottom button
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          color: Colors.white,
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.check_rounded),
              label: const Text('I Understand — Go Back'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─── Terms Section Widget ─────────────────────────────────────────────────────

class _TermsSection extends StatelessWidget {
  final String number, title, body;
  const _TermsSection(
      {required this.number, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border(
            left: BorderSide(color: AppTheme.primary, width: 4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
                color: const Color(0x1A1B3A8C),
                borderRadius: BorderRadius.circular(8)),
            child: Center(
              child: Text(number,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primary)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primary)),
          ),
        ]),
        const SizedBox(height: 10),
        const Divider(color: AppTheme.divider, height: 1),
        const SizedBox(height: 10),
        Text(body,
            style: const TextStyle(
                fontSize: 13,
                color: AppTheme.textDark,
                height: 1.6)),
      ]),
    );
  }
}

// ─── Sign Up Screen ───────────────────────────────────────────────────────────

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});
  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();

  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _studentIdCtrl = TextEditingController();
  String? _selectedCourse;
  final _yearCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();

  bool _obscurePass = true;
  bool _obscureConfirm = true;
  bool _agreedToTerms = false;

  // Live email validation state
  bool get _emailValid => kDemoMode
      ? _emailCtrl.text.trim().contains('@')
      : RegExp(r'^[a-zA-Z0-9._%+\-]+@neu\.edu\.ph$')
          .hasMatch(_emailCtrl.text.trim());

  // Live student ID validation (##-#####-### format)
  bool get _idValid =>
      RegExp(r'^\d{2}-\d{5}-\d{3}$').hasMatch(_studentIdCtrl.text.trim());

  // Validate: must be NEU email domain only (relaxed in demo mode)
  String? _validateEmail(String? val) {
    if (val == null || val.trim().isEmpty) return 'Email is required';
    if (!val.trim().contains('@')) return 'Enter a valid email address';
    if (!kDemoMode && !val.trim().toLowerCase().endsWith('@neu.edu.ph')) {
      return 'Must be an official NEU email (@neu.edu.ph)';
    }
    return null;
  }

  // Validate: NEU student ID format ##-#####-###
  String? _validateStudentId(String? val) {
    if (val == null || val.trim().isEmpty) return 'Student ID is required';
    if (!RegExp(r'^\d{2}-\d{5}-\d{3}$').hasMatch(val.trim())) {
      return 'Invalid format — e.g. 26-12345-123';
    }
    return null;
  }

  String? _validateRequired(String? val) {
    if (val == null || val.trim().isEmpty) return 'Required';
    return null;
  }

  String? _validatePassword(String? val) {
    if (val == null || val.isEmpty) return 'Required';
    if (val.length < 8) return 'At least 8 characters';
    return null;
  }

  String? _validateConfirmPass(String? val) {
    if (val == null || val.isEmpty) return 'Required';
    if (val != _passCtrl.text) return 'Passwords do not match';
    return null;
  }

  Future<void> _submitSignUp() async {
    if (_formKey.currentState!.validate()) {
      if (!_agreedToTerms) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please agree to the Terms and Conditions'), backgroundColor: AppTheme.danger));
        return;
      }
      // Show loading
      showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));

      try {
        final res = await ApiService.registerStudent({
          'first_name':     _firstNameCtrl.text.trim(),
          'last_name':      _lastNameCtrl.text.trim(),
          'email':          _emailCtrl.text.trim(),
          'student_number': _studentIdCtrl.text.trim(),
          'course':         _selectedCourse ?? '',
          'year_level':     int.tryParse(_yearCtrl.text.trim()) ?? 1,
          'password':       _passCtrl.text,
        });
        if (!mounted) return;
        Navigator.pop(context); // close loading

        if (res['success'] == true) {
          showDialog(context: context, barrierDismissible: false,
            builder: (_) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              contentPadding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 72, height: 72,
                  decoration: BoxDecoration(color: const Color(0x1F06D6A0), shape: BoxShape.circle),
                  child: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 40)),
                const SizedBox(height: 20),
                const Text('Account Created!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
                const SizedBox(height: 10),
                Text(kDemoMode
                        ? 'Welcome, ${_firstNameCtrl.text}! Your account is ready — you can sign in now with your student number and password.'
                        : 'Welcome, ${_firstNameCtrl.text}! A verification link has been sent to ${_emailCtrl.text.trim()}. Please check your inbox and verify your email before signing in.',
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
                const SizedBox(height: 24),
                SizedBox(width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () { Navigator.pop(context); Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen())); },
                    child: const Text('Go to Sign In'))),
              ]),
            ));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(res['message'] ?? 'Registration failed.'), backgroundColor: AppTheme.danger));
        }
      } catch (e) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not create the account. Check your internet connection and try again.'), backgroundColor: AppTheme.danger));
        }
      }
    }
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _studentIdCtrl.dispose();
    _yearCtrl.dispose();
    _passCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 24, 20),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Create Account',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold)),
                        Text('Student Registration',
                            style: TextStyle(
                                color: AppTheme.textLight, fontSize: 12)),
                      ],
                    ),
                  ),
                  const NeuLogo(size: 40),
                ],
              ),
            ),
            // Form Sheet
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [

                        // ── NEU Students Only Banner ──
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0x1A1B3A8C),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppTheme.primary.withAlpha(50)),
                          ),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(
                                color: AppTheme.primary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.school_rounded,
                                  color: Colors.white, size: 20),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('NEU Students Only',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: AppTheme.primary)),
                                  SizedBox(height: 4),
                                  Text(
                                    'This system is exclusively for students of New Era University — College of Engineering and Architecture. Registration requires a valid NEU email address (@neu.edu.ph) and your official student ID number.',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textMid,
                                        height: 1.4),
                                  ),
                                ],
                              ),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 20),

                        // ── SECTION: Identity Verification ──
                        _SectionDivider(
                          icon: Icons.verified_user_outlined,
                          label: 'Identity Verification',
                          color: AppTheme.accent,
                        ),
                        const SizedBox(height: 16),

                        // Institutional Email
                        _FieldLabel('NEU Email Address'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          validator: _validateEmail,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'yourname@neu.edu.ph',
                            prefixIcon: const Icon(Icons.email_outlined,
                                color: AppTheme.textMid),
                            suffixIcon: _emailCtrl.text.isNotEmpty
                                ? Icon(
                                    _emailValid
                                        ? Icons.check_circle_rounded
                                        : Icons.cancel_rounded,
                                    color: _emailValid
                                        ? AppTheme.success
                                        : AppTheme.danger,
                                    size: 20,
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(children: [
                          Icon(
                            _emailCtrl.text.isEmpty
                                ? Icons.info_outline_rounded
                                : _emailValid
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.error_outline_rounded,
                            size: 12,
                            color: _emailCtrl.text.isEmpty
                                ? AppTheme.textLight
                                : _emailValid
                                    ? AppTheme.success
                                    : AppTheme.danger,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _emailCtrl.text.isEmpty
                                ? 'Must end with @neu.edu.ph'
                                : _emailValid
                                    ? 'Valid NEU email ✓'
                                    : 'Only @neu.edu.ph emails are accepted',
                            style: TextStyle(
                              fontSize: 11,
                              color: _emailCtrl.text.isEmpty
                                  ? AppTheme.textLight
                                  : _emailValid
                                      ? AppTheme.success
                                      : AppTheme.danger,
                            ),
                          ),
                        ]),
                        const SizedBox(height: 16),

                        // Student ID
                        _FieldLabel('Student ID Number'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _studentIdCtrl,
                          keyboardType: TextInputType.text,
                          autocorrect: false,
                          validator: _validateStudentId,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'e.g. 26-12345-123',
                            prefixIcon: const Icon(Icons.badge_outlined,
                                color: AppTheme.textMid),
                            suffixIcon: _studentIdCtrl.text.isNotEmpty
                                ? Icon(
                                    _idValid
                                        ? Icons.check_circle_rounded
                                        : Icons.cancel_rounded,
                                    color: _idValid
                                        ? AppTheme.success
                                        : AppTheme.danger,
                                    size: 20,
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(children: [
                          Icon(
                            _studentIdCtrl.text.isEmpty
                                ? Icons.info_outline_rounded
                                : _idValid
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.error_outline_rounded,
                            size: 12,
                            color: _studentIdCtrl.text.isEmpty
                                ? AppTheme.textLight
                                : _idValid
                                    ? AppTheme.success
                                    : AppTheme.danger,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _studentIdCtrl.text.isEmpty
                                ? 'Format: 26-12345-123'
                                : _idValid
                                    ? 'Valid student ID format ✓'
                                    : 'Invalid format — check your ID number',
                            style: TextStyle(
                              fontSize: 11,
                              color: _studentIdCtrl.text.isEmpty
                                  ? AppTheme.textLight
                                  : _idValid
                                      ? AppTheme.success
                                      : AppTheme.danger,
                            ),
                          ),
                        ]),
                        const SizedBox(height: 20),

                        // Verification info box
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0x0FF5A623),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: const Color(0x33F5A623)),
                          ),
                          child: const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.verified_user_outlined,
                                  size: 16, color: AppTheme.accent),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                    'Your NEU email and Student ID are used to verify that you are an enrolled CEA student. Accounts with non-NEU emails or invalid student IDs will not be approved by laboratory staff.',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textMid,
                                        height: 1.5)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── SECTION: Personal Information ──
                        _SectionDivider(
                          icon: Icons.person_outline_rounded,
                          label: 'Personal Information',
                          color: AppTheme.primary,
                        ),
                        const SizedBox(height: 16),

                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _FieldLabel('First Name'),
                                  const SizedBox(height: 8),
                                  TextFormField(
                                    controller: _firstNameCtrl,
                                    validator: _validateRequired,
                                    decoration: const InputDecoration(
                                        hintText: 'e.g. Juan'),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _FieldLabel('Last Name'),
                                  const SizedBox(height: 8),
                                  TextFormField(
                                    controller: _lastNameCtrl,
                                    validator: _validateRequired,
                                    decoration: const InputDecoration(
                                        hintText: 'e.g. Dela Cruz'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _FieldLabel('Course / Program'),
                                  const SizedBox(height: 8),
                                  DropdownButtonFormField<String>(
                                    value: _selectedCourse,
                                    validator: (v) => v == null ? 'Required' : null,
                                    decoration: const InputDecoration(
                                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14)),
                                    hint: const Text('Select course'),
                                    isExpanded: true,
                                    items: _kCourses.map((c) => DropdownMenuItem(value: c, child: Text(courseLabel(c)))).toList(),
                                    onChanged: (v) => setState(() => _selectedCourse = v),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _FieldLabel('Year Level'),
                                  const SizedBox(height: 8),
                                  DropdownButtonFormField<String>(
                                    validator: (v) =>
                                        v == null ? 'Required' : null,
                                    decoration: const InputDecoration(
                                        contentPadding: EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 14)),
                                    hint: const Text('Year'),
                                    items: ['1st', '2nd', '3rd', '4th', '5th']
                                        .map((y) => DropdownMenuItem(
                                            value: y, child: Text(y)))
                                        .toList(),
                                    onChanged: (v) =>
                                        setState(() => _yearCtrl.text = v ?? ''),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),

                        // ── SECTION: Account Security ──
                        _SectionDivider(
                          icon: Icons.lock_outline_rounded,
                          label: 'Account Security',
                          color: AppTheme.warning,
                        ),
                        const SizedBox(height: 16),

                        _FieldLabel('Password'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _passCtrl,
                          obscureText: _obscurePass,
                          validator: _validatePassword,
                          decoration: InputDecoration(
                            hintText: 'Minimum 8 characters',
                            prefixIcon: const Icon(Icons.lock_outline_rounded,
                                color: AppTheme.textMid),
                            suffixIcon: GestureDetector(
                              onTap: () =>
                                  setState(() => _obscurePass = !_obscurePass),
                              child: Icon(
                                  _obscurePass
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: AppTheme.textMid),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        _FieldLabel('Confirm Password'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _confirmPassCtrl,
                          obscureText: _obscureConfirm,
                          validator: _validateConfirmPass,
                          decoration: InputDecoration(
                            hintText: 'Re-enter your password',
                            prefixIcon: const Icon(Icons.lock_outline_rounded,
                                color: AppTheme.textMid),
                            suffixIcon: GestureDetector(
                              onTap: () => setState(
                                  () => _obscureConfirm = !_obscureConfirm),
                              child: Icon(
                                  _obscureConfirm
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: AppTheme.textMid),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Terms and Conditions
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onTap: () => setState(
                                  () => _agreedToTerms = !_agreedToTerms),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: 22, height: 22,
                                decoration: BoxDecoration(
                                  color: _agreedToTerms
                                      ? AppTheme.accent
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: _agreedToTerms
                                          ? AppTheme.accent
                                          : AppTheme.textLight,
                                      width: 1.5),
                                ),
                                child: _agreedToTerms
                                    ? const Icon(Icons.check_rounded,
                                        color: Colors.white, size: 14)
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  text: 'I have read and agree to the ',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textMid),
                                  children: [
                                    WidgetSpan(
                                      child: GestureDetector(
                                        onTap: () => Navigator.push(context,
                                            MaterialPageRoute(builder: (_) =>
                                                const TermsAndConditionsScreen())),
                                        child: const Text('Terms and Conditions',
                                            style: TextStyle(
                                                fontSize: 13,
                                                color: AppTheme.accent,
                                                fontWeight: FontWeight.bold,
                                                decoration: TextDecoration.underline)),
                                      ),
                                    ),
                                    const TextSpan(text: ' and '),
                                    WidgetSpan(
                                      child: GestureDetector(
                                        onTap: () => Navigator.push(context,
                                            MaterialPageRoute(builder: (_) =>
                                                const PrivacyPolicyScreen())),
                                        child: const Text('Privacy Policy',
                                            style: TextStyle(
                                                fontSize: 13,
                                                color: AppTheme.accent,
                                                fontWeight: FontWeight.bold,
                                                decoration: TextDecoration.underline)),
                                      ),
                                    ),
                                    const TextSpan(
                                        text: ' of the LabTrack borrowing system.'),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),

                        // Submit Button
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _submitSignUp,
                            icon: const Icon(Icons.how_to_reg_rounded),
                            label: const Text('Create Account'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('Already have an account? ',
                                style: TextStyle(
                                    fontSize: 13, color: AppTheme.textMid)),
                            GestureDetector(
                              onTap: () => Navigator.pop(context),
                              child: const Text('Sign In',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.accent,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sign Up helper widgets ──

class _SectionDivider extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _SectionDivider(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color.withAlpha(26),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 16),
        ),
        const SizedBox(width: 10),
        Text(label,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color)),
        const SizedBox(width: 12),
        const Expanded(child: Divider(color: AppTheme.divider)),
      ],
    );
  }
}

Widget _FieldLabel(String label) => Text(label,
    style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppTheme.textDark));

class _RoleTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _RoleTab(
      {required this.label,
      required this.icon,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppTheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: selected ? AppTheme.accent : AppTheme.textMid),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      color: selected ? Colors.white : AppTheme.textMid,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Student Home Screen ──────────────────────────────────────────────────────

class StudentHomeScreen extends StatefulWidget {
  const StudentHomeScreen({super.key});
  @override
  State<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends State<StudentHomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const _StudentDashboard(),
    const EquipmentCatalogScreen(),
    const MyBorrowingsScreen(),
    const ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: _pages[_currentIndex]),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(color: Color(0x1A000000), blurRadius: 16, offset: Offset(0, -4))
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          type: BottomNavigationBarType.fixed,
          selectedItemColor: AppTheme.primary,
          unselectedItemColor: AppTheme.textLight,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined),
                activeIcon: Icon(Icons.home_rounded),
                label: 'Home'),
            BottomNavigationBarItem(
                icon: Icon(Icons.inventory_2_outlined),
                activeIcon: Icon(Icons.inventory_2_rounded),
                label: 'Catalog'),
            BottomNavigationBarItem(
                icon: Icon(Icons.receipt_long_outlined),
                activeIcon: Icon(Icons.receipt_long_rounded),
                label: 'My Loans'),
            BottomNavigationBarItem(
                icon: Icon(Icons.person_outline_rounded),
                activeIcon: Icon(Icons.person_rounded),
                label: 'Profile'),
          ],
        ),
      ),
    );
  }
}

// ─── Student Dashboard ────────────────────────────────────────────────────────

class _StudentDashboard extends StatefulWidget {
  const _StudentDashboard();
  @override
  State<_StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<_StudentDashboard> {
  bool _loading = true;
  List<dynamic> _allLoans = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Honour the user's saved notification toggles when building cards.
      await NotifPrefs.load();
      final loans = await ApiService.getMyBorrowings(
        studentId: Session.studentId,
        studentNumber: Session.studentNumber,
      );
      // Refresh the live hold/penalty flag so the banner stays current even if
      // staff placed a hold during this session.
      final sid = Session.currentUser?['student_id']?.toString() ?? '';
      if (sid.isNotEmpty) {
        final fresh = await ApiService.getStudent(sid);
        if (fresh != null && Session.currentUser != null) {
          Session.currentUser!['hold'] = fresh['hold'] ?? false;
          Session.currentUser!['hold_reason'] = fresh['hold_reason'] ?? '';
        }
      }
      setState(() { _allLoans = loans; _loading = false; });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  // Derive stats from live loans
  List<dynamic> get _activeLoans =>
      _allLoans.where((e) => e['status'] == 'Approved').toList();
  List<dynamic> get _pendingLoans =>
      _allLoans.where((e) => e['status'] == 'Pending').toList();

  int get _dueToday => _activeLoans.where((e) {
    final due = DateTime.tryParse('${e['due_date']}'.replaceAll(' ', 'T'));
    if (due == null) return false;
    final now = DateTime.now();
    return due.year == now.year && due.month == now.month && due.day == now.day;
  }).length;

  int get _overdue => _activeLoans.where((e) {
    final due = DateTime.tryParse('${e['due_date']}'.replaceAll(' ', 'T'));
    if (due == null) return false;
    return due.isBefore(DateTime.now());
  }).length;

  // Build notification cards from live loan statuses
  List<Map<String, dynamic>> get _notifications {
    final notes = <Map<String, dynamic>>[];
    for (final loan in _allLoans) {
      final status   = loan['status'] ?? '';
      final equipName= loan['equipment_name'] ?? 'Equipment';
      final due      = DateTime.tryParse('${loan['due_date']}'.replaceAll(' ', 'T'));
      final now      = DateTime.now();

      // Each card type honours the corresponding toggle in
      // Profile → Notifications (NotifPrefs).
      if (status == 'Approved' && due != null) {
        if (NotifPrefs.dueSoon &&
            due.year == now.year && due.month == now.month && due.day == now.day) {
          notes.add({
            'icon':  Icons.access_alarm_rounded,
            'color': AppTheme.warning,
            'title': 'Due Today',
            'body':  '$equipName is due back today before 5:00 PM.',
          });
        } else if (NotifPrefs.overdue && due.isBefore(now)) {
          notes.add({
            'icon':  Icons.warning_amber_rounded,
            'color': AppTheme.danger,
            'title': 'Overdue!',
            'body':  '$equipName was due on ${due.month}/${due.day}. Please return it immediately.',
          });
        }
      }
      if (NotifPrefs.approved &&
          status == 'Approved' && due != null && !due.isBefore(now)) {
        notes.add({
          'icon':  Icons.check_circle_rounded,
          'color': AppTheme.success,
          'title': 'Request Approved',
          'body':  'Your request for $equipName has been approved.',
        });
      }
      if (NotifPrefs.rejected && status == 'Rejected') {
        notes.add({
          'icon':  Icons.cancel_rounded,
          'color': AppTheme.danger,
          'title': 'Request Rejected',
          'body':  'Your request for $equipName was rejected by staff.',
        });
      }
      if (NotifPrefs.returnConfirmed && status == 'Returned') {
        notes.add({
          'icon':  Icons.assignment_turned_in_rounded,
          'color': AppTheme.success,
          'title': 'Return Confirmed',
          'body':  'Your return of $equipName has been confirmed by staff.',
        });
      }
    }
    return notes;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hour = now.hour;
    final greeting = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4FF),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            // ── Hero Header ──────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF0D2257), Color(0xFF1B3A8C), Color(0xFF1E4DB7)],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Stack(
                    children: [
                      // Decorative circles
                      Positioned(top: -30, right: -30,
                        child: Container(width: 130, height: 130,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0x0AFFFFFF)))),
                      Positioned(top: 40, right: 40,
                        child: Container(width: 60, height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0x1FF5A623)))),
                      Positioned(bottom: -10, left: -20,
                        child: Container(width: 90, height: 90,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0x08FFFFFF)))),

                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Top bar — logo + notification
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // System tag
                                Row(children: [
                                  Container(
                                    width: 32, height: 32,
                                    decoration: BoxDecoration(
                                      color: const Color(0x33F5A623),
                                      borderRadius: BorderRadius.circular(9),
                                    ),
                                    child: const Icon(Icons.science_rounded,
                                        color: Color(0xFFF5A623), size: 18)),
                                  const SizedBox(width: 8),
                                  Column(crossAxisAlignment: CrossAxisAlignment.start,
                                    children: const [
                                      Text('LabTrack',
                                        style: TextStyle(color: Color(0xFFF5A623),
                                          fontSize: 12, fontWeight: FontWeight.w800,
                                          letterSpacing: 0.8)),
                                      Text('CEA Lab · NEU',
                                        style: TextStyle(color: Color(0x99FFFFFF),
                                          fontSize: 9)),
                                    ]),
                                ]),
                                // Notification bell
                                GestureDetector(
                                  onTap: () {},
                                  child: Stack(children: [
                                    Container(
                                      width: 38, height: 38,
                                      decoration: BoxDecoration(
                                        color: const Color(0x1AFFFFFF),
                                        borderRadius: BorderRadius.circular(11),
                                      ),
                                      child: const Icon(Icons.notifications_outlined,
                                          color: Colors.white, size: 20)),
                                    if (_notifications.isNotEmpty)
                                      Positioned(top: 6, right: 6,
                                        child: Container(
                                          width: 8, height: 8,
                                          decoration: const BoxDecoration(
                                            color: Color(0xFFEF4444),
                                            shape: BoxShape.circle))),
                                  ]),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),

                            // System title — the main identity
                            const Text(
                              'Mobile Equipment Borrowing\n& Return Monitoring System',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                height: 1.25,
                                letterSpacing: 0.1,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text('for School Laboratories',
                              style: TextStyle(color: Color(0xFFF5A623),
                                fontSize: 12, fontWeight: FontWeight.w500)),
                            const SizedBox(height: 16),

                            // User greeting chip
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                color: const Color(0x1AFFFFFF),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: const Color(0x26FFFFFF)),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 12,
                                    backgroundColor: const Color(0xFFF5A623)
                                        .withValues(alpha: 0.25),
                                    child: Text(Session.initials,
                                      style: const TextStyle(
                                        color: Color(0xFFF5A623),
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 8),
                                  Text('$greeting, ${Session.name.split(' ').first}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500)),
                                ]),
                            ),
                            const SizedBox(height: 20),

                            // ── Stats row inside header ──
                            if (!_loading)
                              Row(children: [
                                _HeroStat(
                                  value: '${_activeLoans.length}',
                                  label: 'Active\nLoans',
                                  icon: Icons.inventory_2_rounded,
                                  accent: const Color(0xFFF5A623),
                                ),
                                const SizedBox(width: 10),
                                _HeroStat(
                                  value: '$_dueToday',
                                  label: 'Due\nToday',
                                  icon: Icons.schedule_rounded,
                                  accent: const Color(0xFFFFB703),
                                ),
                                const SizedBox(width: 10),
                                _HeroStat(
                                  value: '${_pendingLoans.length}',
                                  label: 'Pending\nRequests',
                                  icon: Icons.pending_actions_rounded,
                                  accent: const Color(0xFF60A5FA),
                                ),
                                const SizedBox(width: 10),
                                _HeroStat(
                                  value: '$_overdue',
                                  label: 'Over-\ndue',
                                  icon: Icons.warning_amber_rounded,
                                  accent: _overdue > 0
                                      ? const Color(0xFFEF4444)
                                      : const Color(0xFF06D6A0),
                                ),
                              ]),
                            if (_loading)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2)),
                              ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (!_loading)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

                      // ── Penalty / Hold banner (Prof recommendation #3) ──
                      if (Session.isOnHold || _overdue > 0) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: const Color(0x1AE74C3C),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: AppTheme.danger.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.gpp_bad_rounded,
                                  color: AppTheme.danger, size: 22),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Borrowing on Hold',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                            color: AppTheme.danger)),
                                    const SizedBox(height: 4),
                                    Text(
                                      Session.isOnHold && Session.holdReason.isNotEmpty
                                          ? Session.holdReason
                                          : 'You have overdue equipment. Please return it and '
                                              'settle any penalty with the laboratory staff '
                                              'before borrowing again.',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.textDark,
                                          height: 1.4),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // ── Alerts / Notifications ──────────────────────────
                      if (_notifications.isNotEmpty) ...[
                        _SectionTitle(title: 'Alerts', icon: Icons.notifications_active_rounded,
                            color: const Color(0xFFEF4444)),
                        const SizedBox(height: 10),
                        ..._notifications.take(3).map((n) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _AlertCard(
                            icon:  n['icon'] as IconData,
                            color: n['color'] as Color,
                            title: n['title'] as String,
                            body:  n['body']  as String,
                          ),
                        )),
                        const SizedBox(height: 20),
                      ],

                      // ── Quick Actions ────────────────────────────────────
                      _SectionTitle(title: 'Quick Actions',
                          icon: Icons.flash_on_rounded,
                          color: const Color(0xFFF5A623)),
                      const SizedBox(height: 12),
                      Row(children: [
                        _ActionTile(
                          icon: Icons.add_circle_rounded,
                          label: 'New\nRequest',
                          gradient: const [Color(0xFF1B3A8C), Color(0xFF1E4DB7)],
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const BorrowRequestScreen())),
                        ),
                        const SizedBox(width: 10),
                        _ActionTile(
                          icon: Icons.receipt_long_rounded,
                          label: 'My\nLoans',
                          gradient: const [Color(0xFF059669), Color(0xFF10B981)],
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const MyBorrowingsScreen())),
                        ),
                        const SizedBox(width: 10),
                        _ActionTile(
                          icon: Icons.report_problem_rounded,
                          label: 'Damage\nReport',
                          gradient: const [Color(0xFFD97706), Color(0xFFF59E0B)],
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const DamageReportScreen())),
                        ),
                        const SizedBox(width: 10),
                        _ActionTile(
                          icon: Icons.policy_rounded,
                          label: 'Lab\nPolicies',
                          gradient: const [Color(0xFF7C3AED), Color(0xFF8B5CF6)],
                          onTap: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const LabPoliciesScreen())),
                        ),
                      ]),
                      const SizedBox(height: 24),

                      // ── Active Loans ─────────────────────────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _SectionTitle(title: 'Active Loans',
                              icon: Icons.inventory_2_rounded,
                              color: const Color(0xFF1B3A8C)),
                          if (_activeLoans.isNotEmpty || _pendingLoans.isNotEmpty)
                            GestureDetector(
                              onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const MyBorrowingsScreen())),
                              child: const Text('See all',
                                style: TextStyle(
                                  color: Color(0xFF1B3A8C),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                )),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      if (_activeLoans.isEmpty && _pendingLoans.isEmpty)
                        _EmptyCard(
                          icon: Icons.inventory_2_outlined,
                          title: 'No active loans',
                          subtitle: 'Tap "New Request" to borrow equipment',
                        )
                      else ...[
                        ..._pendingLoans.take(2).map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _LoanItemCard(
                            name: '${e['equipment_name'] ?? ''}',
                            qr: '${e['qr_code'] ?? ''}',
                            status: 'Pending',
                            statusColor: const Color(0xFFF5A623),
                            subtitle: 'Awaiting staff approval',
                            icon: Icons.pending_actions_rounded,
                          ),
                        )),
                        ..._activeLoans.take(3).map((e) {
                          final due = DateTime.tryParse(
                              '${e['due_date']}'.replaceAll(' ', 'T'));
                          final now2 = DateTime.now();
                          final isOverdue = due != null && due.isBefore(now2);
                          final isDueToday = due != null &&
                              due.year == now2.year &&
                              due.month == now2.month &&
                              due.day == now2.day;
                          final status = isOverdue ? 'Overdue'
                              : isDueToday ? 'Due Today' : 'Active';
                          final statusColor = isOverdue
                              ? const Color(0xFFEF4444)
                              : isDueToday
                                  ? const Color(0xFFD97706)
                                  : const Color(0xFF059669);
                          final dueStr = due != null
                              ? '${due.month}/${due.day} · 5:00 PM'
                              : '';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _LoanItemCard(
                              name: '${e['equipment_name'] ?? ''}',
                              qr: '${e['qr_code'] ?? ''}',
                              status: status,
                              statusColor: statusColor,
                              subtitle: 'Return by $dueStr',
                              icon: isOverdue
                                  ? Icons.warning_amber_rounded
                                  : isDueToday
                                      ? Icons.access_alarm_rounded
                                      : Icons.check_circle_outline_rounded,
                            ),
                          );
                        }),
                      ],
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Dashboard Helper Widgets ──────────────────────────────────────────────────

class _HeroStat extends StatelessWidget {
  final String value, label;
  final IconData icon;
  final Color accent;
  const _HeroStat({required this.value, required this.label,
      required this.icon, required this.accent});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x1FFFFFFF)),
        ),
        child: Column(children: [
          Icon(icon, color: accent, size: 18),
          const SizedBox(height: 5),
          Text(value, style: const TextStyle(
              color: Colors.white, fontSize: 18,
              fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(label, textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xAAFFFFFF),
                  fontSize: 9, height: 1.2)),
        ]),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  const _SectionTitle({required this.title, required this.icon, required this.color});
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
            color: color.withAlpha(31),
            borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, color: color, size: 15),
      ),
      const SizedBox(width: 8),
      Text(title, style: TextStyle(
          fontSize: 14, fontWeight: FontWeight.bold, color: color)),
    ]);
  }
}

class _AlertCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, body;
  const _AlertCard({required this.icon, required this.color,
      required this.title, required this.body});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: color, width: 4)),
        boxShadow: [BoxShadow(color: color.withAlpha(15),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
              color: color.withAlpha(26),
              borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, color: color, size: 18)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.bold,
                color: Color(0xFF1A1D2E))),
            const SizedBox(height: 2),
            Text(body, style: const TextStyle(
                fontSize: 12, color: Color(0xFF6B7280), height: 1.3)),
          ])),
      ]),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final List<Color> gradient;
  final VoidCallback onTap;
  const _ActionTile({required this.icon, required this.label,
      required this.gradient, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 80,
          decoration: BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradient),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(
                color: gradient.last.withValues(alpha: 0.3),
                blurRadius: 8, offset: const Offset(0, 4))],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(height: 5),
              Text(label, textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 10,
                      fontWeight: FontWeight.w600, height: 1.2)),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoanItemCard extends StatelessWidget {
  final String name, qr, status, subtitle;
  final Color statusColor;
  final IconData icon;
  const _LoanItemCard({required this.name, required this.qr,
      required this.status, required this.subtitle,
      required this.statusColor, required this.icon});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: const Color(0x0A000000),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: statusColor, size: 20)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.bold,
                color: Color(0xFF1A1D2E))),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(
                fontSize: 11, color: Color(0xFF6B7280))),
            const SizedBox(height: 4),
            Text(qr, style: const TextStyle(
                fontSize: 10, color: Color(0xFF9CA3AF),
                fontFamily: 'Courier New')),
          ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20)),
          child: Text(status, style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold,
              color: statusColor))),
      ]),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  const _EmptyCard({required this.icon, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: const Color(0x08000000),
              blurRadius: 8, offset: const Offset(0, 2))]),
      child: Center(child: Column(children: [
        Icon(icon, size: 36, color: const Color(0xFF9CA3AF)),
        const SizedBox(height: 8),
        Text(title, style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 14,
            color: Color(0xFF374151))),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(
            fontSize: 12, color: Color(0xFF9CA3AF))),
      ])),
    );
  }
}



// ─── Equipment Catalog Screen ─────────────────────────────────────────────────

class EquipmentCatalogScreen extends StatefulWidget {
  const EquipmentCatalogScreen({super.key});
  @override
  State<EquipmentCatalogScreen> createState() => _EquipmentCatalogScreenState();
}

class _EquipmentCatalogScreenState extends State<EquipmentCatalogScreen> {
  String _search = '';
  final Set<String> _selectedCategories = {};
  final _categories = _kCategories;
  bool _dropdownOpen = false;
  bool _showAllCourses = false;
  bool _loading = true;
  bool _hasError = false;
  List<dynamic> _items = [];

  // Pagination — the catalog loads a screenful at a time rather than the whole
  // equipment collection (see ApiService.getEquipmentPage).
  static const int _pageSize = 20;
  final _scrollController = ScrollController();
  DocumentSnapshot? _cursor;
  bool _hasMore = true;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadEquipment();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) _loadMore();
  }

  // First page / pull-to-refresh — resets the cursor.
  Future<void> _loadEquipment() async {
    setState(() {
      _loading = true;
      _hasError = false;
      _items = [];
      _cursor = null;
      _hasMore = true;
    });
    try {
      final page = await ApiService.getEquipmentPage(limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _hasError = true; });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ApiService.getEquipmentPage(
          limit: _pageSize, startAfter: _cursor);
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page.items];
        _cursor = page.cursor ?? _cursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Keep what is already loaded; the next scroll retries.
      setState(() => _loadingMore = false);
    }
  }

  String get _filterLabel {
    if (_selectedCategories.isEmpty) return 'All Categories';
    if (_selectedCategories.length == 1) return _selectedCategories.first;
    return '${_selectedCategories.length} categories';
  }

  void _toggleCategory(String cat) {
    setState(() {
      if (_selectedCategories.contains(cat)) _selectedCategories.remove(cat);
      else _selectedCategories.add(cat);
    });
  }

  void _clearFilters() => setState(() => _selectedCategories.clear());

  // Trailing row of the catalog list: paging spinner, an empty-result message,
  // or a quiet end-of-list marker.
  Widget _listFooter(bool isEmpty) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
              width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Column(children: [
          Icon(Icons.search_off_rounded, size: 44, color: AppTheme.textLight),
          SizedBox(height: 10),
          Text('No equipment matches your filters',
              style: TextStyle(color: AppTheme.textMid)),
        ]),
      );
    }
    if (!_hasMore) {
      return const Padding(
        padding: EdgeInsets.only(top: 16, bottom: 4),
        child: Center(
          child: Text('End of catalog',
              style: TextStyle(fontSize: 11, color: AppTheme.textLight)),
        ),
      );
    }
    return const SizedBox(height: 4);
  }

  @override
  Widget build(BuildContext context) {
    final studentCourse = Session.course;
    final filtered = _items.where((e) {
      final matchCat = _selectedCategories.isEmpty ||
          _selectedCategories.contains(e['category']);
      final matchSearch = _search.isEmpty ||
          (e['equipment_name'] as String).toLowerCase().contains(_search.toLowerCase());
      final itemCourses = (e['courses'] as List?)?.cast<String>() ?? [];
      final matchCourse = _showAllCourses ||
          studentCourse.isEmpty ||
          itemCourses.isEmpty ||
          itemCourses.contains(studentCourse);
      return matchCat && matchSearch && matchCourse;
    }).toList();

    // Filters run over the pages loaded so far, so an active search or category
    // can leave the screen looking empty while matches sit further down the
    // collection. Pull the next page until there is enough to fill the list or
    // the collection runs out.
    if (filtered.length < _pageSize && _hasMore && !_loadingMore && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Equipment Catalog')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _hasError
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.wifi_off_rounded, size: 52, color: AppTheme.textLight),
                      const SizedBox(height: 16),
                      const Text('Failed to load equipment',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
                      const SizedBox(height: 8),
                      const Text('Check your internet connection and try again.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: _loadEquipment,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try Again'),
                      ),
                    ]),
                  ),
                )
          : Column(
        children: [
          // Search + Filter
          Container(
            color: AppTheme.primary,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Search bar
                TextField(
                  onChanged: (v) => setState(() => _search = v),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search equipment...',
                    hintStyle: const TextStyle(color: AppTheme.textLight),
                    prefixIcon: const Icon(Icons.search_rounded,
                        color: AppTheme.textLight),
                    filled: true,
                    fillColor: const Color(0x1AFFFFFF),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: AppTheme.accent, width: 1.5)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const SizedBox(height: 10),
                // Multi-select dropdown button
                GestureDetector(
                  onTap: () => setState(() => _dropdownOpen = !_dropdownOpen),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0x1AFFFFFF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: _selectedCategories.isNotEmpty
                              ? AppTheme.accent
                              : const Color(0x33FFFFFF),
                          width: _selectedCategories.isNotEmpty ? 1.5 : 1),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.filter_list_rounded,
                            color: AppTheme.textLight, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _filterLabel,
                            style: TextStyle(
                              color: _selectedCategories.isNotEmpty
                                  ? AppTheme.accent
                                  : AppTheme.textLight,
                              fontSize: 13,
                              fontWeight: _selectedCategories.isNotEmpty
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        // Active filter chips inline
                        if (_selectedCategories.isNotEmpty) ...[
                          GestureDetector(
                            onTap: _clearFilters,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                  color: const Color(0x33F5A623),
                                  borderRadius: BorderRadius.circular(10)),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('Clear',
                                      style: TextStyle(
                                          color: AppTheme.accent,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold)),
                                  SizedBox(width: 2),
                                  Icon(Icons.close_rounded,
                                      size: 12, color: AppTheme.accent),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        AnimatedRotation(
                          turns: _dropdownOpen ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(Icons.keyboard_arrow_down_rounded,
                              color: AppTheme.textLight, size: 20),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Dropdown panel (shown below header, above list)
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            height: _dropdownOpen ? (_categories.length * 52.0) : 0,
            child: Container(
              color: Colors.white,
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  children: [
                    // "Select All" / "Clear All" row
                    InkWell(
                      onTap: () {
                        setState(() {
                          if (_selectedCategories.length ==
                              _categories.length) {
                            _selectedCategories.clear();
                          } else {
                            _selectedCategories
                                .addAll(_categories);
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: _selectedCategories.length ==
                                        _categories.length
                                    ? AppTheme.primary
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: _selectedCategories.length ==
                                            _categories.length
                                        ? AppTheme.primary
                                        : AppTheme.textLight),
                              ),
                              child: _selectedCategories.length ==
                                      _categories.length
                                  ? const Icon(Icons.check_rounded,
                                      color: Colors.white, size: 14)
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            const Text('Select All',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.textDark)),
                          ],
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: AppTheme.divider),
                    ..._categories.map((cat) {
                      final checked =
                          _selectedCategories.contains(cat);
                      return InkWell(
                        onTap: () => _toggleCategory(cat),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: Row(
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: checked
                                      ? AppTheme.primary
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: checked
                                          ? AppTheme.primary
                                          : AppTheme.textLight),
                                ),
                                child: checked
                                    ? const Icon(Icons.check_rounded,
                                        color: Colors.white, size: 14)
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Text(cat,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: checked
                                          ? AppTheme.primary
                                          : AppTheme.textDark,
                                      fontWeight: checked
                                          ? FontWeight.w600
                                          : FontWeight.normal)),
                              const Spacer(),
                              // Item count badge per category
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: checked
                                      ? const Color(0x1A1B3A8C)
                                      : AppTheme.surface,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${_items.where((e) => e['category'] == cat).length}',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: checked
                                          ? AppTheme.primary
                                          : AppTheme.textMid,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
          // Active filter tags row
          if (_selectedCategories.isNotEmpty)
            Container(
              color: AppTheme.surface,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Text('Filtered: ',
                      style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMid,
                          fontWeight: FontWeight.w600)),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _selectedCategories.map((cat) {
                          return Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0x1A1B3A8C),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color:
                                      const Color(0x4D1B3A8C)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(cat,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.primary,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: () => _toggleCategory(cat),
                                  child: const Icon(Icons.close_rounded,
                                      size: 12, color: AppTheme.primary),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (Session.course.isNotEmpty)
            Container(
              color: const Color(0xFFF0F4FF),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.school_outlined, size: 14, color: AppTheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    _showAllCourses
                        ? 'Showing all programs'
                        : 'Showing equipment for ${courseLabel(Session.course)}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _showAllCourses = !_showAllCourses),
                    child: Text(
                      _showAllCourses ? 'My program only' : 'Show all',
                      style: const TextStyle(fontSize: 12, color: AppTheme.accent, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.separated(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              cacheExtent: 500,
              // One extra row for the paging footer.
              itemCount: filtered.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                if (i == filtered.length) return _listFooter(filtered.isEmpty);
                final e = filtered[i];
                final isAvailable = (e['status'] ?? 'Available') == 'Available';
                final category = e['category'] as String? ?? '';
                return GestureDetector(
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => EquipmentDetailScreen(equipment: e))),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border(
                        left: BorderSide(
                          color: isAvailable ? AppTheme.success : AppTheme.danger,
                          width: 4,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        EquipmentThumb(
                          bytes: photoThumbOf(e),
                          category: category,
                          color: isAvailable ? AppTheme.success : AppTheme.danger,
                          size: 50,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e['equipment_name'] as String,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: AppTheme.textDark)),
                              const SizedBox(height: 2),
                              Text('${e['qr_code']}  •  $category',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.textMid)),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  StatusBadge(
                                    label: e['status'] ?? 'Available',
                                    color: isAvailable ? AppTheme.success : AppTheme.danger,
                                  ),
                                  if (e['location'] != null && e['location'].toString().isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    StatusBadge(label: e['location'], color: AppTheme.textMid),
                                  ],
                                ],
                              ),
                              if (((e['courses'] as List?)?.isNotEmpty ?? false)) ...[
                                const SizedBox(height: 6),
                                Row(children: [
                                  const Icon(Icons.school_outlined,
                                      size: 12, color: AppTheme.primary),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      'For: ${(e['courses'] as List).map((c) => courseLabel('$c')).join(', ')}',
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppTheme.primary,
                                          fontWeight: FontWeight.w600),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ]),
                              ],
                            ],
                          ),
                        ),
                        Icon(
                            isAvailable
                                ? Icons.arrow_forward_ios_rounded
                                : Icons.block_rounded,
                            size: 16,
                            color: isAvailable
                                ? AppTheme.accent
                                : AppTheme.danger),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Equipment Detail Screen ───────────────────────────────────────────────────

class EquipmentDetailScreen extends StatefulWidget {
  final Map<String, dynamic> equipment;
  const EquipmentDetailScreen({super.key, required this.equipment});
  @override
  State<EquipmentDetailScreen> createState() => _EquipmentDetailScreenState();
}

class _EquipmentDetailScreenState extends State<EquipmentDetailScreen> {
  Map<String, dynamic> get equipment => widget.equipment;

  // The list thumbnail is already on the record; the larger copy lives in its
  // own document and is fetched only here, when someone actually looks at it.
  Uint8List? _fullPhoto;

  @override
  void initState() {
    super.initState();
    _fullPhoto = photoThumbOf(widget.equipment);
    final id = '${widget.equipment['equipment_id'] ?? ''}';
    if (id.isNotEmpty) {
      ApiService.getEquipmentPhoto(id).then((bytes) {
        if (!mounted || bytes == null) return;
        setState(() => _fullPhoto = bytes);
      }).catchError((_) {});
    }
  }

  IconData _categoryIcon(String cat) {
    switch (cat.toLowerCase()) {
      case 'electronics':     return Icons.electric_bolt_rounded;
      case 'tools':           return Icons.build_rounded;
      case 'measurement':     return Icons.straighten_rounded;
      case 'optics':          return Icons.remove_red_eye_rounded;
      case 'microcontroller': return Icons.memory_rounded;
      default:                return Icons.science_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final name      = equipment['equipment_name'] as String? ?? '';
    final category  = equipment['category']       as String? ?? '';
    final status    = equipment['status']         as String? ?? 'Available';
    final location  = equipment['location']       as String? ?? '';
    final qrCode    = equipment['qr_code']        as String? ?? '';
    final brand     = equipment['brand']          as String? ?? '';
    final model     = equipment['model']          as String? ?? '';
    final serial    = equipment['serial_number']  as String? ?? '';
    final desc      = equipment['description']    as String? ?? '';
    final photo     = _fullPhoto;
    final hasPhoto  = photo != null && photo.isNotEmpty;
    final courses   = (equipment['courses'] as List?)?.cast<String>() ?? [];
    final equipId   = '${equipment['equipment_id'] ?? ''}';
    final isAvail   = status == 'Available';
    final isStudent = Session.role == 'student';

    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: CustomScrollView(
        slivers: [
          // ── App bar with collapsing image ──
          SliverAppBar(
            expandedHeight: hasPhoto ? 260 : 160,
            pinned: true,
            backgroundColor: AppTheme.primary,
            iconTheme: const IconThemeData(color: Colors.white),
            flexibleSpace: FlexibleSpaceBar(
              background: hasPhoto
                  ? Stack(fit: StackFit.expand, children: [
                      // Starts as the thumbnail already in hand, then swaps to
                      // the full-size copy once it arrives.
                      Image.memory(
                        photo,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stack) =>
                            _imageFallback(category),
                      ),
                      // Dark gradient so text is readable
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x33000000), Color(0xAA000000)],
                          ),
                        ),
                      ),
                    ])
                  : _imageFallback(category),
              title: Text(name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              titlePadding: const EdgeInsets.fromLTRB(56, 0, 16, 16),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Status + Category row ──
                  Row(children: [
                    StatusBadge(
                      label: status,
                      color: isAvail ? AppTheme.success : AppTheme.danger,
                    ),
                    const SizedBox(width: 8),
                    StatusBadge(label: category, color: AppTheme.primary),
                    if (location.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      StatusBadge(
                        label: location,
                        color: AppTheme.textMid,
                      ),
                    ],
                  ]),
                  const SizedBox(height: 20),

                  // ── Description ──
                  if (desc.isNotEmpty) ...[
                    const Text('About this equipment',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textDark)),
                    const SizedBox(height: 8),
                    Text(desc,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textMid,
                            height: 1.6)),
                    const SizedBox(height: 20),
                  ],

                  // ── Specifications table ──
                  const Text('Specifications',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textDark)),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.divider),
                    ),
                    child: Column(children: [
                      if (brand.isNotEmpty)
                        _specRow('Brand / Manufacturer', brand, isFirst: true),
                      if (model.isNotEmpty)
                        _specRow('Model', model, isFirst: brand.isEmpty),
                      if (serial.isNotEmpty)
                        _specRow('Serial Number', serial,
                            isFirst: brand.isEmpty && model.isEmpty),
                      _specRow('Category', category,
                          isFirst: brand.isEmpty && model.isEmpty && serial.isEmpty),
                      if (location.isNotEmpty) _specRow('Storage Location', location),
                      _specRow('Status', status, isLast: courses.isEmpty),
                      if (courses.isNotEmpty)
                        _specRow('Available to', courses.map((c) => courseLabel(c)).join(', '), isLast: true),
                    ]),
                  ),
                  // ── QR Code card ──
                  if (qrCode.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text('QR Code',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textDark)),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppTheme.divider),
                      ),
                      child: Column(children: [
                        QrImageView(
                          data: qrCode,
                          version: QrVersions.auto,
                          size: 180,
                          eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: AppTheme.primary),
                          dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: AppTheme.primary),
                        ),
                        const SizedBox(height: 8),
                        Text(qrCode,
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textMid,
                                letterSpacing: 1.2)),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 28),

                  // ── Borrow button (students only, available only) ──
                  if (isStudent)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: isAvail
                            ? () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => BorrowRequestScreen(
                                        equipmentName: name,
                                        equipmentId: equipId,
                                        equipment: equipment)))
                            : null,
                        icon: Icon(isAvail
                            ? Icons.assignment_outlined
                            : Icons.block_rounded),
                        label: Text(
                            isAvail ? 'Borrow This Equipment' : 'Currently Unavailable'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              isAvail ? AppTheme.primary : AppTheme.textLight,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageFallback(String category) {
    return Container(
      color: AppTheme.primary,
      child: Center(
        child: Icon(_categoryIcon(category), size: 72, color: Colors.white24),
      ),
    );
  }
}

Widget _specRow(String label, String value,
    {bool isFirst = false, bool isLast = false}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      border: Border(
        top: isFirst ? BorderSide.none : const BorderSide(color: AppTheme.divider),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textMid,
                  fontWeight: FontWeight.w500)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textDark,
                  fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
}

// ─── Equipment Picker Sheet ───────────────────────────────────────────────────
// Bottom sheet behind the borrow form's equipment field. Pages through the
// collection (see ApiService.getEquipmentPage) rather than reading all of it,
// and pops with the chosen record.

class _EquipmentPickerSheet extends StatefulWidget {
  final String selectedId;
  const _EquipmentPickerSheet({required this.selectedId});
  @override
  State<_EquipmentPickerSheet> createState() => _EquipmentPickerSheetState();
}

class _EquipmentPickerSheetState extends State<_EquipmentPickerSheet> {
  static const int _pageSize = 20;
  final _scrollController = ScrollController();
  final List<Map<String, dynamic>> _items = [];
  DocumentSnapshot? _cursor;
  bool _loading     = true;
  bool _loadingMore = false;
  bool _hasMore     = true;
  bool _failed      = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadMore();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) _loadMore();
  }

  // Only 'Available' equipment is offered. That filter runs on the client,
  // because combining it with the name ordering server-side would need a
  // composite index (see the TODO in _AdminInventoryScreenState), so a page
  // can arrive with nothing to show — build() keeps pulling until it does.
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final page = await ApiService.getEquipmentPage(
          limit: _pageSize, startAfter: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items.where((e) => e['status'] == 'Available'));
        _cursor      = page.cursor ?? _cursor;
        _hasMore     = page.hasMore;
        _loading     = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed      = _items.isEmpty;
        _hasMore     = false;
        _loading     = false;
        _loadingMore = false;
      });
    }
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(
          child: Text('No available equipment.',
              style: TextStyle(color: AppTheme.textMid)),
        ),
      );
    }
    return const SizedBox(height: 4);
  }

  @override
  Widget build(BuildContext context) {
    // Every item loaded so far was filtered out — pull the next page.
    if (!_loading && !_loadingMore && _hasMore && _items.length < _pageSize) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    }

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(children: [
        // Handle
        Container(
          margin: const EdgeInsets.only(top: 12),
          width: 40, height: 4,
          decoration: BoxDecoration(
              color: AppTheme.divider,
              borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Icon(Icons.science_outlined, color: AppTheme.primary, size: 20),
            SizedBox(width: 10),
            Text('Select Equipment',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                    color: AppTheme.textDark)),
          ]),
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text('Only available equipment is shown.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMid)),
        ),
        const SizedBox(height: 12),
        const Divider(color: AppTheme.divider, height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _failed
                  ? const Center(
                      child: Text('Could not load equipment.',
                          style: TextStyle(color: AppTheme.textMid)))
                  : ListView.separated(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      // One extra row for the paging footer.
                      itemCount: _items.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        if (i == _items.length) return _footer();
                        final e = _items[i];
                        final isSelected =
                            widget.selectedId == '${e['equipment_id']}';
                        return GestureDetector(
                          onTap: () => Navigator.pop(context, e),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0x121B3A8C)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: isSelected
                                      ? AppTheme.primary
                                      : AppTheme.divider),
                            ),
                            child: Row(children: [
                              EquipmentThumb(
                                bytes: photoThumbOf(e),
                                category: e['category'] as String? ?? '',
                                color: AppTheme.success,
                                size: 40,
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(e['equipment_name'] as String,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: AppTheme.textDark)),
                                Text('${e['qr_code']}  •  ${e['category']}',
                                    style: const TextStyle(
                                        fontSize: 12, color: AppTheme.textMid)),
                              ])),
                              StatusBadge(label: 'Available', color: AppTheme.success),
                              if (isSelected) ...[
                                const SizedBox(width: 8),
                                const Icon(Icons.check_circle_rounded,
                                    color: AppTheme.primary, size: 20),
                              ],
                            ]),
                          ),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}

// ─── Borrow Request Screen ─────────────────────────────────────────────────────

class BorrowRequestScreen extends StatefulWidget {
  final String? equipmentName;
  final String equipmentId; // Firebase doc ID is a String
  // Full equipment record when the student arrives from the catalog, so the
  // confirmation card can show the photo without re-reading the document.
  final Map<String, dynamic>? equipment;
  const BorrowRequestScreen({
    super.key,
    this.equipmentName,
    this.equipmentId = '',
    this.equipment,
  });
  @override
  State<BorrowRequestScreen> createState() => _BorrowRequestScreenState();
}

class _BorrowRequestScreenState extends State<BorrowRequestScreen> {
  int _qty = 1;
  bool _loading = false;
  bool _agreedToPolicies = false;
  final _nameCtrl    = TextEditingController();
  final _idCtrl      = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _purposeCtrl = TextEditingController();

  // Selected equipment — Firebase doc ID stored as String
  String _selectedEquipmentId   = '';
  String _selectedEquipmentName = '';
  // Full record of the selection, so the student can check the photo and the
  // identifying details before submitting and avoid requesting the wrong item.
  Map<String, dynamic> _selectedEquipment = {};

  String _sel(String key) => '${_selectedEquipment[key] ?? ''}';

  // Borrow time — default now, return time — default 5:00 PM
  TimeOfDay _borrowTime = TimeOfDay.now();
  TimeOfDay _returnTime = const TimeOfDay(hour: 17, minute: 0);

  // Build DateTime from today + selected TimeOfDay
  DateTime _toDateTime(TimeOfDay t) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, t.hour, t.minute, 0);
  }

  String _formatTime(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    final p = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:$m $p';
  }

  Future<void> _pickBorrowTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _borrowTime,
      helpText: 'Select Borrow Time',
    );
    if (picked != null) setState(() => _borrowTime = picked);
  }

  Future<void> _pickReturnTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _returnTime,
      helpText: 'Select Return Time',
    );
    if (picked != null) {
      // Enforce max 5:00 PM
      final maxReturn = const TimeOfDay(hour: 17, minute: 0);
      if (picked.hour > 17 || (picked.hour == 17 && picked.minute > 0)) {
        setState(() => _returnTime = maxReturn);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Return time cannot be later than 5:00 PM.'),
            backgroundColor: AppTheme.warning,
            behavior: SnackBarBehavior.floating,
          ));
        }
      } else {
        setState(() => _returnTime = picked);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = Session.name;
    _idCtrl.text   = Session.studentNumber;
    // Pre-fill if coming from catalog
    _selectedEquipmentId   = widget.equipmentId;
    _selectedEquipmentName = widget.equipmentName ?? '';
    _selectedEquipment     = widget.equipment ?? {};
    // Arrived with an id but no record (e.g. an older call site) — fetch just
    // that document so the confirmation card still shows the photo.
    if (_selectedEquipmentId.isNotEmpty && _selectedEquipment.isEmpty) {
      ApiService.getEquipmentById(_selectedEquipmentId).then((match) {
        if (!mounted || match == null) return;
        setState(() => _selectedEquipment = match);
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _idCtrl.dispose();
    _subjectCtrl.dispose();
    _purposeCtrl.dispose();
    super.dispose();
  }

  // Opens a bottom sheet to pick equipment from the catalog
  Future<void> _pickEquipment() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EquipmentPickerSheet(selectedId: _selectedEquipmentId),
    );
    if (picked == null) return;
    setState(() {
      _selectedEquipmentId   = '${picked['equipment_id']}';
      _selectedEquipmentName = picked['equipment_name'] as String;
      _selectedEquipment     = picked;
    });
  }

  Future<void> _submitRequest() async {
    if (_selectedEquipmentId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an equipment first.'),
            backgroundColor: AppTheme.danger));
      return;
    }
    if (!_agreedToPolicies) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please read and agree to the Laboratory Policies first.'),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating));
      return;
    }
    if (Session.isOnHold) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          icon: const Icon(Icons.gpp_bad_rounded, color: AppTheme.danger, size: 48),
          title: const Text('Borrowing on Hold'),
          content: Text(
              Session.holdReason.isNotEmpty
                  ? Session.holdReason
                  : 'Your borrowing privileges are on hold. Please see the '
                      'laboratory staff to settle the penalty.',
              textAlign: TextAlign.center),
          actions: [
            ElevatedButton(
                onPressed: () => Navigator.pop(context), child: const Text('OK'))
          ],
        ),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ApiService.borrowEquipment({
        'student_id':     Session.currentUser?['student_id']?.toString() ?? '',
        'equipment_id':   _selectedEquipmentId,
        'borrower_name':  _nameCtrl.text.trim(),
        'student_number': _idCtrl.text.trim(),
        'subject':        _subjectCtrl.text.trim(),
        'quantity':       _qty,
        'borrow_date':    _toDateTime(_borrowTime).toIso8601String(),
        'due_date':       _toDateTime(_returnTime).toIso8601String(),
        'purpose':        _purposeCtrl.text.trim(),
      });
      if (!mounted) return;
      if (res['success'] == true) {
        showDialog(context: context, barrierDismissible: false,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            icon: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 52),
            title: const Text('Request Submitted!'),
            content: const Text('Your borrowing request has been submitted and is awaiting staff approval. Please return the equipment before 5:00 PM today.',
                textAlign: TextAlign.center),
            actions: [ElevatedButton(
              onPressed: () { Navigator.pop(context); Navigator.pop(context); },
              child: const Text('Done'))],
          ));
      } else {
        // A program/course restriction gets its own clearer presentation; other
        // failures fall back to the generic error dialog. Either way the full
        // message is shown so it can be read completely.
        final restricted = res['course_restricted'] == true;
        showDialog(context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            icon: Icon(
                restricted ? Icons.school_outlined : Icons.error_outline_rounded,
                color: AppTheme.danger, size: 48),
            title: Text(restricted ? 'Not Available to Your Program' : 'Submission Failed'),
            content: Text(res['message'] ?? 'Unknown error.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13)),
            actions: [ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'))],
          ));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ApiService._friendlyError(e)), backgroundColor: AppTheme.danger,
            duration: const Duration(seconds: 6)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Borrow Request')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Equipment picker — tappable
            GestureDetector(
              onTap: _pickEquipment,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: _selectedEquipmentId.isEmpty
                        ? const Color(0x0FF5A623)
                        : const Color(0x0F06D6A0),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: _selectedEquipmentId.isEmpty
                            ? const Color(0x4DF5A623)
                            : AppTheme.success.withValues(alpha: 0.3))),
                child: Row(
                  children: [
                    if (_selectedEquipmentId.isEmpty)
                      Container(
                        width: 48, height: 48,
                        decoration: BoxDecoration(
                            color: AppTheme.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.add_circle_outline_rounded,
                            color: AppTheme.accent),
                      )
                    else
                      EquipmentThumb(
                        bytes: photoThumbOf(_selectedEquipment),
                        category: _sel('category'),
                        color: AppTheme.success,
                        size: 64,
                      ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedEquipmentId.isEmpty
                                ? 'Tap to Select Equipment'
                                : _selectedEquipmentName,
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: _selectedEquipmentId.isEmpty
                                    ? AppTheme.accent
                                    : AppTheme.textDark),
                          ),
                          const SizedBox(height: 2),
                          // Identifying details, so two similar-looking items
                          // are not mistaken for one another.
                          if (_selectedEquipmentId.isNotEmpty) ...[
                            if (_sel('qr_code').isNotEmpty)
                              Text(
                                [_sel('qr_code'), _sel('category')]
                                    .where((s) => s.isNotEmpty)
                                    .join('  •  '),
                                style: const TextStyle(
                                    fontSize: 12, color: AppTheme.textMid),
                              ),
                            if (_sel('brand').isNotEmpty ||
                                _sel('model').isNotEmpty)
                              Text(
                                [_sel('brand'), _sel('model')]
                                    .where((s) => s.isNotEmpty)
                                    .join(' '),
                                style: const TextStyle(
                                    fontSize: 12, color: AppTheme.textMid),
                              ),
                            const SizedBox(height: 2),
                          ],
                          Text(
                            _selectedEquipmentId.isEmpty
                                ? 'Required — choose from available equipment'
                                : 'Check the photo, then tap to change selection',
                            style: const TextStyle(
                                fontSize: 12, color: AppTheme.textMid),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: _selectedEquipmentId.isEmpty
                          ? AppTheme.accent
                          : AppTheme.success,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            _FieldLabel('Borrower Name'),
            const SizedBox(height: 8),
            TextField(controller: _nameCtrl, decoration: const InputDecoration(hintText: 'e.g. Juan Santos')),
            const SizedBox(height: 16),
            _FieldLabel('Student ID'),
            const SizedBox(height: 8),
            TextField(controller: _idCtrl, decoration: const InputDecoration(hintText: 'e.g. 26-12345-123')),
            const SizedBox(height: 16),
            _FieldLabel('Subject / Section'),
            const SizedBox(height: 8),
            TextField(controller: _subjectCtrl, decoration: const InputDecoration(hintText: 'e.g. PHYS101 - Sec A')),
            const SizedBox(height: 16),
            _FieldLabel('Quantity'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.divider)),
              child: Row(
                children: [
                  IconButton(
                      onPressed: () => setState(() => _qty = (_qty - 1).clamp(1, 10)),
                      icon: const Icon(Icons.remove_rounded)),
                  Expanded(child: Center(child: Text('$_qty',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
                  IconButton(
                      onPressed: () => setState(() => _qty = (_qty + 1).clamp(1, 10)),
                      icon: const Icon(Icons.add_rounded)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // ── Time Selection ──
            Row(children: [
              // Borrow Time
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _FieldLabel('Borrow Time'),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: _pickBorrowTime,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.divider),
                        ),
                        child: Row(children: [
                          const Icon(Icons.access_time_rounded,
                              color: AppTheme.primary, size: 18),
                          const SizedBox(width: 8),
                          Text(_formatTime(_borrowTime),
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textDark)),
                        ]),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Return Time
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _FieldLabel('Return Time'),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: _pickReturnTime,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: _returnTime.hour >= 17
                                  ? AppTheme.warning
                                  : AppTheme.divider),
                        ),
                        child: Row(children: [
                          Icon(Icons.timer_outlined,
                              color: _returnTime.hour >= 17
                                  ? AppTheme.warning
                                  : AppTheme.primary,
                              size: 18),
                          const SizedBox(width: 8),
                          Text(_formatTime(_returnTime),
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: _returnTime.hour >= 17
                                      ? AppTheme.warning
                                      : AppTheme.textDark)),
                        ]),
                      ),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 6),
            const Text('⚠️ Equipment must be returned before 5:00 PM.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMid)),
            const SizedBox(height: 16),
            // ── Return Deadline info ──
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0x14FFB703),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x4DFFB703)),
              ),
              child: Row(children: [
                const Icon(Icons.access_time_rounded,
                    color: AppTheme.warning, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text('Return Deadline',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.warning)),
                    const SizedBox(height: 2),
                    Text(
                        'Selected return time: ${_formatTime(_returnTime)}. All equipment must be returned today.',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textDark)),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            _FieldLabel('Purpose / Notes'),
            const SizedBox(height: 8),
            TextField(
              controller: _purposeCtrl,
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'Describe the purpose of borrowing...'),
            ),
            const SizedBox(height: 20),

            // ── Lab Policies Agreement ──
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0x0A1B3A8C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x261B3A8C)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.policy_rounded,
                        color: AppTheme.primary, size: 16),
                    const SizedBox(width: 6),
                    const Text('Laboratory Policies',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primary)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(
                              builder: (_) => const LabPoliciesScreen())),
                      child: const Text('View All',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.accent,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.underline)),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  // Quick policy reminders
                  _PolicyReminder(
                    icon: Icons.warning_amber_rounded,
                    color: AppTheme.danger,
                    text: 'Damaged or missing equipment must be replaced.',
                  ),
                  const SizedBox(height: 6),
                  _PolicyReminder(
                    icon: Icons.access_time_rounded,
                    color: AppTheme.warning,
                    text: 'Return before 5:00 PM. Late returns lose borrowing privileges.',
                  ),
                  const SizedBox(height: 6),
                  _PolicyReminder(
                    icon: Icons.today_rounded,
                    color: AppTheme.primary,
                    text: 'Reservations are for same-day use only.',
                  ),
                  const SizedBox(height: 10),
                  // Agreement checkbox
                  GestureDetector(
                    onTap: () => setState(() => _agreedToPolicies = !_agreedToPolicies),
                    child: Row(children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 20, height: 20,
                        decoration: BoxDecoration(
                          color: _agreedToPolicies
                              ? AppTheme.primary
                              : Colors.white,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                              color: _agreedToPolicies
                                  ? AppTheme.primary
                                  : AppTheme.divider,
                              width: 1.5),
                        ),
                        child: _agreedToPolicies
                            ? const Icon(Icons.check_rounded,
                                color: Colors.white, size: 14)
                            : null,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'I have read and agree to the Laboratory Equipment Policies.',
                          style: TextStyle(fontSize: 12, color: AppTheme.textDark),
                        ),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _submitRequest,
                icon: _loading
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.send_rounded),
                label: const Text('Submit Request'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Policy Reminder widget ─────────────────────────────────────────────────────
class _PolicyReminder extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _PolicyReminder({required this.icon, required this.color, required this.text});
  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 14),
      const SizedBox(width: 6),
      Expanded(child: Text(text,
          style: const TextStyle(fontSize: 11, color: AppTheme.textMid, height: 1.4))),
    ]);
  }
}



// ─── Lab Policies Screen ──────────────────────────────────────────────────────

class LabPoliciesScreen extends StatelessWidget {
  const LabPoliciesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const policies = [
      {
        'title': 'Damaged or Missing Equipment Policy',
        'icon': '⚠️',
        'color': 0xFFEF4444,
        'body':
            'If a borrowed equipment is returned damaged or with missing parts, the student is required to replace the item with the same type or equivalent condition. The replacement does not need to be brand new, but it must be functional and acceptable to the staff.\n\nFailure to replace the damaged or missing equipment will result in the student\'s clearance not being signed or approved.',
      },
      {
        'title': 'Late Return Policy',
        'icon': '🕐',
        'color': 0xFFFFB703,
        'body':
            'Students who fail to return borrowed equipment on the agreed return date and time will be considered late returnees.\n\nLate returnees may temporarily lose their borrowing privileges for a certain period determined by the laboratory staff.',
      },
      {
        'title': 'Reservation Policy',
        'icon': '📅',
        'color': 0xFF1B3A8C,
        'body':
            'Equipment reservations are only allowed for the same day. Students must specify the exact borrowing time and expected return time during the reservation process.\n\nReservations are subject to equipment availability and staff approval.',
      },
      {
        'title': 'Outside Campus Equipment Usage Policy',
        'icon': '🏫',
        'color': 0xFF7C3AED,
        'body':
            'If a student needs to use laboratory equipment outside the campus or university premises, they are required to submit a formal request or report explaining the purpose and reason for external usage.\n\nThe request must be reviewed and approved by the laboratory staff before the equipment can be released.',
      },
      {
        'title': 'Inventory and Serial Number Policy',
        'icon': '📋',
        'color': 0xFF059669,
        'body':
            'All laboratory equipment must be recorded in the inventory system. Large equipment, tools, or high-value items are required to have a unique serial number for tracking purposes, while small equipment or minor tools may be recorded without a serial number.',
      },
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Laboratory Policies')),
      body: Column(
        children: [
          // Header banner
          Container(
            width: double.infinity,
            color: AppTheme.primary,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Row(children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                    color: const Color(0x1AFFFFFF),
                    borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.policy_rounded,
                    color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('CEA Laboratory Policies',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                  SizedBox(height: 2),
                  Text(
                      'Please read all policies carefully before borrowing equipment.',
                      style:
                          TextStyle(color: AppTheme.textLight, fontSize: 11)),
                ]),
              ),
            ]),
          ),

          // Policy list
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: policies.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final pol = policies[i];
                final color = Color(pol['color'] as int);
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border(
                        left: BorderSide(color: color, width: 4)),
                    boxShadow: [
                      BoxShadow(
                          color: color.withAlpha(15),
                          blurRadius: 8,
                          offset: const Offset(0, 2))
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      // Policy title row
                      Row(children: [
                        Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(10)),
                          child: Center(
                              child: Text(pol['icon'] as String,
                                  style: const TextStyle(fontSize: 18))),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(pol['title'] as String,
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: color)),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      const Divider(color: AppTheme.divider, height: 1),
                      const SizedBox(height: 12),
                      // Policy body
                      Text(pol['body'] as String,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.textDark,
                              height: 1.6)),
                    ]),
                  ),
                );
              },
            ),
          ),

          // Bottom button
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            color: Colors.white,
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.check_rounded),
                label: const Text('I Understand — Go Back'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── QR Scan Screen (Admin — Return Processing) ───────────────────────────────

class QRScanScreen extends StatefulWidget {
  const QRScanScreen({super.key});
  @override
  State<QRScanScreen> createState() => _QRScanScreenState();
}

class _QRScanScreenState extends State<QRScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _scanning = true;
  bool _torchOn  = false;
  final _manualCtrl = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!_scanning) return;
    final code = capture.barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;
    setState(() => _scanning = false);
    await _handleCode(code);
  }

  Future<void> _handleCode(String code) async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Looking up equipment...'),
            ]),
          ),
        ),
      ),
    );

    try {
      final res = await ApiService.getEquipmentByQr(code);
      if (!mounted) return;
      Navigator.pop(context); // close loading

      if (res['success'] == true) {
        _showReturnSheet(res['data'] as Map<String, dynamic>);
      } else {
        _showNotFound(code);
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      _showError();
    }
  }

  Future<void> _processReturn(
      String equipId, String equipName, String condition) async {
    Navigator.pop(context); // close the return sheet
    final res = await ApiService.returnEquipmentByQr(equipId, condition);
    if (!mounted) return;
    if (res['success'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res['message'] ?? 'Failed to process return.'),
        backgroundColor: AppTheme.danger,
        behavior: SnackBarBehavior.floating,
      ));
      setState(() => _scanning = true);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(condition == 'Damaged'
          ? '"$equipName" returned and marked Under Repair.'
          : '"$equipName" marked as returned.'),
      backgroundColor:
          condition == 'Damaged' ? AppTheme.warning : AppTheme.success,
      behavior: SnackBarBehavior.floating,
    ));
    if (condition == 'Damaged') {
      await _offerDamageFollowUp(res, equipId, equipName);
    }
    if (mounted) setState(() => _scanning = true);
  }

  Future<void> _offerDamageFollowUp(
      Map<String, dynamic> res, String equipId, String equipName) async {
    final borrower  = '${res['borrower_name'] ?? 'the student'}';
    final studentId = '${res['student_id'] ?? ''}';
    final apply = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.gpp_maybe_outlined, color: AppTheme.danger, size: 44),
        title: const Text('Log Damage & Hold?'),
        content: Text(
            'Record a damage report for "$equipName" and place a borrowing hold '
            'on $borrower until it is settled?',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Skip', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
              onPressed: () => Navigator.pop(dCtx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              child: const Text('Log & Hold')),
        ],
      ),
    );
    if (apply != true) return;
    await ApiService.submitDamageReport({
      'equipment_id':   equipId,
      'equipment_name': equipName,
      'student_id':     studentId,
      'borrower_name':  res['borrower_name'] ?? '',
      'student_number': res['student_number'] ?? '',
      'description':    'Reported damaged on return (staff QR return).',
      'reported_by':    'staff',
    });
    if (studentId.isNotEmpty) {
      await ApiService.setStudentHold(studentId, true,
          reason: 'Damaged equipment "$equipName" pending settlement.');
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Damage report logged and hold placed.'),
      backgroundColor: AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _showReturnSheet(Map<String, dynamic> equipment) {
    final status      = equipment['status'] ?? 'Unknown';
    final isBorrowed  = status == 'Borrowed';
    final equipName   = equipment['equipment_name'] ?? '';
    final equipId     = '${equipment['equipment_id']}';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Handle
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppTheme.divider,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),

          // Equipment info
          Container(
            width: 60, height: 60,
            decoration: BoxDecoration(
                color: (isBorrowed ? AppTheme.warning : AppTheme.success).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16)),
            child: Icon(Icons.science_outlined,
                color: isBorrowed ? AppTheme.warning : AppTheme.success, size: 30),
          ),
          const SizedBox(height: 12),
          Text(equipName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                  color: AppTheme.textDark),
              textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text('${equipment['qr_code']}  •  ${equipment['category']}',
              style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const SizedBox(height: 12),

          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            StatusBadge(
                label: status,
                color: isBorrowed ? AppTheme.warning : AppTheme.success),
            if (equipment['location'] != null) ...[
              const SizedBox(width: 8),
              StatusBadge(label: equipment['location'], color: AppTheme.textMid),
            ],
          ]),
          const SizedBox(height: 24),
          const Divider(color: AppTheme.divider),
          const SizedBox(height: 16),

          // Action
          if (isBorrowed) ...[
            const Text(
                'Confirm the student has returned this equipment, then record its condition.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _processReturn(equipId, equipName, 'Good'),
                icon: const Icon(Icons.check_circle_outline_rounded),
                label: const Text('Return — Good Condition'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.success,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _processReturn(equipId, equipName, 'Damaged'),
                icon: const Icon(Icons.report_problem_outlined),
                label: const Text('Return — Report Damage'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.warning,
                    side: const BorderSide(color: AppTheme.warning),
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: const Color(0x1406D6A0),
                  borderRadius: BorderRadius.circular(12)),
              child: const Row(children: [
                Icon(Icons.info_outline_rounded, color: AppTheme.success, size: 18),
                SizedBox(width: 10),
                Expanded(child: Text(
                  'This equipment is already Available — no return needed.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textDark),
                )),
              ]),
            ),
          ],

          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () {
                Navigator.pop(context);
                setState(() => _scanning = true);
              },
              child: const Text('Scan Another'),
            ),
          ),
        ]),
      ),
    ).then((_) => setState(() => _scanning = true));
  }

  void _showNotFound(String code) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.search_off_rounded, color: AppTheme.danger, size: 48),
        title: const Text('Not Found'),
        content: Text('No equipment found for:\n"$code"',
            textAlign: TextAlign.center),
        actions: [ElevatedButton(
          onPressed: () { Navigator.pop(context); setState(() => _scanning = true); },
          child: const Text('Scan Again'))],
      ),
    );
  }

  void _showError() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.wifi_off_rounded, color: AppTheme.danger, size: 48),
        title: const Text('Connection Error'),
        content: const Text('Could not reach the server.',
            textAlign: TextAlign.center),
        actions: [ElevatedButton(
          onPressed: () { Navigator.pop(context); setState(() => _scanning = true); },
          child: const Text('Try Again'))],
      ),
    );
  }

  void _showManualEntry() {
    _manualCtrl.clear();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Enter QR Code Manually'),
        content: TextField(
          controller: _manualCtrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
              hintText: 'e.g. ELE-001',
              prefixIcon: Icon(Icons.qr_code_rounded)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
            onPressed: () async {
              final code = _manualCtrl.text.trim().toUpperCase();
              if (code.isEmpty) return;
              Navigator.pop(context);
              setState(() => _scanning = false);
              await _handleCode(code);
            },
            child: const Text('Look Up'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan QR — Process Return'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: Icon(_torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                color: _torchOn ? AppTheme.accent : Colors.white),
            onPressed: () {
              _controller.toggleTorch();
              setState(() => _torchOn = !_torchOn);
            },
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios_rounded, color: Colors.white),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Live camera
          MobileScanner(controller: _controller, onDetect: _onDetect),

          // Overlay
          CustomPaint(painter: _ScanOverlayPainter(), child: const SizedBox.expand()),

          // Instructions + manual entry
          Column(children: [
            const Spacer(),
            const Text('Scan equipment QR code to process return',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 220),
            TextButton.icon(
              onPressed: _showManualEntry,
              icon: const Icon(Icons.keyboard_alt_outlined, color: AppTheme.accent),
              label: const Text('Enter code manually',
                  style: TextStyle(color: AppTheme.accent)),
            ),
            const SizedBox(height: 32),
          ]),

          // Loading overlay while processing
          if (!_scanning)
            Container(
              color: Colors.black45,
              child: const Center(child: CircularProgressIndicator(color: AppTheme.accent)),
            ),
        ],
      ),
    );
  }
}

// ── Scan overlay painter ──────────────────────────────────────────────────────
class _ScanOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const boxSize = 260.0;
    final cx = size.width / 2;
    final cy = size.height / 2 - 60;
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: boxSize, height: boxSize);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(16));

    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = const Color(0x8C000000));

    canvas.drawRRect(rrect, Paint()
      ..color = const Color(0xFFF5A623)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5);

    const cLen = 24.0;
    final cp = Paint()
      ..color = const Color(0xFFF5A623)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final l = rect.left; final t = rect.top;
    final r = rect.right; final b = rect.bottom;
    canvas.drawLine(Offset(l, t + cLen), Offset(l, t), cp);
    canvas.drawLine(Offset(l, t), Offset(l + cLen, t), cp);
    canvas.drawLine(Offset(r - cLen, t), Offset(r, t), cp);
    canvas.drawLine(Offset(r, t), Offset(r, t + cLen), cp);
    canvas.drawLine(Offset(l, b - cLen), Offset(l, b), cp);
    canvas.drawLine(Offset(l, b), Offset(l + cLen, b), cp);
    canvas.drawLine(Offset(r - cLen, b), Offset(r, b), cp);
    canvas.drawLine(Offset(r, b), Offset(r, b - cLen), cp);
  }

  @override
  bool shouldRepaint(_) => false;
}

// ─── My Borrowings Screen ─────────────────────────────────────────────────────

class MyBorrowingsScreen extends StatefulWidget {
  const MyBorrowingsScreen({super.key});
  @override
  State<MyBorrowingsScreen> createState() => _MyBorrowingsScreenState();
}

class _MyBorrowingsScreenState extends State<MyBorrowingsScreen> {
  // Live Firestore stream: the lists update by themselves when staff approve,
  // reject or process a return — no pull-to-refresh needed.
  late final Stream<List<dynamic>> _stream = ApiService.myBorrowingsStream();

  Color _statusColor(String s) {
    switch (s) {
      case 'Approved': return AppTheme.success;
      case 'Pending':  return AppTheme.accent;
      case 'Returned': return AppTheme.textMid;
      case 'Rejected': return AppTheme.danger;
      default:         return AppTheme.textMid;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<dynamic>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('My Borrowings')),
            body: const Center(
                child: Text('Could not load your borrowings.',
                    style: TextStyle(color: AppTheme.textMid))),
          );
        }
        final all = snap.data ?? const [];
        final active  = all.where((e) => e['status'] == 'Approved').toList();
        final pending = all.where((e) => e['status'] == 'Pending').toList();
        final history = all.where((e) => e['status'] == 'Returned' || e['status'] == 'Rejected').toList();

        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('My Borrowings'),
              bottom: const TabBar(
                indicatorColor: AppTheme.accent,
                labelColor: Colors.white,
                unselectedLabelColor: AppTheme.textLight,
                tabs: [Tab(text: 'Active'), Tab(text: 'Pending'), Tab(text: 'History')],
              ),
            ),
            body: TabBarView(
              children: [
                _LiveBorrowList(items: active, statusColorFn: _statusColor),
                _LiveBorrowList(items: pending, statusColorFn: _statusColor),
                _LiveBorrowList(items: history, statusColorFn: _statusColor),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LiveBorrowList extends StatelessWidget {
  final List<dynamic> items;
  final Color Function(String) statusColorFn;
  const _LiveBorrowList({required this.items, required this.statusColorFn});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.inbox_rounded, size: 48, color: AppTheme.textLight),
        SizedBox(height: 8),
        Text('No items', style: TextStyle(color: AppTheme.textMid)),
        SizedBox(height: 12),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.sync_rounded, size: 14, color: AppTheme.textLight),
          SizedBox(width: 6),
          Text('Updates automatically', style: TextStyle(fontSize: 12, color: AppTheme.textLight)),
        ]),
      ]));
    }
    return Material(
      color: Colors.transparent,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final e = items[i];
          final status = e['status'] ?? 'Pending';
          final dueDate = e['due_date'] ?? '';
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                Row(
                  children: [
                    EquipmentThumb(
                      bytes: photoThumbOf(e),
                      category: e['category'] as String? ?? '',
                      color: AppTheme.primary,
                      size: 46,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e['equipment_name'] ?? '',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
                        Text('${e['qr_code'] ?? ''}  •  Due: $dueDate',
                            style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                      ]),
                    ),
                    StatusBadge(label: status, color: statusColorFn(status)),
                  ],
                ),
                if (status == 'Approved') ...[
                  const SizedBox(height: 12),
                  const Divider(color: AppTheme.divider, height: 1),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const DamageReportScreen())),
                      icon: const Icon(Icons.report_problem_outlined, size: 16),
                      label: const Text('Report Damage'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.warning,
                          side: const BorderSide(color: AppTheme.warning)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Row(children: [
                    Icon(Icons.qr_code_2_rounded, size: 13, color: AppTheme.textLight),
                    SizedBox(width: 6),
                    Expanded(
                        child: Text(
                      'Returns are processed by lab staff scanning the QR code on the item.',
                      style: TextStyle(fontSize: 11, color: AppTheme.textLight),
                    )),
                  ]),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}



// ─── Damage Report Screen ─────────────────────────────────────────────────────

class DamageReportScreen extends StatefulWidget {
  const DamageReportScreen({super.key});
  @override
  State<DamageReportScreen> createState() => _DamageReportScreenState();
}

class _DamageReportScreenState extends State<DamageReportScreen> {
  String? _severity;
  String? _selectedEquipmentId;
  String? _selectedEquipmentName;
  bool _loading = false;
  bool _loadingEquipment = true;
  final _descCtrl = TextEditingController();

  // Only equipment the student currently has borrowed (Approved status)
  List<Map<String, dynamic>> _borrowedItems = [];

  @override
  void initState() {
    super.initState();
    _loadBorrowedEquipment();
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBorrowedEquipment() async {
    setState(() => _loadingEquipment = true);
    try {
      final loans = await ApiService.getMyBorrowings(
        studentId: Session.currentUser?['student_id'],
        studentNumber: Session.studentNumber,
      );
      // Only Approved (currently borrowed) items
      final active = loans
          .where((e) => e['status'] == 'Approved')
          .map<Map<String, dynamic>>((e) => {
                'equipment_id':   '${e['equipment_id'] ?? ''}',
                'equipment_name': '${e['equipment_name'] ?? 'Unknown'}',
                'qr_code':        '${e['qr_code'] ?? ''}',
                'transaction_id': '${e['transaction_id'] ?? ''}',
              })
          .toList();

      // Remove duplicates by equipment_id
      final seen = <String>{};
      final unique = active.where((e) => seen.add(e['equipment_id']!)).toList();

      setState(() {
        _borrowedItems = unique;
        _loadingEquipment = false;
      });
    } catch (_) {
      setState(() => _loadingEquipment = false);
    }
  }

  Future<void> _submit() async {
    if (_selectedEquipmentId == null || _selectedEquipmentId!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please select the damaged equipment.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating));
      return;
    }
    if (_severity == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please select the damage severity.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating));
      return;
    }
    if (_descCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please describe the damage.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating));
      return;
    }

    setState(() => _loading = true);
    try {
      final res = await ApiService.submitDamageReport({
        'equipment_id':   _selectedEquipmentId ?? '',
        'equipment_name': _selectedEquipmentName ?? '',
        'student_id':     Session.currentUser?['student_id']?.toString() ?? '',
        'student_number': Session.studentNumber,
        'borrower_name':  Session.name,
        'severity':       _severity ?? 'Minor',
        'description':    '${_severity ?? 'Minor'}: ${_descCtrl.text.trim()}',
      });
      if (!mounted) return;
      if (res['success'] == true) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            icon: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 52),
            title: const Text('Report Submitted'),
            content: const Text(
                'Your damage report has been submitted. Lab staff will review it shortly.',
                textAlign: TextAlign.center),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context); // close dialog
                  Navigator.pop(context); // go back
                },
                child: const Text('OK'),
              )
            ],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(res['message'] ?? 'Submission failed.'),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ApiService._friendlyError(e)),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Damage Report')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Warning banner
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: const Color(0x14EF4444),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0x40EF4444))),
              child: const Row(children: [
                Icon(Icons.warning_amber_rounded, color: AppTheme.danger),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Report any damage immediately. Unreported damage may result in clearance issues.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textDark),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 20),

            // Equipment selector — live from borrowed items
            _FieldLabel('Equipment (Your Active Loans)'),
            const SizedBox(height: 8),
            _loadingEquipment
                ? Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.divider)),
                    child: const Row(children: [
                      SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text('Loading your borrowed equipment...',
                          style: TextStyle(color: AppTheme.textMid, fontSize: 13)),
                    ]),
                  )
                : _borrowedItems.isEmpty
                    ? Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppTheme.divider)),
                        child: const Row(children: [
                          Icon(Icons.inventory_2_outlined,
                              color: AppTheme.textLight, size: 20),
                          SizedBox(width: 10),
                          Text('No active loans found.',
                              style: TextStyle(
                                  color: AppTheme.textMid, fontSize: 13)),
                        ]),
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 4),
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: _selectedEquipmentId != null
                                    ? AppTheme.primary
                                    : AppTheme.divider)),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: _selectedEquipmentId,
                            hint: const Text(
                                'Select borrowed equipment to report',
                                style: TextStyle(
                                    color: AppTheme.textLight, fontSize: 13)),
                            items: _borrowedItems.map((e) {
                              return DropdownMenuItem<String>(
                                value: e['equipment_id'],
                                child: Row(children: [
                                  const Icon(Icons.science_outlined,
                                      size: 16, color: AppTheme.primary),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(e['equipment_name']!,
                                            style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: AppTheme.textDark)),
                                        Text(e['qr_code']!,
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: AppTheme.textMid)),
                                      ],
                                    ),
                                  ),
                                ]),
                              );
                            }).toList(),
                            onChanged: (val) {
                              final item = _borrowedItems
                                  .firstWhere((e) => e['equipment_id'] == val);
                              setState(() {
                                _selectedEquipmentId   = val;
                                _selectedEquipmentName = item['equipment_name'];
                              });
                            },
                          ),
                        ),
                      ),

            // Total borrowed count info
            if (!_loadingEquipment && _borrowedItems.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'You currently have ${_borrowedItems.length} item(s) borrowed.',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMid),
                ),
              ),
            const SizedBox(height: 20),

            // Severity selector
            _FieldLabel('Damage Severity'),
            const SizedBox(height: 10),
            Row(
              children: ['Minor', 'Moderate', 'Severe'].map((s) {
                final colors = {
                  'Minor':    AppTheme.success,
                  'Moderate': AppTheme.warning,
                  'Severe':   AppTheme.danger,
                };
                final c = colors[s]!;
                final selected = _severity == s;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _severity = s),
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: selected ? c.withValues(alpha: 0.12) : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: selected ? c : AppTheme.divider,
                            width: selected ? 2 : 1),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            s == 'Minor'    ? Icons.info_outline_rounded :
                            s == 'Moderate' ? Icons.warning_amber_rounded :
                                              Icons.report_rounded,
                            color: selected ? c : AppTheme.textLight,
                            size: 20,
                          ),
                          const SizedBox(height: 4),
                          Text(s,
                              style: TextStyle(
                                  color: selected ? c : AppTheme.textMid,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // Description
            _FieldLabel('Description of Damage'),
            const SizedBox(height: 8),
            TextField(
              controller: _descCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                  hintText: 'Describe the damage in detail. Be specific about what is broken, missing, or not working...'),
            ),
            const SizedBox(height: 28),

            // Submit button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _submit,
                icon: _loading
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.send_rounded),
                label: Text(_loading ? 'Submitting...' : 'Submit Report'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.danger,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ─── Profile Screen ───────────────────────────────────────────────────────────

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  void _confirmSignOut(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Session.clear();
              Navigator.pop(context);
              Navigator.pushReplacement(context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
            icon: const Icon(Icons.logout_rounded, size: 16),
            label: const Text('Sign Out'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // ── Header ──
            Container(
              color: AppTheme.primary,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Center(
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundColor: const Color(0x33F5A623),
                      child: Text(Session.initials,
                          style: const TextStyle(
                              color: AppTheme.accent,
                              fontSize: 28,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 12),
                    Text(Session.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      '${Session.studentNumber}  •  ${courseLabel(Session.currentUser?['course'] ?? 'CEA')}',
                      style: const TextStyle(color: AppTheme.textLight, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const _ProfileStat(label: 'Total\nBorrowed', value: '—'),
                        Container(width: 1, height: 32, color: Colors.white24,
                            margin: const EdgeInsets.symmetric(horizontal: 20)),
                        const _ProfileStat(label: 'Active\nLoans', value: '—'),
                        Container(width: 1, height: 32, color: Colors.white24,
                            margin: const EdgeInsets.symmetric(horizontal: 20)),
                        const _ProfileStat(label: 'Late\nReturns', value: '0'),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Account Settings ──
                  const SectionHeader(title: 'Account Settings'),
                  const SizedBox(height: 12),
                  _SettingTile(
                    icon: Icons.person_outline_rounded,
                    label: 'Edit Profile',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const EditProfileScreen())),
                  ),
                  _SettingTile(
                    icon: Icons.lock_outline_rounded,
                    label: 'Change Password',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
                  ),
                  _SettingTile(
                    icon: Icons.notifications_outlined,
                    label: 'Notifications',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const NotificationsSettingsScreen())),
                  ),
                  const SizedBox(height: 20),

                  // ── Support ──
                  const SectionHeader(title: 'Support'),
                  const SizedBox(height: 12),
                  _SettingTile(
                    icon: Icons.policy_rounded,
                    label: 'Laboratory Policies',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const LabPoliciesScreen())),
                  ),
                  _SettingTile(
                    icon: Icons.help_outline_rounded,
                    label: 'Help & FAQ',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const HelpFaqScreen())),
                  ),
                  _SettingTile(
                    icon: Icons.info_outline_rounded,
                    label: 'About LabTrack · NEU',
                    onTap: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const AboutScreen())),
                  ),
                  const SizedBox(height: 20),

                  // ── Sign Out ──
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _confirmSignOut(context),
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text('Sign Out'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.danger,
                          side: const BorderSide(color: AppTheme.danger),
                          padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Edit Profile Screen ──────────────────────────────────────────────────────

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});
  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late TextEditingController _nameCtrl;
  String? _selectedCourse;
  late TextEditingController _yearCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: Session.name);
    final stored = Session.currentUser?['course'] as String?;
    _selectedCourse = _kCourses.contains(stored) ? stored : null;
    _yearCtrl = TextEditingController(text: '${Session.currentUser?['year_level'] ?? ''}');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name   = _nameCtrl.text.trim();
    final course = _selectedCourse ?? '';
    final yearLevel = int.tryParse(_yearCtrl.text.trim()) ?? 1;

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name cannot be empty.'), backgroundColor: AppTheme.danger));
      return;
    }

    setState(() => _saving = true);
    try {
      final res = await ApiService.updateProfile(
        studentId: Session.studentId,
        name:      name,
        course:    course,
        yearLevel: yearLevel,
      );
      if (!mounted) return;

      if (res['success'] == true) {
        // Update local session so UI reflects changes immediately
        if (Session.currentUser != null) {
          Session.currentUser!['name']       = name;
          Session.currentUser!['course']     = course;
          Session.currentUser!['year_level'] = yearLevel;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile updated successfully!'),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res['message'] ?? 'Update failed.'),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot connect to server.'),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Avatar
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 48,
                    backgroundColor: const Color(0x26F5A623),
                    child: Text(Session.initials,
                        style: const TextStyle(
                            color: AppTheme.accent,
                            fontSize: 34,
                            fontWeight: FontWeight.bold)),
                  ),
                  Positioned(
                    bottom: 0, right: 0,
                    child: Container(
                      width: 32, height: 32,
                      decoration: const BoxDecoration(
                          color: AppTheme.primary, shape: BoxShape.circle),
                      child: const Icon(Icons.camera_alt_rounded,
                          color: Colors.white, size: 16),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // Student ID (read-only)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.divider)),
              child: Row(children: [
                const Icon(Icons.badge_outlined, color: AppTheme.textMid, size: 20),
                const SizedBox(width: 12),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Student ID', style: TextStyle(fontSize: 11, color: AppTheme.textMid)),
                  Text(Session.studentNumber,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
                ]),
                const Spacer(),
                const StatusBadge(label: 'Read-only', color: AppTheme.textLight),
              ]),
            ),
            const SizedBox(height: 16),

            _FieldLabel('Full Name'),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  hintText: 'e.g. Juan Santos',
                  prefixIcon: Icon(Icons.person_outline_rounded, color: AppTheme.textMid)),
            ),
            const SizedBox(height: 16),

            _FieldLabel('Course'),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedCourse,
              decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  prefixIcon: Icon(Icons.school_outlined, color: AppTheme.textMid)),
              hint: const Text('Select course'),
              isExpanded: true,
              items: _kCourses.map((c) => DropdownMenuItem(value: c, child: Text(courseLabel(c)))).toList(),
              onChanged: (v) => setState(() => _selectedCourse = v),
            ),
            const SizedBox(height: 16),

            _FieldLabel('Year Level'),
            const SizedBox(height: 8),
            TextField(
              controller: _yearCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  hintText: 'e.g. 3',
                  prefixIcon: Icon(Icons.calendar_today_outlined, color: AppTheme.textMid)),
            ),
            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.save_rounded),
                label: const Text('Save Changes'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Change Password Screen ───────────────────────────────────────────────────

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _currentCtrl = TextEditingController();
  final _newCtrl     = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscureCurrent = true;
  bool _obscureNew     = true;
  bool _obscureConfirm = true;
  bool _saving = false;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_currentCtrl.text.isEmpty || _newCtrl.text.isEmpty || _confirmCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.'), backgroundColor: AppTheme.danger));
      return;
    }
    if (_newCtrl.text.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New password must be at least 8 characters.'), backgroundColor: AppTheme.danger));
      return;
    }
    if (_newCtrl.text != _confirmCtrl.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New passwords do not match.'), backgroundColor: AppTheme.danger));
      return;
    }
    setState(() => _saving = true);
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() => _saving = false);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 52),
        title: const Text('Password Changed!'),
        content: const Text('Your password has been updated successfully.',
            textAlign: TextAlign.center),
        actions: [
          ElevatedButton(
            onPressed: () { Navigator.pop(context); Navigator.pop(context); },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _passwordField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required bool obscure,
    required VoidCallback onToggle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppTheme.textMid),
            suffixIcon: GestureDetector(
              onTap: onToggle,
              child: Icon(
                  obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  color: AppTheme.textMid),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change Password')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Info banner
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: const Color(0x121B3A8C),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x261B3A8C))),
              child: const Row(children: [
                Icon(Icons.shield_outlined, color: AppTheme.primary, size: 20),
                SizedBox(width: 10),
                Expanded(child: Text(
                    'Use a strong password with at least 8 characters.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textDark))),
              ]),
            ),
            const SizedBox(height: 24),

            _passwordField(
              controller: _currentCtrl,
              label: 'Current Password',
              hint: 'Enter current password', // not bullets — see login field

              obscure: _obscureCurrent,
              onToggle: () => setState(() => _obscureCurrent = !_obscureCurrent),
            ),

            const Divider(color: AppTheme.divider, height: 8),
            const SizedBox(height: 16),

            _passwordField(
              controller: _newCtrl,
              label: 'New Password',
              hint: 'At least 8 characters',
              obscure: _obscureNew,
              onToggle: () => setState(() => _obscureNew = !_obscureNew),
            ),

            _passwordField(
              controller: _confirmCtrl,
              label: 'Confirm New Password',
              hint: 'Re-enter new password',
              obscure: _obscureConfirm,
              onToggle: () => setState(() => _obscureConfirm = !_obscureConfirm),
            ),

            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.lock_reset_rounded),
                label: const Text('Update Password'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Notifications Settings Screen ───────────────────────────────────────────

class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key});
  @override
  State<NotificationsSettingsScreen> createState() => _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState extends State<NotificationsSettingsScreen> {
  bool _borrowApproved  = NotifPrefs.approved;
  bool _borrowRejected  = NotifPrefs.rejected;
  bool _dueSoon         = NotifPrefs.dueSoon;
  bool _overdue         = NotifPrefs.overdue;
  bool _returnConfirmed = NotifPrefs.returnConfirmed;
  bool _damageUpdate    = NotifPrefs.damageUpdate;

  @override
  void initState() {
    super.initState();
    // Re-read from disk in case this screen is opened before the dashboard
    // has loaded the preferences.
    NotifPrefs.load().then((_) {
      if (!mounted) return;
      setState(() {
        _borrowApproved  = NotifPrefs.approved;
        _borrowRejected  = NotifPrefs.rejected;
        _dueSoon         = NotifPrefs.dueSoon;
        _overdue         = NotifPrefs.overdue;
        _returnConfirmed = NotifPrefs.returnConfirmed;
        _damageUpdate    = NotifPrefs.damageUpdate;
      });
    });
  }

  Future<void> _save() async {
    NotifPrefs.approved        = _borrowApproved;
    NotifPrefs.rejected        = _borrowRejected;
    NotifPrefs.dueSoon         = _dueSoon;
    NotifPrefs.overdue         = _overdue;
    NotifPrefs.returnConfirmed = _returnConfirmed;
    NotifPrefs.damageUpdate    = _damageUpdate;
    await NotifPrefs.save();
  }

  Widget _notifTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    Color? activeColor,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
        subtitle: Text(subtitle,
            style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
        value: value,
        onChanged: onChanged,
        activeThumbColor: activeColor ?? AppTheme.primary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'Borrow Requests'),
            const SizedBox(height: 12),
            _notifTile(
              title: 'Request Approved',
              subtitle: 'When staff approves your borrow request',
              value: _borrowApproved,
              onChanged: (v) => setState(() => _borrowApproved = v),
              activeColor: AppTheme.success,
            ),
            _notifTile(
              title: 'Request Rejected',
              subtitle: 'When staff rejects your borrow request',
              value: _borrowRejected,
              onChanged: (v) => setState(() => _borrowRejected = v),
              activeColor: AppTheme.danger,
            ),
            const SizedBox(height: 20),

            const SectionHeader(title: 'Due Dates'),
            const SizedBox(height: 12),
            _notifTile(
              title: 'Due Soon Reminder',
              subtitle: 'Get reminded 1 day before equipment is due',
              value: _dueSoon,
              onChanged: (v) => setState(() => _dueSoon = v),
              activeColor: AppTheme.warning,
            ),
            _notifTile(
              title: 'Overdue Alert',
              subtitle: 'Alert when equipment return is overdue',
              value: _overdue,
              onChanged: (v) => setState(() => _overdue = v),
              activeColor: AppTheme.danger,
            ),
            const SizedBox(height: 20),

            const SectionHeader(title: 'Returns & Reports'),
            const SizedBox(height: 12),
            _notifTile(
              title: 'Return Confirmed',
              subtitle: 'When staff confirms your equipment return',
              value: _returnConfirmed,
              onChanged: (v) => setState(() => _returnConfirmed = v),
            ),
            _notifTile(
              title: 'Damage Report Update',
              subtitle: 'Updates on your submitted damage reports',
              value: _damageUpdate,
              onChanged: (v) => setState(() => _damageUpdate = v),
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  await _save();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Notification preferences saved!'),
                      backgroundColor: AppTheme.success,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.save_rounded),
                label: const Text('Save Preferences'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Help & FAQ Screen ────────────────────────────────────────────────────────

class HelpFaqScreen extends StatefulWidget {
  const HelpFaqScreen({super.key});
  @override
  State<HelpFaqScreen> createState() => _HelpFaqScreenState();
}

class _HelpFaqScreenState extends State<HelpFaqScreen> {
  int? _expanded;

  final _faqs = const [
    {
      'q': 'How do I borrow equipment?',
      'a': 'Go to the Equipment Catalog, tap on the item you want to borrow, fill in the Borrow Request form, and submit. Your request will be reviewed by lab staff.',
    },
    {
      'q': 'How long can I borrow equipment?',
      'a': 'The borrowing period is set when you submit your request by choosing a return date. Maximum borrowing period is 30 days.',
    },
    {
      'q': 'What happens if I return equipment late?',
      'a': 'Late returns are recorded in your profile. Repeated late returns may affect your borrowing privileges. Always return equipment on or before the due date.',
    },
    {
      'q': 'How do I scan a QR code to borrow?',
      'a': 'Tap "Scan QR" on the home screen, point your camera at the equipment\'s QR code, and the system will automatically identify the equipment for your borrow request.',
    },
    {
      'q': 'What do I do if equipment is damaged?',
      'a': 'Report it immediately using the Damage Report feature. Go to My Borrowings, find the item, and tap "Report". Describe the damage and submit — lab staff will be notified.',
    },
    {
      'q': 'Can I cancel a borrow request?',
      'a': 'You can cancel a pending request by contacting the lab staff directly. Once approved, cancellations must also be done in person at the laboratory.',
    },
    {
      'q': 'I forgot my password, what should I do?',
      'a': 'Tap "Forgot Password?" on the login screen, or contact your lab staff to reset your account credentials.',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help & FAQ')),
      body: Column(
        children: [
          // Banner
          Container(
            color: AppTheme.primary,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Row(children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                    color: const Color(0x26FFFFFF),
                    borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.help_outline_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Frequently Asked Questions',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                SizedBox(height: 2),
                Text('Tap a question to see the answer',
                    style: TextStyle(color: AppTheme.textLight, fontSize: 12)),
              ])),
            ]),
          ),

          // FAQ List
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _faqs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final isOpen = _expanded == i;
                return GestureDetector(
                  onTap: () => setState(() => _expanded = isOpen ? null : i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: isOpen ? const Color(0x4D1B3A8C) : AppTheme.divider),
                      boxShadow: isOpen ? [
                        BoxShadow(color: const Color(0x141B3A8C),
                            blurRadius: 8, offset: const Offset(0, 2))
                      ] : [],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                                color: isOpen ? AppTheme.primary : AppTheme.surface,
                                borderRadius: BorderRadius.circular(8)),
                            child: Center(
                              child: Text('${i + 1}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: isOpen ? Colors.white : AppTheme.textMid)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Text(_faqs[i]['q']!,
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: isOpen ? AppTheme.primary : AppTheme.textDark))),
                          Icon(isOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                              color: isOpen ? AppTheme.primary : AppTheme.textLight),
                        ]),
                        if (isOpen) ...[
                          const SizedBox(height: 12),
                          const Divider(color: AppTheme.divider, height: 1),
                          const SizedBox(height: 12),
                          Text(_faqs[i]['a']!,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textMid,
                                  height: 1.5)),
                        ],
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),

          // Contact bar
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            color: Colors.white,
            child: Row(children: [
              const Icon(Icons.mail_outline_rounded, color: AppTheme.primary, size: 20),
              const SizedBox(width: 10),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Still need help?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textDark)),
                Text('cea.lab@neu.edu.ph', style: TextStyle(fontSize: 12, color: AppTheme.textMid)),
              ])),
              TextButton(
                onPressed: () {},
                child: const Text('Contact Us', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ─── About Screen ─────────────────────────────────────────────────────────────

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About LabTrack')),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Hero
            Container(
              width: double.infinity,
              color: AppTheme.primary,
              padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
              child: const Column(children: [
                NeuLogo(size: 72),
                SizedBox(height: 16),
                Text('LabTrack',
                    style: TextStyle(color: Colors.white, fontSize: 28,
                        fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                SizedBox(height: 4),
                Text('CEA Laboratory · New Era University',
                    style: TextStyle(color: AppTheme.textLight, fontSize: 13)),
                SizedBox(height: 12),
                StatusBadge(label: 'Version 1.0.0', color: AppTheme.accent),
              ]),
            ),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // About card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                        color: Colors.white, borderRadius: BorderRadius.circular(16)),
                    child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('About This App', style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
                      SizedBox(height: 10),
                      Text(
                        'LabTrack is a mobile equipment borrowing and return monitoring system '
                        'developed for the College of Engineering and Architecture (CEA) Laboratory '
                        'of New Era University.\n\n'
                        'The system allows students to borrow laboratory equipment digitally, '
                        'track their active loans, and report damage — while giving lab staff '
                        'full visibility and control over inventory.',
                        style: TextStyle(fontSize: 13, color: AppTheme.textMid, height: 1.6),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),

                  // Info tiles
                  _AboutTile(icon: Icons.school_rounded,     label: 'Institution',  value: 'New Era University'),
                  _AboutTile(icon: Icons.business_rounded,   label: 'College',      value: 'College of Engineering & Architecture'),
                  _AboutTile(icon: Icons.code_rounded,       label: 'Platform',     value: 'Flutter (Android & iOS)'),
                  _AboutTile(icon: Icons.storage_rounded,    label: 'Backend',      value: 'PHP + MySQL (Laragon)'),
                  _AboutTile(icon: Icons.calendar_month_rounded, label: 'Year',     value: '2026'),
                  const SizedBox(height: 16),

                  // Divider
                  const Divider(color: AppTheme.divider),
                  const SizedBox(height: 12),
                  const Center(
                    child: Text('Developed as a Capstone Project',
                        style: TextStyle(fontSize: 12, color: AppTheme.textLight)),
                  ),
                  const SizedBox(height: 4),
                  const Center(
                    child: Text('New Era University · CEA · 2026',
                        style: TextStyle(fontSize: 12, color: AppTheme.textLight)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutTile extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _AboutTile({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
              color: const Color(0x141B3A8C),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: AppTheme.primary, size: 18),
        ),
        const SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
          Text(value,  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
        ]),
      ]),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  final String label, value;
  const _ProfileStat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(color: AppTheme.textLight, fontSize: 11),
            textAlign: TextAlign.center),
      ],
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _SettingTile({required this.icon, required this.label, this.onTap});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Icon(icon, color: AppTheme.primary, size: 22),
        title: Text(label,
            style: const TextStyle(fontSize: 14, color: AppTheme.textDark)),
        trailing: const Icon(Icons.arrow_forward_ios_rounded,
            size: 14, color: AppTheme.textLight),
        onTap: onTap ?? () {},
      ),
    );
  }
}

// ─── Admin Dashboard Screen ────────────────────────────────────────────────────

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    // ── Auth guard — redirect if not staff ──
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Session.role != 'staff') {
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => const LoginScreen()));
      }
    });
  }

  final List<Widget> _pages = [
    const _AdminHome(),
    const AdminRequestsScreen(),
    const AdminInventoryScreen(),
    const AdminReportsScreen(),
  ];

  void _confirmSignOut(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Sign Out'),
        content: const Text(
            'Are you sure you want to sign out of your staff account?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: AppTheme.textMid)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pushReplacement(context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
            icon: const Icon(Icons.logout_rounded, size: 16),
            label: const Text('Sign Out'),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.danger),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabTitles = ['Dashboard', 'Requests', 'Inventory', 'Reports'];
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NeuLogo(size: 28),
            const SizedBox(width: 10),
            Text(tabTitles[_currentIndex]),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sign Out',
            icon: const Icon(Icons.logout_rounded, color: Colors.white),
            onPressed: () => _confirmSignOut(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _pages[_currentIndex]),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(color: Color(0x1A000000), blurRadius: 16, offset: Offset(0, -4))
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          type: BottomNavigationBarType.fixed,
          selectedItemColor: AppTheme.primary,
          unselectedItemColor: AppTheme.textLight,
          backgroundColor: Colors.transparent,
          elevation: 0,
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.dashboard_outlined),
                activeIcon: Icon(Icons.dashboard_rounded),
                label: 'Dashboard'),
            BottomNavigationBarItem(
                icon: Icon(Icons.assignment_outlined),
                activeIcon: Icon(Icons.assignment_rounded),
                label: 'Requests'),
            BottomNavigationBarItem(
                icon: Icon(Icons.inventory_2_outlined),
                activeIcon: Icon(Icons.inventory_2_rounded),
                label: 'Inventory'),
            BottomNavigationBarItem(
                icon: Icon(Icons.bar_chart_outlined),
                activeIcon: Icon(Icons.bar_chart_rounded),
                label: 'Reports'),
          ],
        ),
      ),
    );
  }
}

class _AdminHome extends StatefulWidget {
  const _AdminHome();
  @override
  State<_AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<_AdminHome> {
  bool _loading = true;
  Map<String, dynamic> _stats = {};
  List<dynamic> _pending  = [];
  List<dynamic> _approved = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getDashboardData();
      if (!mounted) return;
      setState(() {
        _stats    = data.stats;
        _pending  = data.pending;
        _approved = data.approved;
        _loading  = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _approve(String txId) async {
    try {
      await ApiService.updateRequestStatus(txId, 'approve');
      _load();
    } catch (_) {}
  }

  Future<void> _reject(String txId) async {
    try {
      await ApiService.updateRequestStatus(txId, 'reject');
      _load();
    } catch (_) {}
  }

  Future<void> _return(String txId, String equipmentName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Confirm Return'),
        content: Text('Mark "$equipmentName" as returned?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm Return')),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await ApiService.returnEquipment(txId, 'Good');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Equipment marked as returned!'),
          backgroundColor: AppTheme.success,
          behavior: SnackBarBehavior.floating,
        ));
        _load();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 210,
              pinned: true,
              backgroundColor: AppTheme.primary,
              automaticallyImplyLeading: false,
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppTheme.primary, AppTheme.primaryDark],
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Background watermark
                      Positioned(
                        right: -24, top: -10,
                        child: Icon(Icons.inventory_2_rounded,
                            size: 180,
                            color: const Color(0x0AFFFFFF)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 52, 24, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Top row
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Container(
                                  width: 36, height: 36,
                                  decoration: BoxDecoration(
                                      color: const Color(0x33F5A623),
                                      borderRadius: BorderRadius.circular(10)),
                                  child: const Icon(Icons.science_rounded,
                                      color: AppTheme.accent, size: 20),
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('LabTrack',
                                          style: TextStyle(
                                              color: AppTheme.accent,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 1)),
                                      Text('CEA Laboratory · New Era University',
                                          style: TextStyle(
                                              color: AppTheme.textLight,
                                              fontSize: 10)),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                      color: const Color(0x33F5A623),
                                      borderRadius: BorderRadius.circular(8)),
                                  child: Text(
                                      Session.isViewer
                                          ? 'VIEW ONLY'
                                          : Session.staffRole.toUpperCase(),
                                      style: const TextStyle(
                                          color: AppTheme.accent,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 1)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            // System title
                            const Text(
                              'Equipment Borrowing\n& Return Monitoring',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  height: 1.2),
                            ),
                            const SizedBox(height: 6),
                            Row(children: [
                              const Icon(Icons.manage_accounts_rounded,
                                  color: AppTheme.textLight, size: 13),
                              const SizedBox(width: 4),
                              Text('Staff: ${Session.name}',
                                  style: const TextStyle(
                                      color: AppTheme.textLight,
                                      fontSize: 12)),
                            ]),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()))
            else
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!Session.canManage)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: const Color(0x141B3A8C),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0x331B3A8C)),
                          ),
                          child: const Row(children: [
                            Icon(Icons.visibility_outlined,
                                color: AppTheme.primary, size: 18),
                            SizedBox(width: 10),
                            Expanded(
                                child: Text(
                              'View-only access. You can review all records but '
                              'cannot approve, edit, or process transactions.',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textDark,
                                  height: 1.4),
                            )),
                          ]),
                        ),

                      // ── Live Stats ──
                      IntrinsicHeight(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Expanded(child: _AdminStatCard(
                              label: 'Pending Requests',
                              value: '${_stats['pending_requests'] ?? 0}',
                              icon: Icons.pending_actions_rounded,
                              color: AppTheme.accent)),
                          const SizedBox(width: 12),
                          Expanded(child: _AdminStatCard(
                              label: 'Active Loans',
                              value: '${_stats['active_loans'] ?? 0}',
                              icon: Icons.inventory_2_rounded,
                              color: AppTheme.success)),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      IntrinsicHeight(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Expanded(child: _AdminStatCard(
                              label: 'Overdue Items',
                              value: '${_stats['overdue_loans'] ?? 0}',
                              icon: Icons.warning_amber_rounded,
                              color: AppTheme.danger)),
                          const SizedBox(width: 12),
                          Expanded(child: _AdminStatCard(
                              label: 'Total Equipment',
                              value: '${_stats['total_equipment'] ?? 0}',
                              icon: Icons.science_rounded,
                              color: AppTheme.primary)),
                        ]),
                      ),
                      const SizedBox(height: 12),
                      IntrinsicHeight(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Expanded(child: _AdminStatCard(
                              label: 'Registered Students',
                              value: '${_stats['total_students'] ?? 0}',
                              icon: Icons.people_alt_rounded,
                              color: AppTheme.primary)),
                          const SizedBox(width: 12),
                          Expanded(child: _AdminStatCard(
                              label: 'Students on Hold',
                              value: '${_stats['held_students'] ?? 0}',
                              icon: Icons.gpp_bad_rounded,
                              color: AppTheme.danger)),
                        ]),
                      ),
                      const SizedBox(height: 24),

                      // ── Scan QR for Return (manage rights only) ──
                      if (Session.canManage) ...[
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () => Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const QRScanScreen())),
                            icon: const Icon(Icons.qr_code_scanner_rounded),
                            label: const Text('Scan QR to Process Return'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primary,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      // ── Damage reports + penalties quick access (all staff) ──
                      Row(children: [
                        Expanded(child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const AdminDamageReportsScreen())),
                          icon: const Icon(Icons.report_problem_outlined, size: 18),
                          label: Text('Damage (${_stats['damage_reports'] ?? 0})'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.warning,
                            side: const BorderSide(color: AppTheme.warning),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        )),
                        const SizedBox(width: 12),
                        Expanded(child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const AdminPenaltiesScreen())),
                          icon: const Icon(Icons.gpp_maybe_outlined, size: 18),
                          label: const Text('Penalties'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.danger,
                            side: const BorderSide(color: AppTheme.danger),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        )),
                      ]),
                      const SizedBox(height: 12),
                      // ── Students directory (all staff; viewer is read-only) ──
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const AdminStudentsScreen())),
                          icon: const Icon(Icons.people_alt_outlined, size: 18),
                          label: const Text('Students'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.primary,
                            side: const BorderSide(color: AppTheme.primary),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // ── Pending Approvals ──
                      SectionHeader(
                          title: 'Pending Approvals (${_pending.length})',
                          action: 'View all',
                          onAction: () {}),
                      const SizedBox(height: 12),
                      if (_pending.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16)),
                          child: const Center(
                            child: Column(children: [
                              Icon(Icons.check_circle_outline_rounded,
                                  color: AppTheme.success, size: 36),
                              SizedBox(height: 8),
                              Text('No pending requests',
                                  style: TextStyle(color: AppTheme.textMid, fontSize: 13)),
                            ]),
                          ),
                        )
                      else
                        ..._pending.map((e) {
                          final txId = '${e['transaction_id']}';
                          final name = e['borrower_name'] ?? e['student_number'] ?? 'Student';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: const Color(0x33F5A623))),
                              child: Column(children: [
                                Row(children: [
                                  CircleAvatar(
                                    radius: 18,
                                    backgroundColor: const Color(0x1AF5A623),
                                    child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                                        style: const TextStyle(color: AppTheme.accent,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(name, style: const TextStyle(
                                        fontWeight: FontWeight.bold, fontSize: 13,
                                        color: AppTheme.textDark)),
                                    Text('${e['equipment_name']}  •  Qty: ${e['quantity'] ?? 1}',
                                        style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
                                  ])),
                                  StatusBadge(label: 'Pending', color: AppTheme.accent),
                                ]),
                                if (Session.canManage) ...[
                                  const SizedBox(height: 12),
                                  const Divider(color: AppTheme.divider, height: 1),
                                  const SizedBox(height: 10),
                                  Row(children: [
                                    Expanded(child: OutlinedButton.icon(
                                      onPressed: () => _reject(txId),
                                      icon: const Icon(Icons.close_rounded, size: 16),
                                      label: const Text('Deny'),
                                      style: OutlinedButton.styleFrom(
                                          foregroundColor: AppTheme.danger,
                                          side: const BorderSide(color: AppTheme.danger)),
                                    )),
                                    const SizedBox(width: 10),
                                    Expanded(child: ElevatedButton.icon(
                                      onPressed: () => _approve(txId),
                                      icon: const Icon(Icons.check_rounded, size: 16),
                                      label: const Text('Approve'),
                                      style: ElevatedButton.styleFrom(
                                          backgroundColor: AppTheme.success),
                                    )),
                                  ]),
                                ],
                              ]),
                            ),
                          );
                        }),
                      const SizedBox(height: 24),

                      // ── Active Loans (Approved — awaiting return) ──
                      SectionHeader(
                          title: 'Active Loans (${_approved.length})',
                          action: 'View all',
                          onAction: () {}),
                      const SizedBox(height: 12),
                      if (_approved.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16)),
                          child: const Center(
                            child: Text('No active loans',
                                style: TextStyle(color: AppTheme.textMid, fontSize: 13)),
                          ),
                        )
                      else
                        ..._approved.map((e) {
                          final txId = '${e['transaction_id']}';
                          final name = e['borrower_name'] ?? e['student_number'] ?? 'Student';
                          final equipName = e['equipment_name'] ?? 'Equipment';
                          final dueDate = (e['due_date'] ?? '').toString().split('T').first;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: const Color(0x3306D6A0))),
                              child: Column(children: [
                                Row(children: [
                                  Container(
                                    width: 40, height: 40,
                                    decoration: BoxDecoration(
                                        color: const Color(0x1A06D6A0),
                                        borderRadius: BorderRadius.circular(10)),
                                    child: const Icon(Icons.science_outlined,
                                        color: AppTheme.success, size: 20),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(equipName, style: const TextStyle(
                                        fontWeight: FontWeight.bold, fontSize: 13,
                                        color: AppTheme.textDark)),
                                    Text('$name  •  Due: $dueDate',
                                        style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
                                  ])),
                                  StatusBadge(label: 'Active', color: AppTheme.success),
                                ]),
                                if (Session.canManage) ...[
                                  const SizedBox(height: 12),
                                  const Divider(color: AppTheme.divider, height: 1),
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () => _return(txId, equipName),
                                      icon: const Icon(Icons.assignment_return_rounded, size: 16),
                                      label: const Text('Mark as Returned'),
                                      style: ElevatedButton.styleFrom(
                                          backgroundColor: AppTheme.primary),
                                    ),
                                  ),
                                ],
                              ]),
                            ),
                          );
                        }),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AdminStatCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _AdminStatCard(
      {required this.label,
      required this.value,
      required this.icon,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: color.withAlpha(26),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: color.withAlpha(31),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 12),
          Text(value,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  fontSize: 10, color: AppTheme.textMid),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ─── Admin Requests Screen ────────────────────────────────────────────────────

class AdminRequestsScreen extends StatefulWidget {
  const AdminRequestsScreen({super.key});
  @override
  State<AdminRequestsScreen> createState() => _AdminRequestsScreenState();
}

class _AdminRequestsScreenState extends State<AdminRequestsScreen> {
  // Live Firestore stream: new requests pop in as students submit them and
  // status changes render immediately — no manual refresh.
  late final Stream<List<dynamic>> _stream = ApiService.requestsStream();

  Color _statusColor(String s) {
    switch (s) {
      case 'Pending':  return AppTheme.accent;
      case 'Approved': return AppTheme.success;
      case 'Returned': return AppTheme.textMid;
      case 'Rejected': return AppTheme.danger;
      default:         return AppTheme.textMid;
    }
  }

  Future<void> _action(String txId, String action, {String reason = ''}) async {
    try {
      final res = await ApiService.updateRequestStatus(txId, action, reason: reason);
      if (mounted && res['success'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res['message'] ?? 'Action failed.'),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
        ));
      }
      // No manual reload needed — the snapshot stream delivers the change.
    } catch (_) {}
  }

  Future<void> _confirmReject(String txId) async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Reject Request'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Optionally add a reason the student will see.',
              style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const SizedBox(height: 12),
          TextField(
            controller: reasonCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
                hintText: 'e.g. Equipment reserved for a class'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
              onPressed: () => Navigator.pop(dCtx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              child: const Text('Reject')),
        ],
      ),
    );
    if (ok == true) _action(txId, 'reject', reason: reasonCtrl.text.trim());
  }

  // One-line "who processed this" note built from the audit fields stamped on
  // the transaction (approved/rejected/returned by which staff member).
  String _auditLine(dynamic e) {
    final status = '${e['status'] ?? ''}';
    if (status == 'Approved' && '${e['approved_by_name'] ?? ''}'.isNotEmpty) {
      return 'Approved by ${e['approved_by_name']}';
    }
    if (status == 'Rejected' && '${e['rejected_by_name'] ?? ''}'.isNotEmpty) {
      return 'Rejected by ${e['rejected_by_name']}';
    }
    if (status == 'Returned' && '${e['returned_by_name'] ?? ''}'.isNotEmpty) {
      return 'Returned to ${e['returned_by_name']}';
    }
    return '';
  }

  Widget _buildCard(dynamic e, {bool showActions = false}) {
    final status = e['status'] ?? '';
    final sc = _statusColor(status);
    final txId = '${e['transaction_id']}';
    final studentName = e['borrower_name'] ?? e['student_number'] ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: sc.withValues(alpha: 0.25))),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 20, backgroundColor: sc.withValues(alpha: 0.12),
                child: Text(studentName.isNotEmpty ? studentName[0].toUpperCase() : '?',
                    style: TextStyle(color: sc, fontWeight: FontWeight.bold, fontSize: 15))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(studentName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
              Text('ID: ${e['student_number'] ?? ''}', style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
            ])),
            StatusBadge(label: status, color: sc),
          ]),
          const SizedBox(height: 10),
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: AppTheme.surface, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              const Icon(Icons.science_outlined, size: 13, color: AppTheme.textMid),
              const SizedBox(width: 6),
              Expanded(child: Text('${e['equipment_name'] ?? ''}  •  Qty: ${e['quantity'] ?? 1}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textDark, fontWeight: FontWeight.w600))),
              const Icon(Icons.calendar_today_rounded, size: 13, color: AppTheme.textMid),
              const SizedBox(width: 4),
              Text('Due: ${(e['due_date'] ?? '').toString().split('T').first}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
            ]),
          ),
          if (status == 'Rejected' && '${e['reject_reason'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Reason: ${e['reject_reason']}',
                style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.danger,
                    fontStyle: FontStyle.italic)),
          ],
          // Audit trail — who acted on this request/loan.
          if (_auditLine(e).isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.badge_outlined, size: 12, color: AppTheme.textLight),
              const SizedBox(width: 4),
              Expanded(child: Text(_auditLine(e),
                  style: const TextStyle(fontSize: 10, color: AppTheme.textLight))),
            ]),
          ],
          if (showActions && status == 'Pending' && Session.canManage) ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: () => _confirmReject(txId),
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text('Deny'),
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger, side: const BorderSide(color: AppTheme.danger)),
              )),
              const SizedBox(width: 10),
              Expanded(child: ElevatedButton.icon(
                onPressed: () => _action(txId, 'approve'),
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Approve'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
              )),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _requestList(List<dynamic> items, String emptyText,
      {bool showActions = false}) {
    return ListView(padding: const EdgeInsets.all(16),
        children: items.isEmpty
            ? [Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(emptyText, style: const TextStyle(color: AppTheme.textMid))))]
            : items.map((e) => _buildCard(e, showActions: showActions)).toList());
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<dynamic>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Requests')),
            body: const Center(
                child: Text('Could not load requests.',
                    style: TextStyle(color: AppTheme.textMid))),
          );
        }
        final all = snap.data ?? const [];
        final pending  = all.where((e) => e['status'] == 'Pending').toList();
        final approved = all.where((e) => e['status'] == 'Approved').toList();

        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Requests'),
              bottom: const TabBar(
                indicatorColor: AppTheme.accent, labelColor: Colors.white,
                unselectedLabelColor: AppTheme.textLight,
                tabs: [Tab(text: 'Pending'), Tab(text: 'Approved'), Tab(text: 'All')],
              ),
            ),
            body: TabBarView(children: [
              _requestList(pending, 'No pending requests', showActions: true),
              _requestList(approved, 'No approved requests'),
              _requestList(all, 'No requests yet'),
            ]),
          ),
        );
      },
    );
  }
}



// ─── Admin Inventory Screen ──────────────────────────────────────────────────

class AdminInventoryScreen extends StatefulWidget {
  const AdminInventoryScreen({super.key});
  @override
  State<AdminInventoryScreen> createState() => _AdminInventoryScreenState();
}

class _AdminInventoryScreenState extends State<AdminInventoryScreen> {
  List<dynamic> _equipment = [];
  bool _loading = true;
  bool _hasError = false;
  String _search = '';
  // TODO(scalability): this category filter is single-select, so unlike the
  // student catalog's multi-select it COULD run server-side as
  //   .where('category', isEqualTo: _filter).orderBy('equipment_name')
  // which would stop the list paging through non-matching items. It needs a
  // composite index (category + equipment_name) created in the Firebase
  // console first — the query fails until that index finishes building, so it
  // was deliberately left client-side rather than risk it close to the
  // defense. The borrow picker's 'Available' filter needs the same treatment
  // (status + equipment_name). Do both in one pass when there is time to
  // verify the indexes.
  String _filter = 'All';
  final _categories = ['All', ..._kCategories];

  // Pagination — see ApiService.getEquipmentPage. The header counts come from
  // aggregation queries so they stay true for the whole inventory, not just
  // the pages loaded so far.
  static const int _pageSize = 20;
  final _scrollController = ScrollController();
  DocumentSnapshot? _cursor;
  bool _hasMore = true;
  bool _loadingMore = false;
  int _totalItems = 0;
  int _availableItems = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) _loadMore();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _hasError = false;
      _equipment = [];
      _cursor = null;
      _hasMore = true;
    });
    try {
      // Both start before either is awaited, so they run concurrently.
      final pageFuture   = ApiService.getEquipmentPage(limit: _pageSize);
      final countsFuture = ApiService.getEquipmentCounts();
      final page   = await pageFuture;
      final counts = await countsFuture;
      if (!mounted) return;
      setState(() {
        _equipment = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _totalItems = counts.total;
        _availableItems = counts.available;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { _loading = false; _hasError = true; });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final page = await ApiService.getEquipmentPage(
          limit: _pageSize, startAfter: _cursor);
      if (!mounted) return;
      setState(() {
        _equipment = [..._equipment, ...page.items];
        _cursor = page.cursor ?? _cursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Keep what is loaded; scrolling again retries.
      setState(() => _loadingMore = false);
    }
  }

  Color _conditionColor(String c) {
    switch (c) {
      case 'Available': return AppTheme.success;
      case 'Borrowed':  return AppTheme.warning;
      default:          return AppTheme.textMid;
    }
  }

  Widget _thumb(Map<String, dynamic> e, Color condColor) => EquipmentThumb(
        bytes: photoThumbOf(e),
        category: e['category'] as String? ?? '',
        color: condColor,
        size: 48,
      );

  // Trailing row of the inventory list: paging spinner, empty-result message,
  // or a quiet end-of-list marker.
  Widget _listFooter(bool isEmpty) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
              width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 60),
        child: Column(children: [
          Icon(Icons.inventory_2_outlined, size: 52, color: AppTheme.textLight),
          SizedBox(height: 12),
          Text('No equipment found',
              style: TextStyle(color: AppTheme.textMid, fontSize: 14)),
        ]),
      );
    }
    if (!_hasMore) {
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Center(
          child: Text('End of inventory',
              style: TextStyle(fontSize: 11, color: AppTheme.textLight)),
        ),
      );
    }
    return const SizedBox(height: 4);
  }

  void _openEdit(Map<String, dynamic> equipment) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditEquipmentSheet(
        equipment: equipment,
        onSaved: _load,
      ),
    );
  }

  Future<void> _confirmDelete(Map<String, dynamic> equipment) async {
    final id = '${equipment['equipment_id'] ?? ''}';
    final name = equipment['equipment_name'] ?? 'this equipment';
    if (id.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.delete_forever_rounded, color: AppTheme.danger, size: 44),
        title: const Text('Delete Equipment'),
        content: Text(
            'Permanently remove "$name" from the inventory? This cannot be undone.',
            textAlign: TextAlign.center),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(
              onPressed: () => Navigator.pop(dCtx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final res = await ApiService.deleteEquipment(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] == true
          ? '"$name" deleted.'
          : (res['message'] ?? 'Delete failed.')),
      backgroundColor: res['success'] == true ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
    if (res['success'] == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.wifi_off_rounded, size: 52, color: AppTheme.textLight),
            const SizedBox(height: 16),
            const Text('Failed to load inventory',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
            const SizedBox(height: 8),
            const Text('Check your internet connection and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
            const SizedBox(height: 20),
            ElevatedButton.icon(onPressed: _load,
                icon: const Icon(Icons.refresh_rounded), label: const Text('Try Again')),
          ]),
        ),
      );
    }

    final filtered = _equipment.where((e) {
      final matchCat = _filter == 'All' || e['category'] == _filter;
      final matchSearch = _search.isEmpty ||
          (e['equipment_name'] as String).toLowerCase().contains(_search.toLowerCase()) ||
          (e['qr_code'] as String).toLowerCase().contains(_search.toLowerCase());
      return matchCat && matchSearch;
    }).toList();

    // Counted server-side over the whole collection — the list below is only a
    // page of it, so these cannot be derived from _equipment.
    final totalItems       = _totalItems;
    final availableItems   = _availableItems;
    final unavailableItems = totalItems - availableItems;

    // An active search or category can hide everything loaded so far while
    // matches remain further down the collection; pull more until the list
    // fills or the inventory runs out.
    if (filtered.length < _pageSize && _hasMore && !_loadingMore && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    }

    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: Column(
        children: [
          // ── Header with summary stats ──
          Container(
            color: AppTheme.primary,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              children: [
                // Summary row
                Row(
                  children: [
                    _InvStat(label: 'Total Items', value: '$totalItems', icon: Icons.inventory_2_rounded, color: Colors.white),
                    const SizedBox(width: 10),
                    _InvStat(label: 'Available', value: '$availableItems', icon: Icons.check_circle_outline_rounded, color: AppTheme.success),
                    const SizedBox(width: 10),
                    _InvStat(label: 'Borrowed', value: '$unavailableItems', icon: Icons.remove_circle_outline_rounded, color: AppTheme.danger),
                  ],
                ),
                const SizedBox(height: 12),
                // Search bar
                TextField(
                  onChanged: (v) => setState(() => _search = v),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search by name or ID...',
                    hintStyle: const TextStyle(color: AppTheme.textLight),
                    prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.textLight),
                    filled: true,
                    fillColor: const Color(0x1AFFFFFF),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppTheme.accent, width: 1.5)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const SizedBox(height: 10),
                // Category filter chips
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _categories.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final c = _categories[i];
                      final sel = _filter == c;
                      return GestureDetector(
                        onTap: () => setState(() => _filter = c),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: sel ? AppTheme.accent : const Color(0x1AFFFFFF),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(c,
                              style: TextStyle(
                                  color: sel ? AppTheme.primary : AppTheme.textLight,
                                  fontSize: 12,
                                  fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // ── Equipment list ──
          Expanded(
            child: ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                    // One extra row for the paging footer.
                    itemCount: filtered.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      if (i == filtered.length) {
                        return _listFooter(filtered.isEmpty);
                      }
                      final e = filtered[i];
                      final status = e['status'] ?? 'Available';
                      final condColor = _conditionColor(status);

                      return GestureDetector(
                        onTap: () => Navigator.push(context,
                            MaterialPageRoute(
                                builder: (_) => EquipmentDetailScreen(equipment: e))),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border(left: BorderSide(color: condColor, width: 4)),
                          ),
                          child: Row(
                            children: [
                              _thumb(e, condColor),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(e['equipment_name'] as String,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
                                    const SizedBox(height: 2),
                                    Text('${e['qr_code']}  ·  ${e['category']}',
                                        style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                                    const SizedBox(height: 8),
                                    Row(children: [
                                      Expanded(child: StatusBadge(label: status, color: condColor)),
                                      const SizedBox(width: 12),
                                      StatusBadge(label: e['category'] as String, color: AppTheme.primary),
                                    ]),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                              if (Session.canManage)
                                PopupMenuButton<String>(
                                  onSelected: (v) {
                                    if (v == 'edit') _openEdit(e);
                                    if (v == 'delete') _confirmDelete(e);
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Row(children: [
                                        Icon(Icons.edit_outlined, size: 18, color: AppTheme.textMid),
                                        SizedBox(width: 8),
                                        Text('Edit Details'),
                                      ]),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Row(children: [
                                        Icon(Icons.delete_outline_rounded, size: 18, color: AppTheme.danger),
                                        SizedBox(width: 8),
                                        Text('Delete', style: TextStyle(color: AppTheme.danger)),
                                      ]),
                                    ),
                                  ],
                                  child: const Icon(Icons.more_vert_rounded, color: AppTheme.textLight),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: !Session.canManage ? null : FloatingActionButton.extended(
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          final result = await Navigator.push<Map<String, dynamic>>(
              context,
              MaterialPageRoute(builder: (_) => const EquipmentRegistrationScreen()));
          if (result != null) {
            _load();
            if (!mounted) return;
            messenger.showSnackBar(
              SnackBar(
                content: Text('${result['name']} registered successfully!'),
                backgroundColor: AppTheme.success,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            );
          }
        },
        backgroundColor: AppTheme.accent,
        foregroundColor: AppTheme.primary,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Equipment', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}

// ── Inventory stat mini-card ──
// ─── Edit Equipment Bottom Sheet ──────────────────────────────────────────────

class _EditEquipmentSheet extends StatefulWidget {
  final Map<String, dynamic> equipment;
  final VoidCallback onSaved;
  const _EditEquipmentSheet({required this.equipment, required this.onSaved});
  @override
  State<_EditEquipmentSheet> createState() => _EditEquipmentSheetState();
}

class _EditEquipmentSheetState extends State<_EditEquipmentSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _brandCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _serialCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _descCtrl;

  late String? _selectedCategory;
  late String _selectedStatus;
  late List<String> _selectedCourses;
  XFile? _pickedImage;
  bool _saving = false;

  final _imagePicker = ImagePicker();
  final _statuses    = _kStatuses;
  final _categories  = _kCategories;

  @override
  void initState() {
    super.initState();
    final e = widget.equipment;
    _nameCtrl     = TextEditingController(text: e['equipment_name'] as String? ?? '');
    _brandCtrl    = TextEditingController(text: e['brand']          as String? ?? '');
    _modelCtrl    = TextEditingController(text: e['model']          as String? ?? '');
    _serialCtrl   = TextEditingController(text: e['serial_number']  as String? ?? '');
    _locationCtrl = TextEditingController(text: e['location']       as String? ?? '');
    _descCtrl     = TextEditingController(text: e['description']    as String? ?? '');
    _selectedCategory = e['category'] as String?;
    _selectedStatus   = (e['status'] as String?) ?? 'Available';
    _selectedCourses  = List<String>.from((e['courses'] as List?) ?? []);
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _brandCtrl.dispose(); _modelCtrl.dispose();
    _serialCtrl.dispose(); _locationCtrl.dispose(); _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await _imagePicker.pickImage(
        source: source, imageQuality: 80, maxWidth: 1200);
    if (picked != null) setState(() => _pickedImage = picked);
  }

  Future<void> _save() async {
    final equipmentId = '${widget.equipment['equipment_id'] ?? ''}';
    if (equipmentId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Cannot edit demo equipment.'),
          backgroundColor: AppTheme.danger));
      return;
    }
    setState(() => _saving = true);
    try {
      String? photoError;
      if (_pickedImage != null) {
        final bytes = await _pickedImage!.readAsBytes();
        final saved = await ApiService.saveEquipmentPhoto(equipmentId, bytes);
        photoError = saved.error;
      }
      final res = await ApiService.updateEquipment(equipmentId, {
        'equipment_name': _nameCtrl.text.trim(),
        'category':       _selectedCategory ?? widget.equipment['category'],
        'status':         _selectedStatus,
        'location':       _locationCtrl.text.trim(),
        'brand':          _brandCtrl.text.trim(),
        'model':          _modelCtrl.text.trim(),
        'serial_number':  _serialCtrl.text.trim(),
        'description':    _descCtrl.text.trim(),
        'courses':        _selectedCourses,
      });
      if (!mounted) return;
      if (res['success'] == true) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        widget.onSaved();
        messenger.showSnackBar(photoError == null
            ? const SnackBar(
                content: Text('Equipment updated successfully.'),
                backgroundColor: AppTheme.success)
            : SnackBar(
                content: Text('Equipment updated, but the photo did not '
                    'upload: $photoError'),
                backgroundColor: AppTheme.warning,
                duration: const Duration(seconds: 6)));
      } else {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(res['message'] ?? 'Update failed.'),
            backgroundColor: AppTheme.danger));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Cannot connect to server.'),
            backgroundColor: AppTheme.danger));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.97,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40, height: 4,
            decoration: BoxDecoration(
                color: AppTheme.divider, borderRadius: BorderRadius.circular(2)),
          ),
          // Title row
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 12),
            child: Row(children: [
              const Expanded(
                child: Text('Edit Equipment',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                        color: AppTheme.textDark)),
              ),
              TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ]),
          ),
          const Divider(height: 1),
          // Scrollable form
          Expanded(
            child: ListView(controller: scroll, padding: const EdgeInsets.all(20),
              children: [
                // Photo picker
                _FieldLabel('Equipment Photo'),
                const SizedBox(height: 8),
                if (_pickedImage != null)
                  Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(File(_pickedImage!.path),
                          height: 160, width: double.infinity, fit: BoxFit.cover),
                    ),
                    Positioned(
                      top: 8, right: 8,
                      child: GestureDetector(
                        onTap: () => setState(() => _pickedImage = null),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                              color: AppTheme.danger, shape: BoxShape.circle),
                          child: const Icon(Icons.close_rounded,
                              color: Colors.white, size: 16),
                        ),
                      ),
                    ),
                  ])
                else if (photoThumbOf(widget.equipment) != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      photoThumbOf(widget.equipment)!,
                      height: 160, width: double.infinity, fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                    ),
                  )
                else
                  Container(
                    height: 100,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.divider),
                    ),
                    child: const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.image_outlined, size: 32, color: AppTheme.textLight),
                        SizedBox(height: 4),
                        Text('No photo', style: TextStyle(fontSize: 12, color: AppTheme.textLight)),
                      ]),
                    ),
                  ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Take Photo'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('From Gallery'),
                    ),
                  ),
                ]),
                const SizedBox(height: 20),

                // Status + Category
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _FieldLabel('Status *'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.divider)),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _selectedStatus,
                          items: _statuses.map((s) => DropdownMenuItem(
                              value: s,
                              child: Text(s, style: const TextStyle(fontSize: 13)))).toList(),
                          onChanged: (v) => setState(() => _selectedStatus = v!),
                        ),
                      ),
                    ),
                  ])),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _FieldLabel('Category *'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.divider)),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _selectedCategory,
                          hint: const Text('Select', style: TextStyle(fontSize: 13)),
                          items: _categories.map((c) => DropdownMenuItem(
                              value: c,
                              child: Text(c, style: const TextStyle(fontSize: 13)))).toList(),
                          onChanged: (v) => setState(() => _selectedCategory = v),
                        ),
                      ),
                    ),
                  ])),
                ]),
                const SizedBox(height: 16),

                _FieldLabel('Equipment Name *'),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Digital Multimeter',
                    prefixIcon: Icon(Icons.science_outlined, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 16),

                _FieldLabel('Storage Location'),
                const SizedBox(height: 8),
                TextField(
                  controller: _locationCtrl,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Cabinet A, Shelf 2',
                    prefixIcon: Icon(Icons.location_on_outlined, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 16),

                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _FieldLabel('Brand'),
                    const SizedBox(height: 8),
                    TextField(controller: _brandCtrl,
                        decoration: const InputDecoration(hintText: 'e.g. Fluke')),
                  ])),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _FieldLabel('Model'),
                    const SizedBox(height: 8),
                    TextField(controller: _modelCtrl,
                        decoration: const InputDecoration(hintText: 'e.g. 117')),
                  ])),
                ]),
                const SizedBox(height: 16),

                _FieldLabel('Serial Number'),
                const SizedBox(height: 8),
                TextField(
                  controller: _serialCtrl,
                  decoration: const InputDecoration(
                    hintText: 'e.g. SN-20241105-001',
                    prefixIcon: Icon(Icons.tag_rounded, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 16),

                _FieldLabel('Description'),
                const SizedBox(height: 8),
                TextField(
                  controller: _descCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'Brief description of the equipment...',
                  ),
                ),
                const SizedBox(height: 16),

                _FieldLabel('Available to Courses'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8, runSpacing: 6,
                  children: _kCourses.map((c) {
                    final sel = _selectedCourses.contains(c);
                    return FilterChip(
                      label: Text(courseLabel(c), style: TextStyle(
                          fontSize: 12, color: sel ? Colors.white : AppTheme.textDark)),
                      selected: sel,
                      selectedColor: AppTheme.primary,
                      backgroundColor: AppTheme.surface,
                      checkmarkColor: Colors.white,
                      side: BorderSide(color: sel ? AppTheme.primary : AppTheme.divider),
                      onSelected: (v) => setState(() {
                        if (v) { _selectedCourses.add(c); } else { _selectedCourses.remove(c); }
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 32),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'Saving…' : 'Save Changes'),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Inventory stat mini-card ──
class _InvStat extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _InvStat({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: TextStyle(
                          color: color, fontSize: 15, fontWeight: FontWeight.bold)),
                  Text(label,
                      style: const TextStyle(
                          color: AppTheme.textLight, fontSize: 9),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label, value;
  const _DetailRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textDark)),
        ],
      ),
    );
  }
}

// ─── Equipment Registration Screen ────────────────────────────────────────────

class EquipmentRegistrationScreen extends StatefulWidget {
  const EquipmentRegistrationScreen({super.key});
  @override
  State<EquipmentRegistrationScreen> createState() =>
      _EquipmentRegistrationScreenState();
}

class _EquipmentRegistrationScreenState
    extends State<EquipmentRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _brandCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _serialCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  // Pre-filled: the centred hintText '1' was indistinguishable from a real
  // value, so the form looked complete but failed validation with "Required".
  final _qtyCtrl = TextEditingController(text: '1');

  XFile? _pickedImage;
  final _imagePicker = ImagePicker();

  String? _selectedCategory;
  String? _selectedCondition;
  final List<String> _selectedCourses = [];
  bool _qrGenerated = false;
  String _generatedId = '';
  String _generatedQr = '';

  final _categories = _kCategories;
  final _conditions = ['Good', 'Fair', 'Under Repair', 'For Disposal'];

  String? _validateRequired(String? v) =>
      (v == null || v.trim().isEmpty) ? 'This field is required' : null;

  String? _validateQty(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final n = int.tryParse(v.trim());
    if (n == null || n < 1) return 'Enter a valid quantity (min 1)';
    return null;
  }

  void _generateAndSubmit() {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please select a category'),
          backgroundColor: AppTheme.danger));
      return;
    }
    if (_selectedCondition == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please select equipment condition'),
          backgroundColor: AppTheme.danger));
      return;
    }

    // Build the real QR code now (same scheme the backend uses) so the preview
    // matches the code that will be stored and printed.
    final cat = _selectedCategory ?? 'EQ';
    final prefix = cat.length >= 3 ? cat.substring(0, 3).toUpperCase() : cat.toUpperCase();
    final suffix = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
    setState(() {
      _generatedQr = '$prefix-$suffix';
      _generatedId = _generatedQr;
      _qrGenerated = true;
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await _imagePicker.pickImage(
        source: source, imageQuality: 80, maxWidth: 1200);
    if (picked != null) setState(() => _pickedImage = picked);
  }

  Future<void> _confirmSave() async {
    showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final res = await ApiService.addEquipment({
        'equipment_name': _nameCtrl.text.trim(),
        'category':       _selectedCategory,
        'location':       _locationCtrl.text.trim(),
        'courses':        List<String>.from(_selectedCourses),
        'description':    _descCtrl.text.trim(),
        'brand':          _brandCtrl.text.trim(),
        'model':          _modelCtrl.text.trim(),
        'serial_number':  _serialCtrl.text.trim(),
        'qr_code':        _generatedQr,
      });
      if (!mounted) return;
      if (res['success'] == true) {
        // Store the photo once the document exists and its id is known.
        String? photoError;
        if (_pickedImage != null) {
          final bytes = await _pickedImage!.readAsBytes();
          final saved = await ApiService.saveEquipmentPhoto(
              res['equipment_id'] as String, bytes);
          photoError = saved.error;
        }
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context); // close loading
        Navigator.pop(context, {
          'equipment_name': _nameCtrl.text.trim(),
          'qr_code':        res['qr_code'] ?? _generatedId,
          'category':       _selectedCategory,
          'status':         'Available',
          'location':       _locationCtrl.text.trim(),
        });
        if (photoError != null) {
          messenger.showSnackBar(SnackBar(
            content: Text('Equipment saved, but the photo could not be '
                'stored: $photoError'),
            backgroundColor: AppTheme.warning,
            duration: const Duration(seconds: 6),
          ));
        }
      } else {
        Navigator.pop(context); // close loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res['message'] ?? 'Failed to save.'), backgroundColor: AppTheme.danger));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot connect to server.'), backgroundColor: AppTheme.danger));
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _descCtrl.dispose(); _brandCtrl.dispose();
    _modelCtrl.dispose(); _serialCtrl.dispose();
    _locationCtrl.dispose(); _qtyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(title: const Text('Register Equipment')),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // ── Progress indicator ──
              _ProgressSteps(step: _qrGenerated ? 2 : 1),
              const SizedBox(height: 24),

              if (!_qrGenerated) ...[
                // ══════════════════════════════════════════
                // STEP 1 — Equipment Information
                // ══════════════════════════════════════════

                _SectionDivider(
                    icon: Icons.inventory_2_outlined,
                    label: 'Basic Information',
                    color: AppTheme.primary),
                const SizedBox(height: 16),

                _FieldLabel('Equipment Name *'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _nameCtrl,
                  validator: _validateRequired,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Digital Multimeter',
                    prefixIcon: Icon(Icons.science_outlined, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 16),

                _FieldLabel('Description'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _descCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'Brief description of the equipment and its purpose...',
                  ),
                ),
                const SizedBox(height: 16),

                _FieldLabel('Equipment Photo'),
                const SizedBox(height: 8),
                if (_pickedImage != null)
                  Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(_pickedImage!.path),
                        height: 160,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: 8, right: 8,
                      child: GestureDetector(
                        onTap: () => setState(() => _pickedImage = null),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                              color: AppTheme.danger, shape: BoxShape.circle),
                          child: const Icon(Icons.close_rounded,
                              color: Colors.white, size: 16),
                        ),
                      ),
                    ),
                  ])
                else
                  Container(
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.divider),
                    ),
                    child: const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.image_outlined, size: 36, color: AppTheme.textLight),
                        SizedBox(height: 6),
                        Text('No photo selected',
                            style: TextStyle(fontSize: 12, color: AppTheme.textLight)),
                      ]),
                    ),
                  ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Take Photo'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('From Gallery'),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),

                // Category + Condition side by side
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FieldLabel('Category *'),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                            decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppTheme.divider)),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: _selectedCategory,
                                hint: const Text('Select', style: TextStyle(color: AppTheme.textLight, fontSize: 13)),
                                items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 13)))).toList(),
                                onChanged: (v) => setState(() => _selectedCategory = v),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FieldLabel('Condition *'),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                            decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppTheme.divider)),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: _selectedCondition,
                                hint: const Text('Select', style: TextStyle(color: AppTheme.textLight, fontSize: 13)),
                                items: _conditions.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 13)))).toList(),
                                onChanged: (v) => setState(() => _selectedCondition = v),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                _FieldLabel('Available to Courses (leave empty for all)'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: _kCourses.map((c) {
                    final selected = _selectedCourses.contains(c);
                    return FilterChip(
                      label: Text(courseLabel(c), style: TextStyle(fontSize: 12, color: selected ? Colors.white : AppTheme.textDark)),
                      selected: selected,
                      selectedColor: AppTheme.primary,
                      backgroundColor: AppTheme.surface,
                      checkmarkColor: Colors.white,
                      side: BorderSide(color: selected ? AppTheme.primary : AppTheme.divider),
                      onSelected: (v) => setState(() {
                        if (v) { _selectedCourses.add(c); } else { _selectedCourses.remove(c); }
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 24),

                _SectionDivider(
                    icon: Icons.build_circle_outlined,
                    label: 'Technical Details',
                    color: AppTheme.primary),
                const SizedBox(height: 16),

                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FieldLabel('Brand / Manufacturer'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _brandCtrl,
                            decoration: const InputDecoration(hintText: 'e.g. Fluke'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FieldLabel('Model'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _modelCtrl,
                            decoration: const InputDecoration(hintText: 'e.g. 117'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                _FieldLabel('Serial Number'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _serialCtrl,
                  decoration: const InputDecoration(
                    hintText: 'e.g. SN-20241105-001',
                    prefixIcon: Icon(Icons.tag_rounded, color: AppTheme.textMid),
                  ),
                ),
                const SizedBox(height: 24),

                _SectionDivider(
                    icon: Icons.warehouse_outlined,
                    label: 'Quantity & Location',
                    color: AppTheme.primary),
                const SizedBox(height: 16),

                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 120,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FieldLabel('Quantity *'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _qtyCtrl,
                            validator: _validateQty,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            decoration: const InputDecoration(
                              hintText: '1',
                              prefixIcon: Icon(Icons.numbers_rounded, color: AppTheme.textMid),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FieldLabel('Storage Location'),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _locationCtrl,
                            decoration: const InputDecoration(
                              hintText: 'e.g. Cabinet A, Shelf 2',
                              prefixIcon: Icon(Icons.location_on_outlined, color: AppTheme.textMid),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),

                // Info note
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0x0F1B3A8C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x261B3A8C)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.qr_code_rounded, color: AppTheme.primary, size: 18),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'A unique QR code will be automatically generated for this equipment after saving. You can print it from the equipment detail page.',
                          style: TextStyle(fontSize: 12, color: AppTheme.textMid, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _generateAndSubmit,
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: const Text('Generate QR & Save'),
                  ),
                ),
              ],

              if (_qrGenerated) ...[
                // ══════════════════════════════════════════
                // STEP 2 — QR Code Generated
                // ══════════════════════════════════════════

                // Summary card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 52, height: 52,
                        decoration: BoxDecoration(
                          color: const Color(0x3306D6A0),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check_rounded, color: AppTheme.success, size: 28),
                      ),
                      const SizedBox(height: 12),
                      Text(_nameCtrl.text,
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 4),
                      Text('$_selectedCategory  ·  Qty: ${_qtyCtrl.text}',
                          style: const TextStyle(color: AppTheme.textLight, fontSize: 13)),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0x26F5A623),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_generatedId,
                            style: const TextStyle(
                                color: AppTheme.accent,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                letterSpacing: 2)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // QR Code display
                _SectionDivider(icon: Icons.qr_code_rounded, label: 'Generated QR Code', color: AppTheme.primary),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(color: const Color(0x141B3A8C), blurRadius: 12, offset: const Offset(0, 4))],
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 180, height: 180,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          border: Border.all(color: AppTheme.divider, width: 2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: _generatedQr.isEmpty
                            ? const SizedBox.shrink()
                            : QrImageView(
                                data: _generatedQr,
                                version: QrVersions.auto,
                                eyeStyle: const QrEyeStyle(
                                    eyeShape: QrEyeShape.square,
                                    color: AppTheme.primary),
                                dataModuleStyle: const QrDataModuleStyle(
                                    dataModuleShape: QrDataModuleShape.square,
                                    color: AppTheme.primary),
                              ),
                      ),
                      const SizedBox(height: 14),
                      Text(_generatedId,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textDark, letterSpacing: 1.5)),
                      const SizedBox(height: 4),
                      Text(_nameCtrl.text,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0x0F1B3A8C),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(children: [
                          Icon(Icons.info_outline_rounded,
                              color: AppTheme.primary, size: 16),
                          SizedBox(width: 8),
                          Expanded(child: Text(
                            'This QR is saved with the equipment. You can reopen '
                            'it any time from the equipment detail page to display '
                            'or screenshot for printing.',
                            style: TextStyle(fontSize: 11, color: AppTheme.textMid, height: 1.4),
                          )),
                        ]),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Equipment summary table
                _SectionDivider(icon: Icons.summarize_outlined, label: 'Registration Summary', color: AppTheme.primary),
                const SizedBox(height: 12),
                _DetailRow(label: 'Equipment Name', value: _nameCtrl.text),
                _DetailRow(label: 'Equipment ID', value: _generatedId),
                _DetailRow(label: 'Category', value: _selectedCategory ?? ''),
                _DetailRow(label: 'Condition', value: _selectedCondition ?? ''),
                _DetailRow(label: 'Quantity', value: '${_qtyCtrl.text} units'),
                if (_brandCtrl.text.isNotEmpty) _DetailRow(label: 'Brand', value: _brandCtrl.text),
                if (_modelCtrl.text.isNotEmpty) _DetailRow(label: 'Model', value: _modelCtrl.text),
                if (_serialCtrl.text.isNotEmpty) _DetailRow(label: 'Serial No.', value: _serialCtrl.text),
                if (_locationCtrl.text.isNotEmpty) _DetailRow(label: 'Location', value: _locationCtrl.text),
                const SizedBox(height: 28),

                // Confirm save
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _confirmSave,
                    icon: const Icon(Icons.check_circle_rounded),
                    label: const Text('Confirm & Add to Inventory'),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.success,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _qrGenerated = false),
                    icon: const Icon(Icons.arrow_back_rounded, size: 16),
                    label: const Text('Go Back & Edit'),
                    style: TextButton.styleFrom(foregroundColor: AppTheme.textMid),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// Progress steps widget shown at top of registration form
class _ProgressSteps extends StatelessWidget {
  final int step; // 1 or 2
  const _ProgressSteps({required this.step});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Step(number: '1', label: 'Equipment Info', active: step >= 1, done: step > 1),
        Expanded(child: Container(height: 2, color: step > 1 ? AppTheme.success : AppTheme.divider)),
        _Step(number: '2', label: 'QR Code', active: step >= 2, done: false),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final String number, label;
  final bool active, done;
  const _Step({required this.number, required this.label, required this.active, required this.done});

  @override
  Widget build(BuildContext context) {
    final color = done ? AppTheme.success : (active ? AppTheme.primary : AppTheme.textLight);
    return Column(
      children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: done ? AppTheme.success : (active ? AppTheme.primary : Colors.white),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: done
                ? const Icon(Icons.check_rounded, color: Colors.white, size: 16)
                : Text(number, style: TextStyle(color: active ? Colors.white : AppTheme.textLight, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ],
    );
  }
}

// ─── Admin Reports Screen ──────────────────────────────────────────────────────

class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});
  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  bool _loading = true;
  bool _exporting = false;

  // Reporting window. Borrowing figures below cover this many days back, not
  // all time — see the note in _load(). Surfaced in the UI and the exported
  // report so the numbers are never read as lifetime totals.
  static const int _reportPeriodDays = 90;

  // Live stats
  int _totalBorrowings   = 0;
  int _totalReturned     = 0;
  int _totalOverdue      = 0;
  int _totalDamage       = 0;
  int _totalEquipment    = 0;
  double _onTimeRate     = 0;

  // Most borrowed equipment map: name → count
  Map<String, int> _mostBorrowed = {};

  // Recent transactions for export
  List<dynamic> _allTransactions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Scoped to a reporting period rather than all-time: borrow_transactions
      // grows forever, so an unbounded read here gets more expensive every
      // semester. Equipment and damage totals are counted server-side.
      final cutoff = DateTime.now().subtract(Duration(days: _reportPeriodDays));
      final txF     = ApiService.getRequestsSince(cutoff);
      final eqF     = ApiService.getEquipmentCounts();
      final damageF = ApiService.damageReportCount();
      final txSnap        = await txF;
      final eqCounts      = await eqF;
      final damageReports = await damageF;

      // Count borrowing stats
      final now = DateTime.now();
      int returned = 0, overdue = 0;

      // Count most borrowed equipment
      final Map<String, int> borrowCount = {};
      for (final tx in txSnap) {
        final eqName = tx['equipment_name'] as String? ?? 'Unknown';
        borrowCount[eqName] = (borrowCount[eqName] ?? 0) + 1;

        if (tx['status'] == 'Returned') {
          returned++;
        }
        if (tx['status'] == 'Approved') {
          final due = DateTime.tryParse(
              '${tx['due_date']}'.replaceAll(' ', 'T'));
          if (due != null && due.isBefore(now)) overdue++;
        }
      }

      // Sort most borrowed descending
      final sorted = borrowCount.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final top4 = Map.fromEntries(sorted.take(4));

      final total = txSnap.length;
      final onTime = total > 0 ? (returned / total * 100) : 0.0;

      setState(() {
        _totalBorrowings  = total;
        _totalReturned    = returned;
        _totalOverdue     = overdue;
        _totalDamage      = damageReports;
        _totalEquipment   = eqCounts.total;
        _onTimeRate       = onTime;
        _mostBorrowed     = top4;
        _allTransactions  = txSnap;
        _loading          = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  // ── Generate and share a text report ──────────────────────────────────────
  Future<void> _exportReport() async {
    setState(() => _exporting = true);

    try {
      final now = DateTime.now();
      final dateStr =
          '${now.year}-${now.month.toString().padLeft(2,'0')}-${now.day.toString().padLeft(2,'0')}';
      final timeStr =
          '${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}';

      // Build report text
      final buf = StringBuffer();
      buf.writeln('==============================================');
      buf.writeln('  LABTRACK — CEA LABORATORY REPORT');
      buf.writeln('  New Era University');
      buf.writeln('  Generated: $dateStr at $timeStr');
      buf.writeln('==============================================');
      buf.writeln('');
      buf.writeln('SUMMARY  (last $_reportPeriodDays days)');
      buf.writeln('----------------------------------------------');
      buf.writeln('Borrowing figures below cover the last '
          '$_reportPeriodDays days. Equipment and damage report');
      buf.writeln('totals are current counts.');
      buf.writeln('');
      buf.writeln('Total Borrowings   : $_totalBorrowings');
      buf.writeln('Total Returned     : $_totalReturned');
      buf.writeln('Total Overdue      : $_totalOverdue');
      buf.writeln('Damage Reports     : $_totalDamage');
      buf.writeln('Total Equipment    : $_totalEquipment');
      buf.writeln('On-Time Return Rate: ${_onTimeRate.toStringAsFixed(1)}%');
      buf.writeln('');
      buf.writeln('MOST BORROWED EQUIPMENT');
      buf.writeln('----------------------------------------------');
      int rank = 1;
      _mostBorrowed.forEach((name, cnt) {
        buf.writeln('$rank. $name — ${cnt}x borrowed');
        rank++;
      });

      if (_allTransactions.isNotEmpty) {
        buf.writeln('');
        buf.writeln('TRANSACTION LOG');
        buf.writeln('----------------------------------------------');
        for (final tx in _allTransactions) {
          final status  = tx['status'] ?? '';
          final student = tx['borrower_name'] ?? tx['student_number'] ?? '—';
          final equip   = tx['equipment_name'] ?? '—';
          final bDate   = '${tx['borrow_date'] ?? ''}'.split('T').first;
          buf.writeln('[$status] $student | $equip | $bDate');
        }
      }

      buf.writeln('');
      buf.writeln('==============================================');
      buf.writeln('  END OF REPORT — LabTrack v1.0');
      buf.writeln('==============================================');

      final reportText = buf.toString();

      // Show report in a dialog with copy option
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(children: const [
            Icon(Icons.assessment_rounded, color: AppTheme.primary),
            SizedBox(width: 10),
            Text('Full Report'),
          ]),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        reportText,
                        style: const TextStyle(
                          fontFamily: 'Courier New',
                          fontSize: 11,
                          color: Color(0xFF00FF88),
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Tap "Copy" to copy the report to your clipboard.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMid),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close', style: TextStyle(color: AppTheme.textMid)),
            ),
            ElevatedButton.icon(
              onPressed: () {
                // Copy to clipboard
                // ignore: deprecated_member_use
                Clipboard.setData(ClipboardData(text: reportText));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('✅ Report copied to clipboard! Paste it in Notes or Email.'),
                    backgroundColor: AppTheme.success,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy Report'),
            ),
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e'), backgroundColor: AppTheme.danger));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Build most borrowed bars
    final maxCount = _mostBorrowed.values.isEmpty
        ? 1
        : _mostBorrowed.values.reduce((a, b) => a > b ? a : b);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // Borrowing figures are scoped to a period, not all-time.
              Row(children: [
                const Icon(Icons.event_note_outlined,
                    size: 14, color: AppTheme.textMid),
                const SizedBox(width: 6),
                Text('Borrowing activity — last $_reportPeriodDays days',
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textMid,
                        fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 12),

              // ── Summary Cards ──
              Row(children: [
                _ReportCard(
                  label: 'Total\nBorrowings',
                  value: '$_totalBorrowings',
                  icon: Icons.trending_up_rounded,
                  color: AppTheme.accent,
                ),
                const SizedBox(width: 12),
                _ReportCard(
                  label: 'On-Time\nReturns',
                  value: '${_onTimeRate.toStringAsFixed(0)}%',
                  icon: Icons.check_circle_outline_rounded,
                  color: AppTheme.success,
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _ReportCard(
                  label: 'Overdue\nItems',
                  value: '$_totalOverdue',
                  icon: Icons.warning_amber_rounded,
                  color: AppTheme.danger,
                ),
                const SizedBox(width: 12),
                _ReportCard(
                  label: 'Damage\nReports',
                  value: '$_totalDamage',
                  icon: Icons.report_problem_outlined,
                  color: AppTheme.warning,
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _ReportCard(
                  label: 'Total\nEquipment',
                  value: '$_totalEquipment',
                  icon: Icons.science_rounded,
                  color: AppTheme.primary,
                ),
                const SizedBox(width: 12),
                _ReportCard(
                  label: 'Returned\nSuccessfully',
                  value: '$_totalReturned',
                  icon: Icons.assignment_return_rounded,
                  color: AppTheme.success,
                ),
              ]),
              const SizedBox(height: 24),

              // ── Most Borrowed ──
              const SectionHeader(title: 'Most Borrowed Equipment'),
              const SizedBox(height: 12),
              if (_mostBorrowed.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14)),
                  child: const Center(
                    child: Text('No borrowing data yet.',
                        style: TextStyle(color: AppTheme.textMid)),
                  ),
                )
              else
                ..._mostBorrowed.entries.map((e) {
                  final ratio = maxCount > 0 ? e.value / maxCount : 0.0;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14)),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.key,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: AppTheme.textDark)),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: ratio,
                                  minHeight: 6,
                                  backgroundColor: AppTheme.divider,
                                  valueColor: const AlwaysStoppedAnimation(
                                      AppTheme.accent),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text('${e.value}x',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.accent)),
                      ]),
                    ),
                  );
                }),
              const SizedBox(height: 24),

              // ── Recent Transactions ──
              const SectionHeader(title: 'Recent Transactions'),
              const SizedBox(height: 12),
              if (_allTransactions.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14)),
                  child: const Center(
                    child: Text('No transactions yet.',
                        style: TextStyle(color: AppTheme.textMid)),
                  ),
                )
              else
                Container(
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14)),
                  child: Column(
                    children: _allTransactions.take(8).map((tx) {
                      final status   = tx['status'] ?? '';
                      final student  = tx['borrower_name'] ??
                          tx['student_number'] ?? '—';
                      final equip    = tx['equipment_name'] ?? '—';
                      final bDate    =
                          '${tx['borrow_date'] ?? ''}'.split('T').first.split(' ').first;
                      final sc = status == 'Approved' ? AppTheme.success
                               : status == 'Pending'  ? AppTheme.accent
                               : status == 'Returned' ? AppTheme.textMid
                               : AppTheme.danger;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: AppTheme.divider),
                          ),
                        ),
                        child: Row(children: [
                          Container(
                            width: 8, height: 8,
                            decoration: BoxDecoration(
                                color: sc, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(student, style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold,
                                color: AppTheme.textDark)),
                            Text(equip, style: const TextStyle(
                                fontSize: 11, color: AppTheme.textMid)),
                          ])),
                          Column(crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                            StatusBadge(label: status, color: sc),
                            const SizedBox(height: 2),
                            Text(bDate, style: const TextStyle(
                                fontSize: 10, color: AppTheme.textLight)),
                          ]),
                        ]),
                      );
                    }).toList(),
                  ),
                ),
              const SizedBox(height: 24),

              // ── Export Button ──
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _exporting ? null : _exportReport,
                  icon: _exporting
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.download_rounded),
                  label: Text(_exporting ? 'Generating...' : 'Export Full Report'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Report will be copied to your clipboard — paste it in Notes, Email, or Google Docs.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: AppTheme.textMid),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _ReportCard(
      {required this.label,
      required this.value,
      required this.icon,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: color.withAlpha(31),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: color)),
                Text(label,
                    style: const TextStyle(
                        fontSize: 10, color: AppTheme.textMid)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Admin Damage Reports Screen (staff review) ───────────────────────────────
// Lets laboratory staff review damage reports filed by students (and logged on
// QR returns), mark them resolved, and place a hold on the borrower.
class AdminDamageReportsScreen extends StatefulWidget {
  const AdminDamageReportsScreen({super.key});
  @override
  State<AdminDamageReportsScreen> createState() =>
      _AdminDamageReportsScreenState();
}

class _AdminDamageReportsScreenState extends State<AdminDamageReportsScreen> {
  bool _loading = true;
  List<dynamic> _reports = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getDamageReports();
      if (!mounted) return;
      setState(() { _reports = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'Resolved': return AppTheme.success;
      case 'Reviewed': return AppTheme.primary;
      default:         return AppTheme.warning; // Open
    }
  }

  Future<void> _resolve(Map<String, dynamic> r) async {
    final res = await ApiService.updateDamageReport('${r['report_id']}', 'Resolved');
    if (!mounted) return;
    if (res['success'] == true) _load();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] == true
          ? 'Report marked resolved.'
          : (res['message'] ?? 'Failed.')),
      backgroundColor: res['success'] == true ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _holdBorrower(Map<String, dynamic> r) async {
    final sid = '${r['student_id'] ?? ''}';
    if (sid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No linked student account for this report.'),
        backgroundColor: AppTheme.danger, behavior: SnackBarBehavior.floating));
      return;
    }
    final res = await ApiService.setStudentHold(sid, true,
        reason: 'Damaged equipment "${r['equipment_name'] ?? ''}" pending settlement.');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] == true
          ? 'Hold placed on borrower.'
          : (res['message'] ?? 'Failed.')),
      backgroundColor: AppTheme.danger, behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Damage Reports')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _reports.isEmpty
              ? const Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.verified_outlined, size: 52, color: AppTheme.textLight),
                    SizedBox(height: 12),
                    Text('No damage reports', style: TextStyle(color: AppTheme.textMid)),
                  ]),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _reports.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final r = _reports[i];
                      final status = '${r['status'] ?? 'Open'}';
                      final sc = _statusColor(status);
                      final date = '${r['reported_at'] ?? ''}'.split('T').first;
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border(left: BorderSide(color: sc, width: 4)),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            const Icon(Icons.report_problem_outlined,
                                color: AppTheme.warning, size: 20),
                            const SizedBox(width: 8),
                            Expanded(child: Text('${r['equipment_name'] ?? 'Equipment'}',
                                style: const TextStyle(fontWeight: FontWeight.bold,
                                    fontSize: 14, color: AppTheme.textDark))),
                            StatusBadge(label: status, color: sc),
                          ]),
                          const SizedBox(height: 8),
                          Text('${r['description'] ?? ''}',
                              style: const TextStyle(fontSize: 13,
                                  color: AppTheme.textMid, height: 1.5)),
                          const SizedBox(height: 8),
                          Row(children: [
                            const Icon(Icons.person_outline_rounded, size: 13, color: AppTheme.textLight),
                            const SizedBox(width: 4),
                            Expanded(child: Text(
                                '${r['borrower_name'] ?? r['student_number'] ?? '—'}',
                                style: const TextStyle(fontSize: 12, color: AppTheme.textMid))),
                            const Icon(Icons.calendar_today_rounded, size: 12, color: AppTheme.textLight),
                            const SizedBox(width: 4),
                            Text(date, style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
                          ]),
                          if (Session.canManage && status != 'Resolved') ...[
                            const SizedBox(height: 12),
                            const Divider(height: 1, color: AppTheme.divider),
                            const SizedBox(height: 10),
                            Row(children: [
                              Expanded(child: OutlinedButton.icon(
                                onPressed: () => _holdBorrower(r),
                                icon: const Icon(Icons.gpp_maybe_outlined, size: 16),
                                label: const Text('Hold'),
                                style: OutlinedButton.styleFrom(
                                    foregroundColor: AppTheme.danger,
                                    side: const BorderSide(color: AppTheme.danger)),
                              )),
                              const SizedBox(width: 10),
                              Expanded(child: ElevatedButton.icon(
                                onPressed: () => _resolve(r),
                                icon: const Icon(Icons.check_rounded, size: 16),
                                label: const Text('Resolve'),
                                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
                              )),
                            ]),
                          ],
                        ]),
                      );
                    },
                  ),
                ),
    );
  }
}

// ─── Admin Penalties / Holds Screen (Prof recommendation #3) ──────────────────
// Surfaces students on a borrowing hold and students with overdue loans, and
// lets staff place or lift holds.
class AdminPenaltiesScreen extends StatefulWidget {
  const AdminPenaltiesScreen({super.key});
  @override
  State<AdminPenaltiesScreen> createState() => _AdminPenaltiesScreenState();
}

class _AdminPenaltiesScreenState extends State<AdminPenaltiesScreen> {
  bool _loading = true;
  List<dynamic> _held = [];
  List<dynamic> _overdue = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final held = await ApiService.getHeldStudents();
      final reqs = await ApiService.getRequests();
      final now = DateTime.now();
      final overdue = reqs.where((e) {
        if (e['status'] != 'Approved') return false;
        final due = DateTime.tryParse('${e['due_date']}'.replaceAll(' ', 'T'));
        return due != null && due.isBefore(now);
      }).toList();
      if (!mounted) return;
      setState(() { _held = held; _overdue = overdue; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setHold(String sid, bool hold, {String reason = ''}) async {
    if (sid.isEmpty) return;
    final res = await ApiService.setStudentHold(sid, hold, reason: reason);
    if (!mounted) return;
    if (res['success'] == true) _load();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res['success'] == true
          ? (hold ? 'Hold placed.' : 'Hold lifted.')
          : (res['message'] ?? 'Failed.')),
      backgroundColor: res['success'] == true ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Penalties & Holds')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                const SectionHeader(title: 'Students on Hold'),
                const SizedBox(height: 10),
                if (_held.isEmpty)
                  _penaltyEmpty('No students are currently on hold.')
                else
                  ..._held.map(_holdCard),
                const SizedBox(height: 24),
                const SectionHeader(title: 'Overdue Loans'),
                const SizedBox(height: 10),
                if (_overdue.isEmpty)
                  _penaltyEmpty('No overdue loans.')
                else
                  ..._overdue.map(_overdueCard),
                const SizedBox(height: 20),
              ]),
            ),
    );
  }

  Widget _penaltyEmpty(String msg) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Center(
            child: Text(msg,
                style: const TextStyle(color: AppTheme.textMid, fontSize: 13))),
      );

  Widget _holdCard(dynamic s) {
    final sid = '${s['student_id'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: AppTheme.danger, width: 4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.gpp_bad_outlined, color: AppTheme.danger, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('${s['name'] ?? s['student_number'] ?? 'Student'}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14,
                  color: AppTheme.textDark))),
          StatusBadge(label: 'On Hold', color: AppTheme.danger),
        ]),
        const SizedBox(height: 6),
        Text('${s['hold_reason'] ?? ''}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
        if (Session.canManage) ...[
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: () => _setHold(sid, false),
            icon: const Icon(Icons.lock_open_rounded, size: 16),
            label: const Text('Lift Hold'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
          )),
        ],
      ]),
    );
  }

  Widget _overdueCard(dynamic e) {
    final sid = '${e['student_id'] ?? ''}';
    final due = '${e['due_date'] ?? ''}'.split('T').first;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: AppTheme.warning, width: 4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.schedule_rounded, color: AppTheme.warning, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('${e['borrower_name'] ?? e['student_number'] ?? 'Student'}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14,
                  color: AppTheme.textDark))),
          StatusBadge(label: 'Overdue', color: AppTheme.warning),
        ]),
        const SizedBox(height: 6),
        Text('${e['equipment_name'] ?? ''}  •  Due: $due',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
        if (Session.canManage) ...[
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            onPressed: sid.isEmpty
                ? null
                : () => _setHold(sid, true,
                    reason: 'Overdue: "${e['equipment_name'] ?? 'equipment'}" not returned by $due.'),
            icon: const Icon(Icons.gpp_maybe_outlined, size: 16),
            label: const Text('Place Hold'),
            style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.danger,
                side: const BorderSide(color: AppTheme.danger)),
          )),
        ],
      ]),
    );
  }
}

// ─── Admin Students Directory ─────────────────────────────────────────────────
// Staff-only, searchable list of registered students. Tapping one opens their
// detail view. Viewers can browse it read-only. The security rules already let
// any staff member read the students collection while blocking student-to-
// student reads, so this exposes no more than staff already handle on every
// borrow request.
class AdminStudentsScreen extends StatefulWidget {
  const AdminStudentsScreen({super.key});
  @override
  State<AdminStudentsScreen> createState() => _AdminStudentsScreenState();
}

class _AdminStudentsScreenState extends State<AdminStudentsScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _loading = true;
  List<dynamic> _all = [];

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getStudents();
      if (!mounted) return;
      setState(() { _all = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<dynamic> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all.where((s) {
      final name = '${s['name'] ?? ''}'.toLowerCase();
      final number = '${s['student_number'] ?? ''}'.toLowerCase();
      return name.contains(q) || number.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Students')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Search by name or student number',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () { _searchCtrl.clear(); setState(() => _query = ''); },
                    ),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
            ),
          ),
        ),
        if (!_loading)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('${_filtered.length} student${_filtered.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _filtered.isEmpty
                      ? ListView(children: [
                          const SizedBox(height: 80),
                          Center(child: Text(
                            _query.isEmpty
                                ? 'No students registered yet.'
                                : 'No students match "$_query".',
                            style: const TextStyle(color: AppTheme.textMid))),
                        ])
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _filtered.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (_, i) => _studentTile(_filtered[i]),
                        ),
                ),
        ),
      ]),
    );
  }

  Widget _studentTile(dynamic s) {
    final name = '${s['name'] ?? 'Student'}';
    final onHold = s['hold'] == true;
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(
              builder: (_) => AdminStudentDetailScreen(student: Map<String, dynamic>.from(s))));
          _load(); // reflect any hold change made in the detail view
        },
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: const Color(0x141B3A8C),
          child: Text(_initials(name),
              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        ),
        title: Text(name,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
        subtitle: Text('${s['student_number'] ?? ''}  •  ${courseLabel('${s['course'] ?? ''}')}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
        trailing: onHold
            ? StatusBadge(label: 'On Hold', color: AppTheme.danger)
            : const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppTheme.textLight),
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }
}

// ─── Admin Student Detail ─────────────────────────────────────────────────────
// One student's profile, borrowing history, and — for staff who can manage —
// hold and password-reset actions. Viewers see everything but no action buttons.
class AdminStudentDetailScreen extends StatefulWidget {
  final Map<String, dynamic> student;
  const AdminStudentDetailScreen({super.key, required this.student});
  @override
  State<AdminStudentDetailScreen> createState() => _AdminStudentDetailScreenState();
}

class _AdminStudentDetailScreenState extends State<AdminStudentDetailScreen> {
  late Map<String, dynamic> _student;
  List<dynamic> _txns = [];
  bool _loadingTxns = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _student = Map<String, dynamic>.from(widget.student);
    _loadTxns();
  }

  String get _sid => '${_student['student_id'] ?? ''}';

  Future<void> _loadTxns() async {
    setState(() => _loadingTxns = true);
    try {
      final t = await ApiService.getStudentTransactions(_sid);
      if (!mounted) return;
      setState(() { _txns = t; _loadingTxns = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingTxns = false);
    }
  }

  Future<void> _refreshStudent() async {
    final fresh = await ApiService.getStudent(_sid);
    if (fresh != null && mounted) setState(() => _student = fresh);
  }

  void _snack(String msg, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? AppTheme.success : AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _placeHold() async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Place Hold'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('The student will be blocked from borrowing until the hold '
              'is lifted. Add a reason they will see.',
              style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
          const SizedBox(height: 12),
          TextField(controller: reasonCtrl, maxLines: 2,
            decoration: const InputDecoration(
                hintText: 'e.g. Unreturned multimeter; settle with lab staff')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(onPressed: () => Navigator.pop(dCtx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              child: const Text('Place Hold')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final res = await ApiService.setStudentHold(_sid, true, reason: reasonCtrl.text.trim());
    if (mounted) setState(() => _busy = false);
    if (res['success'] == true) { await _refreshStudent(); _snack('Hold placed.'); }
    else { _snack(res['message'] ?? 'Failed to place hold.', ok: false); }
  }

  Future<void> _liftHold() async {
    setState(() => _busy = true);
    final res = await ApiService.setStudentHold(_sid, false);
    if (mounted) setState(() => _busy = false);
    if (res['success'] == true) { await _refreshStudent(); _snack('Hold lifted.'); }
    else { _snack(res['message'] ?? 'Failed to lift hold.', ok: false); }
  }

  Future<void> _sendReset() async {
    final email = '${_student['email'] ?? ''}';
    if (email.isEmpty) { _snack('This student has no email on file.', ok: false); return; }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Send Password Reset'),
        content: Text('Send a password-reset email to $email?',
            style: const TextStyle(fontSize: 13, color: AppTheme.textMid)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMid))),
          ElevatedButton(onPressed: () => Navigator.pop(dCtx, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final res = await ApiService.sendPasswordReset(email);
    if (mounted) setState(() => _busy = false);
    _snack(res['success'] == true
        ? 'Reset email sent to $email.'
        : (res['message'] ?? 'Could not send reset email.'),
        ok: res['success'] == true);
  }

  @override
  Widget build(BuildContext context) {
    final onHold = _student['hold'] == true;
    final name = '${_student['name'] ?? 'Student'}';
    return Scaffold(
      appBar: AppBar(title: const Text('Student')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            CircleAvatar(radius: 28, backgroundColor: const Color(0x141B3A8C),
              child: Text(_initials(name),
                  style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 18))),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textDark)),
              const SizedBox(height: 2),
              Text('${_student['student_number'] ?? ''}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
            ])),
            if (onHold) StatusBadge(label: 'On Hold', color: AppTheme.danger),
          ]),
        ),
        const SizedBox(height: 12),
        // Info rows (each is its own card)
        _DetailRow(label: 'Program', value: courseLabel('${_student['course'] ?? ''}')),
        _DetailRow(label: 'Year Level', value: '${_student['year_level'] ?? '-'}'),
        _DetailRow(label: 'Email', value: '${_student['email'] ?? '-'}'),
        _DetailRow(label: 'Member Since', value: _memberSince()),
        // Reliability summary (once history has loaded)
        if (!_loadingTxns) ...[
          const SizedBox(height: 4),
          _reliabilityCard(),
        ],
        // Hold reason
        if (onHold && '${_student['hold_reason'] ?? ''}'.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0x14E53935), borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x33E53935))),
            child: Row(children: [
              const Icon(Icons.gpp_bad_outlined, color: AppTheme.danger, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text('${_student['hold_reason']}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textDark))),
            ]),
          ),
        ],
        // Actions — managers only; viewers see the info above but no buttons.
        if (Session.canManage) ...[
          const SizedBox(height: 16),
          if (onHold)
            SizedBox(width: double.infinity, child: ElevatedButton.icon(
              onPressed: _busy ? null : _liftHold,
              icon: const Icon(Icons.lock_open_rounded, size: 16),
              label: const Text('Lift Hold'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
            ))
          else
            SizedBox(width: double.infinity, child: ElevatedButton.icon(
              onPressed: _busy ? null : _placeHold,
              icon: const Icon(Icons.gpp_maybe_outlined, size: 16),
              label: const Text('Place Hold'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            )),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            onPressed: _busy ? null : _sendReset,
            icon: const Icon(Icons.mail_outline_rounded, size: 16),
            label: const Text('Send Password Reset'),
            style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary, side: const BorderSide(color: AppTheme.primary)),
          )),
        ],
        const SizedBox(height: 24),
        SectionHeader(
          title: 'Borrowing History',
          action: _txns.isEmpty ? null : 'Export',
          onAction: _txns.isEmpty ? null : _exportHistory,
        ),
        const SizedBox(height: 10),
        if (_loadingTxns)
          const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
        else if (_txns.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: const Center(child: Text('No borrowing records.',
                style: TextStyle(color: AppTheme.textMid, fontSize: 13))),
          )
        else
          ..._txns.map(_txnCard),
        const SizedBox(height: 20),
      ]),
    );
  }

  Widget _reliabilityCard() {
    final r = ApiService.studentReliability(_txns);
    final rating = '${r['rating']}';
    final color = rating == 'Good'
        ? AppTheme.success
        : rating == 'Fair'
            ? AppTheme.warning
            : AppTheme.danger;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Reliability',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.textDark)),
          const Spacer(),
          StatusBadge(label: rating, color: color),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _relStat('${r['loans']}', 'Loans', AppTheme.primary)),
          Expanded(child: _relStat('${r['late']}', 'Late', AppTheme.warning)),
          Expanded(child: _relStat('${r['overdue']}', 'Overdue', AppTheme.danger)),
          Expanded(child: _relStat('${r['damages']}', 'Damages', AppTheme.danger)),
        ]),
      ]),
    );
  }

  Widget _relStat(String value, String label, Color color) => Column(children: [
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textMid)),
      ]);

  Future<void> _exportHistory() async {
    final buf = StringBuffer();
    buf.writeln('LabTrack — Student Borrowing History');
    buf.writeln('=====================================');
    buf.writeln('Name        : ${_student['name'] ?? ''}');
    buf.writeln('Student No. : ${_student['student_number'] ?? ''}');
    buf.writeln('Program     : ${courseLabel('${_student['course'] ?? ''}')}');
    buf.writeln('Year Level  : ${_student['year_level'] ?? '-'}');
    final r = ApiService.studentReliability(_txns);
    buf.writeln('Reliability : ${r['rating']} '
        '(loans ${r['loans']}, late ${r['late']}, overdue ${r['overdue']}, damages ${r['damages']})');
    buf.writeln('Generated   : ${DateTime.now()}');
    buf.writeln('');
    buf.writeln('Transactions (${_txns.length}):');
    if (_txns.isEmpty) {
      buf.writeln('  (none)');
    } else {
      for (final e in _txns) {
        final name = '${e['equipment_name'] ?? 'Equipment'}';
        final status = '${e['status'] ?? ''}';
        final borrow = '${e['borrow_date'] ?? ''}'.split('T').first;
        final due = '${e['due_date'] ?? ''}'.split('T').first;
        buf.writeln('  - $name | $status | borrowed $borrow | due $due');
      }
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('History copied to clipboard. Paste into Notes or email.'),
      backgroundColor: AppTheme.success,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Widget _txnCard(dynamic e) {
    final status = '${e['status'] ?? ''}';
    final color = status == 'Approved' ? AppTheme.success
        : status == 'Pending' ? AppTheme.accent
        : status == 'Rejected' ? AppTheme.danger
        : AppTheme.textMid;
    final borrow = '${e['borrow_date'] ?? ''}'.split('T').first;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        const Icon(Icons.science_outlined, size: 18, color: AppTheme.textMid),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${e['equipment_name'] ?? 'Equipment'}',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textDark)),
          if (borrow.isNotEmpty)
            Text('Borrowed: $borrow',
                style: const TextStyle(fontSize: 11, color: AppTheme.textMid)),
        ])),
        StatusBadge(label: status, color: color),
      ]),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  String _memberSince() {
    final raw = _student['created_at'];
    DateTime? dt;
    if (raw is Timestamp) {
      dt = raw.toDate();
    } else {
      dt = DateTime.tryParse('$raw');
    }
    if (dt == null) return '-';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
