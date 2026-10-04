import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

// ─── Firebase Service ─────────────────────────────────────────────────────────
class ApiService {
  static final _auth = FirebaseAuth.instance;
  static final _db   = FirebaseFirestore.instance;

  // ── Auth ──────────────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> login(
      String identifier, String password, String role) async {
    try {
      if (role == 'student') {
        // Students login with student_number → find their email first
        final snap = await _db
            .collection('students')
            .where('student_number', isEqualTo: identifier)
            .limit(1)
            .get();
        if (snap.docs.isEmpty) {
          return {'success': false, 'message': 'Student ID not found.'};
        }
        final studentData = snap.docs.first.data();
        final email = studentData['email'] as String;
        await _auth.signInWithEmailAndPassword(email: email, password: password);
        final user = {...studentData, 'student_id': snap.docs.first.id};
        return {'success': true, 'role': 'student', 'user': user};
      } else {
        // Staff login with email
        await _auth.signInWithEmailAndPassword(
            email: identifier, password: password);
        final uid  = _auth.currentUser!.uid;
        final snap = await _db.collection('staff').doc(uid).get();
        if (!snap.exists) {
          // Check by email if doc not found by uid
          final q = await _db
              .collection('staff')
              .where('email', isEqualTo: identifier)
              .limit(1)
              .get();
          if (q.docs.isEmpty) {
            return {'success': false, 'message': 'Staff account not found.'};
          }
          final data = {...q.docs.first.data(), 'staff_id': q.docs.first.id};
          return {'success': true, 'role': 'staff', 'user': data};
        }
        final data = {...snap.data()!, 'staff_id': uid};
        return {'success': true, 'role': 'staff', 'user': data};
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
      return {'success': false, 'message': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> registerStudent(
      Map<String, dynamic> data) async {
    try {
      final email    = data['email'] as String;
      final password = data['password'] as String;
      final name     = '${data['first_name']} ${data['last_name']}';
      final studentNumber = data['student_number'] as String;

      // Step 1: Create Firebase Auth user first
      UserCredential cred;
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

      // Step 2: Now authenticated — check student_number uniqueness
      try {
        final existing = await _db
            .collection('students')
            .where('student_number', isEqualTo: studentNumber)
            .limit(1)
            .get();
        if (existing.docs.isNotEmpty) {
          // Delete the auth user we just created since student_number is taken
          await cred.user!.delete();
          return {'success': false, 'message': 'Student ID is already registered.'};
        }
      } catch (_) {
        // If the uniqueness check fails, still allow — better to have
        // a duplicate than block valid registrations
      }

      // Step 3: Save student profile to Firestore
      await _db.collection('students').doc(uid).set({
        'name':           name,
        'email':          email,
        'student_number': studentNumber,
        'course':         data['course'] ?? '',
        'year_level':     data['year_level'] ?? 1,
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
      return {'success': false, 'message': e.toString()};
    }
  }

  // ── Equipment ─────────────────────────────────────────────────────────────
  static Future<List<dynamic>> getEquipment(
      {String search = '', String category = ''}) async {
    if (Session.isDemoMode) {
      await Future.delayed(const Duration(milliseconds: 400));
      var data = Session.demoEquipment;
      if (search.isNotEmpty)
        data = data
            .where((e) => (e['equipment_name'] as String)
                .toLowerCase()
                .contains(search.toLowerCase()))
            .toList();
      if (category.isNotEmpty)
        data = data.where((e) => e['category'] == category).toList();
      return data;
    }
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

  static Future<Map<String, dynamic>> getEquipmentByQr(String qrCode) async {
    if (Session.isDemoMode) {
      await Future.delayed(const Duration(milliseconds: 300));
      final match =
          Session.demoEquipment.where((e) => e['qr_code'] == qrCode).toList();
      if (match.isEmpty)
        return {'success': false, 'message': 'Equipment not found.'};
      return {'success': true, 'data': match.first};
    }
    final snap = await _db
        .collection('equipment')
        .where('qr_code', isEqualTo: qrCode)
        .limit(1)
        .get();
    if (snap.docs.isEmpty)
      return {'success': false, 'message': 'Equipment not found.'};
    final data = {
      ...snap.docs.first.data() as Map<String, dynamic>,
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
      // Auto-generate QR code
      final prefix  = category.substring(0, 3).toUpperCase();
      final suffix  = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
      final qrCode  = '$prefix-$suffix';
      final ref = await _db.collection('equipment').add({
        'equipment_name': name,
        'category':       category,
        'location':       location,
        'qr_code':        qrCode,
        'status':         'Available',
        'created_at':     FieldValue.serverTimestamp(),
      });
      return {
        'success':      true,
        'message':      'Equipment added successfully.',
        'equipment_id': ref.id,
        'qr_code':      qrCode,
      };
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  // ── Borrow / Return ───────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> borrowEquipment(
      Map<String, dynamic> data) async {
    if (Session.isDemoMode) {
      await Future.delayed(const Duration(milliseconds: 500));
      return {
        'success': true,
        'message': 'Demo: Borrow request submitted!',
        'transaction_id': 'demo-99'
      };
    }
    try {
      final equipId = data['equipment_id'].toString();
      // Check equipment is Available
      final eqDoc = await _db.collection('equipment').doc(equipId).get();
      if (!eqDoc.exists)
        return {'success': false, 'message': 'Equipment not found.'};
      final eqData = eqDoc.data() as Map<String, dynamic>;
      if (eqData['status'] != 'Available')
        return {
          'success': false,
          'message': 'Equipment is currently ${eqData['status']}.'
        };

      final due = DateTime.now();
      final dueDate = DateTime(due.year, due.month, due.day, 17, 0, 0);
      final ref = await _db.collection('borrow_transactions').add({
        'student_id':     data['student_id'].toString(),
        'equipment_id':   equipId,
        'equipment_name': eqData['equipment_name'],
        'qr_code':        eqData['qr_code'],
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
      return {'success': false, 'message': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> returnEquipment(
      dynamic transactionId, String condition) async {
    if (Session.isDemoMode) {
      await Future.delayed(const Duration(milliseconds: 400));
      return {'success': true, 'message': 'Demo: Equipment returned!'};
    }
    try {
      final txDoc =
          await _db.collection('borrow_transactions').doc('$transactionId').get();
      if (!txDoc.exists)
        return {'success': false, 'message': 'Transaction not found.'};
      final equipId =
          (txDoc.data() as Map<String, dynamic>)['equipment_id'] as String;
      // Update transaction
      await _db.collection('borrow_transactions').doc('$transactionId').update({
        'status':             'Returned',
        'return_date':        FieldValue.serverTimestamp(),
        'condition_returned': condition,
      });
      // Update equipment back to Available
      await _db
          .collection('equipment')
          .doc(equipId)
          .update({'status': 'Available'});
      return {'success': true, 'message': 'Equipment returned successfully.'};
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  // ── Transactions ──────────────────────────────────────────────────────────
  static Future<List<dynamic>> getMyBorrowings(
      {dynamic studentId = 0, String studentNumber = ''}) async {
    if (Session.isDemoMode) {
      await Future.delayed(const Duration(milliseconds: 400));
      return Session.demoBorrowings;
    }
    final sid = Session.currentUser?['student_id']?.toString() ?? '';
    final snap = await _db
        .collection('borrow_transactions')
        .where('student_id', isEqualTo: sid)
        .orderBy('borrow_date', descending: true)
        .get();
    return snap.docs.map((d) {
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
  }

  static Future<List<dynamic>> getRequests({String status = ''}) async {
    if (Session.isDemoMode) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (status.isEmpty || status == 'All') return Session.demoRequests;
      return Session.demoRequests
          .where((e) => e['status'] == status)
          .toList();
    }
    Query q = _db
        .collection('borrow_transactions')
        .orderBy('borrow_date', descending: true);
    if (status.isNotEmpty) q = q.where('status', isEqualTo: status);
    final snap = await q.get();
    return snap.docs.map((d) {
      final data = d.data() as Map<String, dynamic>;
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
  }

  static Future<Map<String, dynamic>> updateRequestStatus(
      dynamic transactionId, String action) async {
    if (Session.isDemoMode) {
      await Future.delayed(const Duration(milliseconds: 400));
      return {'success': true, 'message': 'Demo: Status updated!'};
    }
    try {
      final txDoc =
          await _db.collection('borrow_transactions').doc('$transactionId').get();
      if (!txDoc.exists)
        return {'success': false, 'message': 'Transaction not found.'};
      final equipId =
          (txDoc.data() as Map<String, dynamic>)['equipment_id'] as String;

      if (action == 'approve') {
        await _db
            .collection('borrow_transactions')
            .doc('$transactionId')
            .update({'status': 'Approved'});
        await _db
            .collection('equipment')
            .doc(equipId)
            .update({'status': 'Borrowed'});
        return {'success': true, 'message': 'Request approved.'};
      } else {
        await _db
            .collection('borrow_transactions')
            .doc('$transactionId')
            .update({'status': 'Rejected'});
        return {'success': true, 'message': 'Request rejected.'};
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  // ── Dashboard Stats ───────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> getDashboardStats() async {
    if (Session.isDemoMode) {
      await Future.delayed(const Duration(milliseconds: 300));
      return {
        'pending_requests':    2,
        'active_loans':        2,
        'overdue_loans':       0,
        'total_equipment':     9,
        'available_equipment': 7,
        'damage_reports':      1,
      };
    }
    try {
      final eqSnap  = await _db.collection('equipment').get();
      final txSnap  = await _db.collection('borrow_transactions').get();
      final total   = eqSnap.docs.length;
      final avail   = eqSnap.docs.where((d) => d['status'] == 'Available').length;
      final pending = txSnap.docs.where((d) => d['status'] == 'Pending').length;
      final active  = txSnap.docs.where((d) => d['status'] == 'Approved').length;
      final now     = DateTime.now();
      final overdue = txSnap.docs.where((d) {
        if (d['status'] != 'Approved') return false;
        final due = (d['due_date'] as Timestamp?)?.toDate();
        return due != null && due.isBefore(now);
      }).length;
      return {
        'pending_requests':    pending,
        'active_loans':        active,
        'overdue_loans':       overdue,
        'total_equipment':     total,
        'available_equipment': avail,
        'damage_reports':      0,
      };
    } catch (e) {
      return {};
    }
  }

  // ── Damage Report ─────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> submitDamageReport(
      Map<String, dynamic> data) async {
    try {
      final ref = await _db.collection('damage_reports').add({
        ...data,
        'reported_at': FieldValue.serverTimestamp(),
      });
      return {
        'success':   true,
        'message':   'Damage report submitted successfully.',
        'report_id': ref.id,
      };
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
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
      return {'success': false, 'message': e.toString()};
    }
  }
}

// ─── Session (simple in-memory user state) ───────────────────────────────────
class Session {
  static Map<String, dynamic>? currentUser;
  static String? role; // 'student' or 'staff'
  static bool isDemoMode = false;

  static void set(Map<String, dynamic> user, String r, {bool demo = false}) {
    currentUser = user;
    role = r;
    isDemoMode = demo;
  }

  static void clear() {
    currentUser = null;
    role = null;
    isDemoMode = false;
  }

  static String get name => currentUser?['name'] ?? 'User';
  static String get studentNumber => currentUser?['student_number'] ?? '';
  static int get studentId => int.tryParse('${currentUser?['student_id'] ?? 0}') ?? 0;
  static String get initials {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : 'U';
  }

  // ── Sample data shown when in demo mode ──────────────────────────────────
  static final List<Map<String, dynamic>> demoEquipment = [
    {'equipment_id': '1', 'equipment_name': 'Digital Multimeter',  'category': 'Electronics',     'qr_code': 'ELE-001', 'status': 'Available',  'location': 'Cabinet A'},
    {'equipment_id': '2', 'equipment_name': 'Oscilloscope',         'category': 'Electronics',     'qr_code': 'ELE-002', 'status': 'Borrowed',   'location': 'Cabinet A'},
    {'equipment_id': '3', 'equipment_name': 'Breadboard Kit',       'category': 'Electronics',     'qr_code': 'ELE-003', 'status': 'Available',  'location': 'Cabinet B'},
    {'equipment_id': '4', 'equipment_name': 'Soldering Iron Kit',   'category': 'Tools',           'qr_code': 'TOO-001', 'status': 'Available',  'location': 'Cabinet C'},
    {'equipment_id': '5', 'equipment_name': 'Vernier Caliper',      'category': 'Measurement',     'qr_code': 'MEA-001', 'status': 'Available',  'location': 'Cabinet D'},
    {'equipment_id': '6', 'equipment_name': 'Micrometer',           'category': 'Measurement',     'qr_code': 'MEA-002', 'status': 'Available',  'location': 'Cabinet D'},
    {'equipment_id': '7', 'equipment_name': 'Optical Lens Set',     'category': 'Optics',          'qr_code': 'OPT-001', 'status': 'Borrowed',   'location': 'Cabinet E'},
    {'equipment_id': '8', 'equipment_name': 'Power Supply Unit',    'category': 'Electronics',     'qr_code': 'ELE-004', 'status': 'Available',  'location': 'Cabinet A'},
    {'equipment_id': '9', 'equipment_name': 'Arduino Kit',          'category': 'Microcontroller', 'qr_code': 'MIC-001', 'status': 'Available',  'location': 'Cabinet B'},
  ];

  static final List<Map<String, dynamic>> demoBorrowings = [
    {'transaction_id': '1', 'equipment_name': 'Digital Multimeter', 'qr_code': 'ELE-001', 'status': 'Approved',  'due_date': '2026-04-01', 'student_number': '2024-00001', 'borrower_name': 'Demo Student', 'quantity': 1},
    {'transaction_id': '2', 'equipment_name': 'Breadboard Kit',     'qr_code': 'ELE-003', 'status': 'Pending',   'due_date': '2026-04-05', 'student_number': '2024-00001', 'borrower_name': 'Demo Student', 'quantity': 2},
    {'transaction_id': '3', 'equipment_name': 'Vernier Caliper',    'qr_code': 'MEA-001', 'status': 'Returned',  'due_date': '2026-03-20', 'student_number': '2024-00001', 'borrower_name': 'Demo Student', 'quantity': 1},
  ];

  static final List<Map<String, dynamic>> demoRequests = [
    {'transaction_id': '1', 'equipment_name': 'Digital Multimeter', 'qr_code': 'ELE-001', 'status': 'Pending',  'due_date': '2026-04-01T00:00:00', 'student_number': '2024-00123', 'borrower_name': 'Juan Santos',  'quantity': 1},
    {'transaction_id': '2', 'equipment_name': 'Oscilloscope',        'qr_code': 'ELE-002', 'status': 'Pending',  'due_date': '2026-04-03T00:00:00', 'student_number': '2024-00145', 'borrower_name': 'Ana Reyes',    'quantity': 1},
    {'transaction_id': '3', 'equipment_name': 'Breadboard Kit',      'qr_code': 'ELE-003', 'status': 'Approved', 'due_date': '2026-04-05T00:00:00', 'student_number': '2024-00167', 'borrower_name': 'Leo Cruz',     'quantity': 2},
    {'transaction_id': '4', 'equipment_name': 'Soldering Iron Kit',  'qr_code': 'TOO-001', 'status': 'Approved', 'due_date': '2026-03-28T00:00:00', 'student_number': '2024-00111', 'borrower_name': 'Maria Lim',    'quantity': 1},
    {'transaction_id': '5', 'equipment_name': 'Vernier Caliper',     'qr_code': 'MEA-001', 'status': 'Returned', 'due_date': '2026-03-20T00:00:00', 'student_number': '2024-00099', 'borrower_name': 'Carlo Bato',   'quantity': 3},
  ];
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const LabBorrowApp());
}



// ─── App Entry ───────────────────────────────────────────────────────────────

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

// ─── Theme ────────────────────────────────────────────────────────────────────

class AppTheme {
  // ── NEU Brand Colors ──────────────────────────────────────────────────────
  static const Color primary    = Color(0xFF1B3A8C);   // NEU royal blue
  static const Color primaryDark= Color(0xFF112266);   // darker navy for gradients
  static const Color accent     = Color(0xFFF5A623);   // NEU gold (from seal)
  static const Color success    = Color(0xFF27AE60);   // green
  static const Color warning    = Color(0xFFF39C12);   // amber-orange
  static const Color danger     = Color(0xFFE74C3C);   // red
  static const Color surface    = Color(0xFFF0F3FA);   // very light blue-grey
  static const Color cardBg     = Color(0xFFFFFFFF);
  static const Color textDark   = Color(0xFF1A2340);   // near-black blue
  static const Color textMid    = Color(0xFF5A6A8A);
  static const Color textLight  = Color(0xFF9AAAC8);
  static const Color divider    = Color(0xFFDDE4F0);

  static ThemeData get lightTheme => ThemeData(
        fontFamily: 'Roboto',
        colorScheme: const ColorScheme.light(
          primary: primary,
          secondary: accent,
          surface: surface,
        ),
        scaffoldBackgroundColor: surface,
        appBarTheme: const AppBarTheme(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontFamily: 'Roboto',
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: 0.3,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ),
        cardTheme: CardThemeData(
          color: cardBg,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: primary, width: 2),
          ),
        ),
      );
}

// ── NEU Logo Widget ───────────────────────────────────────────────────────────
// Uses a circular golden seal look matching the NEU crest.
// Replace with: Image.asset('assets/neu_logo.png') once you add the asset.
class NeuLogo extends StatelessWidget {
  final double size;
  const NeuLogo({super.key, this.size = 48});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: AppTheme.accent, width: size * 0.04),
        boxShadow: [
          BoxShadow(
              color: AppTheme.accent.withOpacity(0.25),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: ClipOval(
        // 👉 Swap this entire child with:
        //    Image.asset('assets/neu_logo.png', fit: BoxFit.cover)
        //    after adding the PNG to your assets folder.
        child: CustomPaint(
          painter: _NeuSealPainter(),
        ),
      ),
    );
  }
}

class _NeuSealPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;

    // Background fill
    canvas.drawCircle(Offset(cx, cy), r,
        Paint()..color = const Color(0xFF1B3A8C));

    // Outer gold ring
    canvas.drawCircle(
        Offset(cx, cy),
        r * 0.90,
        Paint()
          ..color = const Color(0xFFF5A623)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.06);

    // Inner white ring
    canvas.drawCircle(
        Offset(cx, cy),
        r * 0.75,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.03);

    // White "NEU" text in center
    final tp = TextPainter(
      text: TextSpan(
        text: 'NEU',
        style: TextStyle(
          color: Colors.white,
          fontSize: r * 0.30,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));

    // Gold dots around ring
    final dotPaint = Paint()..color = const Color(0xFFF5A623);
    for (int i = 0; i < 12; i++) {
      final angle = (i / 12) * 3.14159 * 2;
      final dx = cx + r * 0.82 * cos(angle);
      final dy = cy + r * 0.82 * sin(angle);
      canvas.drawCircle(Offset(dx, dy), r * 0.025, dotPaint);
    }
  }

  double cos(double a) => _cos(a);
  double sin(double a) => _sin(a);
  static double _cos(double a) {
    // simple cos approximation via dart:math
    return _mathCos(a);
  }
  static double _sin(double a) {
    return _mathSin(a);
  }
  static double _mathCos(double a) => _mathFunc(a, true);
  static double _mathSin(double a) => _mathFunc(a, false);
  static double _mathFunc(double a, bool isCos) {
    // Taylor series — good enough for small circle dots
    double result = isCos ? 1.0 : a;
    double term = isCos ? 1.0 : a;
    for (int i = 1; i <= 10; i++) {
      int n = isCos ? 2 * i : 2 * i + 1;
      term *= -a * a / ((n - 1) * n);
      result += term;
    }
    return result;
  }

  @override
  bool shouldRepaint(_NeuSealPainter _) => false;
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
        color: color.withOpacity(0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4)),
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
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.pushReplacement(
            context, MaterialPageRoute(builder: (_) => const LoginScreen()));
      }
    });
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
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const NeuLogo(size: 90),
              const SizedBox(height: 24),
              const Text('LabTrack',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2)),
              const SizedBox(height: 8),
              const Text('CEA Laboratory · New Era University',
                  style: TextStyle(
                      color: AppTheme.textLight, fontSize: 14, letterSpacing: 1)),
              const SizedBox(height: 60),
              const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      color: AppTheme.accent, strokeWidth: 2)),
            ],
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
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl   = TextEditingController();

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
        Session.set(res['user'] as Map<String, dynamic>, res['role'] as String);
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (_) => _isStudent ? const StudentHomeScreen() : const AdminDashboardScreen()));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res['message'] ?? 'Login failed.'), backgroundColor: AppTheme.danger));
      }
    } catch (e) {
      final msg = e.toString();
      String userMsg;
      if (msg.contains('network') || msg.contains('Network') || msg.contains('unavailable')) {
        userMsg = 'No internet connection. Please check your Wi-Fi or mobile data.';
      } else if (msg.contains('timeout') || msg.contains('Timeout')) {
        userMsg = 'Connection timed out. Please try again.';
      } else {
        userMsg = 'Error: $msg';
      }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.primary,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 48),
            const NeuLogo(size: 64),
            const SizedBox(height: 12),
            const Text('LabTrack',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5)),
            const SizedBox(height: 4),
            const Text('New Era University · Lab System',
                style: TextStyle(color: AppTheme.textLight, fontSize: 13)),
            const SizedBox(height: 36),
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
                              ? 'e.g. 2024-00123'
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
                          hintText: '••••••••',
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
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text('Forgot password?',
                            style: const TextStyle(
                                color: AppTheme.accent,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
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
                      const SizedBox(height: 10),
                      // ── Test Connection ──
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            try {
                              final res = await ApiService.getEquipment();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text('✅ Connected! Found ${res.length} equipment items.'),
                                backgroundColor: AppTheme.success,
                                behavior: SnackBarBehavior.floating,
                              ));
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text('❌ Cannot connect to Firebase: ${e.toString()}'),
                                backgroundColor: AppTheme.danger,
                                behavior: SnackBarBehavior.floating,
                                duration: const Duration(seconds: 5),
                              ));
                            }
                          },
                          icon: const Icon(Icons.cloud_rounded, size: 16),
                          label: const Text('Test Firebase Connection'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.textMid,
                            side: const BorderSide(color: AppTheme.divider),
                          ),
                        ),
                      ),
                      // ── Demo Mode ──
                      const SizedBox(height: 20),
                      Row(children: const [
                        Expanded(child: Divider(color: AppTheme.divider)),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Text('DEMO MODE',
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold,
                                  color: AppTheme.textLight, letterSpacing: 1)),
                        ),
                        Expanded(child: Divider(color: AppTheme.divider)),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                          child: _DemoButton(
                            label: 'Student Demo',
                            icon: Icons.school_rounded,
                            color: AppTheme.primary,
                            onTap: () {
                              Session.set({
                                'student_id':     '1',
                                'name':           'Demo Student',
                                'student_number': '2024-00001',
                                'course':         'BSECE',
                                'year_level':     3,
                              }, 'student', demo: true);
                              Navigator.pushReplacement(context, MaterialPageRoute(
                                  builder: (_) => const StudentHomeScreen()));
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _DemoButton(
                            label: 'Staff Demo',
                            icon: Icons.admin_panel_settings_rounded,
                            color: AppTheme.accent,
                            onTap: () {
                              Session.set({
                                'staff_id': '1',
                                'name':     'Demo Staff',
                                'email':    'demo@neu.edu.ph',
                                'role':     'admin',
                              }, 'staff', demo: true);
                              Navigator.pushReplacement(context, MaterialPageRoute(
                                  builder: (_) => const AdminDashboardScreen()));
                            },
                          ),
                        ),
                      ]),
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

// ─── Demo Button Widget ───────────────────────────────────────────────────────

class _DemoButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _DemoButton({required this.label, required this.icon,
      required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 5),
          Text(label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text('Tap to enter', style: TextStyle(fontSize: 10, color: color.withOpacity(0.6))),
        ]),
      ),
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
  final _courseCtrl = TextEditingController();
  final _yearCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();

  bool _obscurePass = true;
  bool _obscureConfirm = true;
  bool _agreedToTerms = false;

  // Live email validation state
  bool get _emailValid =>
      RegExp(r'^[a-zA-Z]+\.[a-zA-Z]+@neu\.edu\.ph$')
          .hasMatch(_emailCtrl.text.trim());

  // Live student ID validation
  bool get _idValid =>
      RegExp(r'^\d{2}-\d{5}-\d{3}$').hasMatch(_studentIdCtrl.text.trim());

  String? _validateEmail(String? val) {
    if (val == null || val.trim().isEmpty) return 'Required';
    if (!RegExp(r'^[a-zA-Z]+\.[a-zA-Z]+@neu\.edu\.ph$')
        .hasMatch(val.trim())) {
      return 'Must be firstname.lastname@neu.edu.ph';
    }
    return null;
  }

  String? _validateStudentId(String? val) {
    if (val == null || val.trim().isEmpty) return 'Required';
    if (!RegExp(r'^\d{2}-\d{5}-\d{3}$').hasMatch(val.trim())) {
      return 'Format: ##-#####-### (e.g. 19-10975-366)';
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
          'course':         _courseCtrl.text.trim(),
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
                  decoration: BoxDecoration(color: AppTheme.success.withOpacity(0.12), shape: BoxShape.circle),
                  child: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 40)),
                const SizedBox(height: 20),
                const Text('Account Created!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textDark)),
                const SizedBox(height: 10),
                Text('Welcome, ${_firstNameCtrl.text}! Your account has been created. You can now sign in to LabTrack.',
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
            const SnackBar(content: Text('Cannot connect to server. Check your IP and Laragon.'), backgroundColor: AppTheme.danger));
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
    _courseCtrl.dispose();
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

                        // ── SECTION: Identity Verification ──
                        _SectionDivider(
                          icon: Icons.verified_user_outlined,
                          label: 'Identity Verification',
                          color: AppTheme.accent,
                        ),
                        const SizedBox(height: 16),

                        // Institutional Email
                        _FieldLabel('Institutional Email'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          validator: _validateEmail,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'juan.delacruz@neu.edu.ph',
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
                        const Text('Format: firstname.lastname@neu.edu.ph',
                            style: TextStyle(
                                fontSize: 11, color: AppTheme.textLight)),
                        const SizedBox(height: 16),

                        // Student ID
                        _FieldLabel('Student ID'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _studentIdCtrl,
                          keyboardType: TextInputType.text,
                          autocorrect: false,
                          validator: _validateStudentId,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: '19-10975-366',
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
                        const Text('Format: ##-#####-### (e.g. 19-10975-366)',
                            style: TextStyle(
                                fontSize: 11, color: AppTheme.textLight)),
                        const SizedBox(height: 20),

                        // Info box
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppTheme.accent.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppTheme.accent.withOpacity(0.2)),
                          ),
                          child: const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.info_outline_rounded,
                                  size: 16, color: AppTheme.accent),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                    'Your institutional email and Student ID are used to verify that you are an enrolled student. These must match your school records.',
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
                                        hintText: 'Juan'),
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
                                        hintText: 'Dela Cruz'),
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
                                  TextFormField(
                                    controller: _courseCtrl,
                                    validator: _validateRequired,
                                    decoration: const InputDecoration(
                                        hintText: 'BSECE'),
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
                        GestureDetector(
                          onTap: () =>
                              setState(() => _agreedToTerms = !_agreedToTerms),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: 22,
                                height: 22,
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
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    text: 'I agree to the ',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.textMid),
                                    children: [
                                      TextSpan(
                                          text: 'Terms and Conditions',
                                          style: TextStyle(
                                              color: AppTheme.accent,
                                              fontWeight: FontWeight.bold)),
                                      TextSpan(text: ' and '),
                                      TextSpan(
                                          text: 'Privacy Policy',
                                          style: TextStyle(
                                              color: AppTheme.accent,
                                              fontWeight: FontWeight.bold)),
                                      TextSpan(
                                          text:
                                              ' of the LabTrack borrowing system.'),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
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
            color: color.withOpacity(0.1),
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
          if (Session.isDemoMode)
            Container(
              width: double.infinity,
              color: AppTheme.accent,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.play_circle_outline_rounded, color: Colors.white, size: 14),
                SizedBox(width: 6),
                Text('DEMO MODE — Data is not saved to the database',
                    style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ]),
            ),
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
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final loans = await ApiService.getMyBorrowings(
        studentId: Session.studentId,
        studentNumber: Session.studentNumber,
      );
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

      if (status == 'Approved' && due != null) {
        if (due.year == now.year && due.month == now.month && due.day == now.day) {
          notes.add({
            'icon':  Icons.access_alarm_rounded,
            'color': AppTheme.warning,
            'title': 'Due Today',
            'body':  '$equipName is due back today before 5:00 PM.',
          });
        } else if (due.isBefore(now)) {
          notes.add({
            'icon':  Icons.warning_amber_rounded,
            'color': AppTheme.danger,
            'title': 'Overdue!',
            'body':  '$equipName was due on ${due.month}/${due.day}. Please return it immediately.',
          });
        }
      }
      if (status == 'Approved' && due != null && !due.isBefore(now)) {
        notes.add({
          'icon':  Icons.check_circle_rounded,
          'color': AppTheme.success,
          'title': 'Request Approved',
          'body':  'Your request for $equipName has been approved.',
        });
      }
      if (status == 'Rejected') {
        notes.add({
          'icon':  Icons.cancel_rounded,
          'color': AppTheme.danger,
          'title': 'Request Rejected',
          'body':  'Your request for $equipName was rejected by staff.',
        });
      }
    }
    return notes;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 100,
              pinned: true,
              backgroundColor: AppTheme.primary,
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppTheme.primary, AppTheme.primaryDark],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 44, 16, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: AppTheme.accent.withOpacity(0.2),
                        child: Text(Session.initials,
                            style: const TextStyle(
                                color: AppTheme.accent,
                                fontSize: 13,
                                fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('Good day,',
                              style: TextStyle(color: AppTheme.textLight, fontSize: 11)),
                          Text(Session.name,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const Spacer(),
                      Stack(
                        children: [
                          IconButton(
                              icon: const Icon(Icons.notifications_outlined,
                                  color: Colors.white, size: 22),
                              onPressed: () {}),
                          if (_notifications.isNotEmpty)
                            Positioned(
                              right: 8, top: 8,
                              child: Container(
                                width: 7, height: 7,
                                decoration: const BoxDecoration(
                                    color: AppTheme.danger,
                                    shape: BoxShape.circle),
                              ),
                            ),
                        ],
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
                      // ── Live Stats ──
                      Row(children: [
                        _StatCard(
                            label: 'Active Loans',
                            value: '${_activeLoans.length}',
                            icon: Icons.inventory_2_rounded,
                            color: AppTheme.accent),
                        const SizedBox(width: 12),
                        _StatCard(
                            label: 'Due Today',
                            value: '$_dueToday',
                            icon: Icons.schedule_rounded,
                            color: AppTheme.warning),
                        const SizedBox(width: 12),
                        _StatCard(
                            label: 'Overdue',
                            value: '$_overdue',
                            icon: Icons.warning_amber_rounded,
                            color: _overdue > 0 ? AppTheme.danger : AppTheme.success),
                      ]),
                      const SizedBox(height: 24),

                      // ── Live Notifications ──
                      const SectionHeader(title: 'Notifications'),
                      const SizedBox(height: 12),
                      if (_notifications.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16)),
                          child: const Center(
                            child: Column(children: [
                              Icon(Icons.notifications_none_rounded,
                                  size: 36, color: AppTheme.textLight),
                              SizedBox(height: 8),
                              Text('No notifications',
                                  style: TextStyle(color: AppTheme.textMid, fontSize: 13)),
                            ]),
                          ),
                        )
                      else
                        ..._notifications.map((n) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _NotificationCard(
                            icon:  n['icon'] as IconData,
                            color: n['color'] as Color,
                            title: n['title'] as String,
                            body:  n['body']  as String,
                            time:  'Now',
                          ),
                        )),
                      const SizedBox(height: 24),

                      // ── Quick Actions ──
                      const SectionHeader(title: 'Quick Actions'),
                      const SizedBox(height: 12),
                      Row(children: [
                        _QuickAction(
                            icon: Icons.add_circle_outline_rounded,
                            label: 'New Request',
                            color: AppTheme.accent,
                            onTap: () => Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const BorrowRequestScreen()))),
                        const SizedBox(width: 12),
                        _QuickAction(
                            icon: Icons.report_problem_outlined,
                            label: 'Report',
                            color: AppTheme.warning,
                            onTap: () => Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const DamageReportScreen()))),
                        const SizedBox(width: 12),
                        _QuickAction(
                            icon: Icons.receipt_long_rounded,
                            label: 'My Loans',
                            color: AppTheme.primary,
                            onTap: () => Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const MyBorrowingsScreen()))),
                        const SizedBox(width: 12),
                        _QuickAction(
                            icon: Icons.history_rounded,
                            label: 'History',
                            color: AppTheme.textMid,
                            onTap: () => Navigator.push(context,
                                MaterialPageRoute(builder: (_) => const MyBorrowingsScreen()))),
                      ]),
                      const SizedBox(height: 24),

                      // ── Live Active Loans ──
                      SectionHeader(
                          title: 'Active Loans',
                          action: _activeLoans.isNotEmpty ? 'See all' : null,
                          onAction: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const MyBorrowingsScreen()))),
                      const SizedBox(height: 12),
                      if (_activeLoans.isEmpty && _pendingLoans.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16)),
                          child: const Center(
                            child: Column(children: [
                              Icon(Icons.inventory_2_outlined,
                                  size: 36, color: AppTheme.textLight),
                              SizedBox(height: 8),
                              Text('No active loans',
                                  style: TextStyle(color: AppTheme.textMid, fontSize: 13)),
                            ]),
                          ),
                        )
                      else ...[
                        // Show pending first
                        ..._pendingLoans.take(2).map((e) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _LoanCard(
                              name: e['equipment_name'] ?? '',
                              id:   e['qr_code'] ?? '',
                              dueDate: 'Awaiting approval',
                              statusColor: AppTheme.accent,
                              statusLabel: 'Pending',
                            ),
                          );
                        }),
                        // Then active/approved
                        ..._activeLoans.take(3).map((e) {
                          final due = DateTime.tryParse(
                              '${e['due_date']}'.replaceAll(' ', 'T'));
                          final now = DateTime.now();
                          final isOverdue = due != null && due.isBefore(now);
                          final isDueToday = due != null &&
                              due.year == now.year &&
                              due.month == now.month &&
                              due.day == now.day;
                          final statusLabel = isOverdue
                              ? 'Overdue'
                              : isDueToday
                                  ? 'Due Today'
                                  : 'Active';
                          final statusColor = isOverdue
                              ? AppTheme.danger
                              : isDueToday
                                  ? AppTheme.warning
                                  : AppTheme.success;
                          final dueStr = due != null
                              ? '${due.month}/${due.day}, 5:00 PM'
                              : '';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _LoanCard(
                              name: e['equipment_name'] ?? '',
                              id:   e['qr_code'] ?? '',
                              dueDate: dueStr,
                              statusColor: statusColor,
                              statusLabel: statusLabel,
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

class _StatCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _StatCard(
      {required this.label,
      required this.value,
      required this.icon,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: SizedBox(
        height: 94,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                  color: color.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 4))
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: color, size: 20),
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
                          fontSize: 10, color: AppTheme.textMid),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _QuickAction(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 72,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(height: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: color)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoanCard extends StatelessWidget {
  final String name, id, dueDate, statusLabel;
  final Color statusColor;
  const _LoanCard(
      {required this.name,
      required this.id,
      required this.dueDate,
      required this.statusLabel,
      required this.statusColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.primary.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.science_outlined,
                color: AppTheme.primary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: AppTheme.textDark)),
                const SizedBox(height: 2),
                Text(id,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textMid)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              StatusBadge(label: statusLabel, color: statusColor),
              const SizedBox(height: 4),
              Text(dueDate,
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMid)),
            ],
          ),
        ],
      ),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, body, time;
  const _NotificationCard(
      {required this.icon,
      required this.color,
      required this.title,
      required this.body,
      required this.time});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
                color: color.withOpacity(0.12), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: AppTheme.textDark)),
                const SizedBox(height: 2),
                Text(body,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textMid)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(time,
              style: const TextStyle(fontSize: 11, color: AppTheme.textLight)),
        ],
      ),
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
  final _categories = ['Electronics', 'Optics', 'Measurement', 'Tools', 'Microcontroller'];
  bool _dropdownOpen = false;
  bool _loading = true;
  bool _hasError = false;
  List<dynamic> _items = [];

  @override
  void initState() {
    super.initState();
    _loadEquipment();
  }

  Future<void> _loadEquipment() async {
    setState(() { _loading = true; _hasError = false; });
    try {
      final data = await ApiService.getEquipment();
      setState(() { _items = data; _loading = false; });
    } catch (e) {
      setState(() { _loading = false; _hasError = true; });
    }
  }

  // Returns an icon based on equipment category
  IconData _equipmentIcon(String category) {
    switch (category.toLowerCase()) {
      case 'electronics':     return Icons.electric_bolt_rounded;
      case 'tools':           return Icons.build_rounded;
      case 'measurement':     return Icons.straighten_rounded;
      case 'optics':          return Icons.remove_red_eye_rounded;
      case 'microcontroller': return Icons.memory_rounded;
      default:                return Icons.science_outlined;
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

  @override
  Widget build(BuildContext context) {
    final filtered = _items.where((e) {
      final matchCat = _selectedCategories.isEmpty ||
          _selectedCategories.contains(e['category']);
      final matchSearch = _search.isEmpty ||
          (e['equipment_name'] as String).toLowerCase().contains(_search.toLowerCase());
      return matchCat && matchSearch;
    }).toList();

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
                      const Text('Check your connection and make sure Laragon is running.',
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
                    fillColor: Colors.white.withOpacity(0.1),
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
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: _selectedCategories.isNotEmpty
                              ? AppTheme.accent
                              : Colors.white.withOpacity(0.2),
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
                                  color: AppTheme.accent.withOpacity(0.2),
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
                                      ? AppTheme.primary.withOpacity(0.1)
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
                              color: AppTheme.primary.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color:
                                      AppTheme.primary.withOpacity(0.3)),
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
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final e = filtered[i];
                final isAvailable = (e['status'] ?? 'Available') == 'Available';
                final category = e['category'] as String? ?? '';
                return GestureDetector(
                  onTap: isAvailable ? () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => BorrowRequestScreen(
                              equipmentName: e['equipment_name'] as String,
                              equipmentId: int.tryParse('${e['equipment_id']}') ?? 0))) : null,
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
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: (isAvailable ? AppTheme.success : AppTheme.danger).withOpacity(0.10),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(_equipmentIcon(category),
                              color: isAvailable ? AppTheme.success : AppTheme.danger,
                              size: 24),
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

// ─── Borrow Request Screen ─────────────────────────────────────────────────────

class BorrowRequestScreen extends StatefulWidget {
  final String? equipmentName;
  final int equipmentId;
  const BorrowRequestScreen({super.key, this.equipmentName, this.equipmentId = 0});
  @override
  State<BorrowRequestScreen> createState() => _BorrowRequestScreenState();
}

class _BorrowRequestScreenState extends State<BorrowRequestScreen> {
  int _qty = 1;
  bool _loading = false;
  final _nameCtrl    = TextEditingController();
  final _idCtrl      = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _purposeCtrl = TextEditingController();

  // Selected equipment — starts from widget props or empty
  int    _selectedEquipmentId   = 0;
  String _selectedEquipmentName = '';

  // Auto due date — today at 5:00 PM
  DateTime get _dueDate {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, 17, 0, 0);
  }

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = Session.name;
    _idCtrl.text   = Session.studentNumber;
    // Pre-fill if coming from catalog
    _selectedEquipmentId   = widget.equipmentId;
    _selectedEquipmentName = widget.equipmentName ?? '';
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
    List<dynamic> items = [];
    bool loading = true;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          // Load equipment on first open
          if (loading) {
            ApiService.getEquipment().then((data) {
              setSheetState(() {
                items = data.where((e) => e['status'] == 'Available').toList();
                loading = false;
              });
            }).catchError((_) => setSheetState(() => loading = false));
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
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : items.isEmpty
                        ? const Center(
                            child: Text('No available equipment.',
                                style: TextStyle(color: AppTheme.textMid)))
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: items.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final e = items[i];
                              final isSelected = _selectedEquipmentId ==
                                  int.tryParse('${e['equipment_id']}');
                              return GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedEquipmentId   = int.tryParse('${e['equipment_id']}') ?? 0;
                                    _selectedEquipmentName = e['equipment_name'] as String;
                                  });
                                  Navigator.pop(ctx);
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? AppTheme.primary.withOpacity(0.07)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                        color: isSelected
                                            ? AppTheme.primary
                                            : AppTheme.divider),
                                  ),
                                  child: Row(children: [
                                    Container(
                                      width: 40, height: 40,
                                      decoration: BoxDecoration(
                                          color: AppTheme.success.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(10)),
                                      child: const Icon(Icons.science_outlined,
                                          color: AppTheme.success, size: 20),
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
        },
      ),
    );
  }

  Future<void> _submitRequest() async {
    if (_selectedEquipmentId == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an equipment first.'),
            backgroundColor: AppTheme.danger));
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ApiService.borrowEquipment({
        'student_id':     Session.studentId,
        'equipment_id':   _selectedEquipmentId,
        'borrower_name':  _nameCtrl.text.trim(),
        'student_number': _idCtrl.text.trim(),
        'subject':        _subjectCtrl.text.trim(),
        'quantity':       _qty,
        'borrow_date':    DateTime.now().toIso8601String(),
        'due_date':       _dueDate.toIso8601String(),
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
        // Show full error in dialog so it can be read completely
        showDialog(context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            icon: const Icon(Icons.error_outline_rounded, color: AppTheme.danger, size: 48),
            title: const Text('Submission Failed'),
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
        SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: AppTheme.danger,
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
                    color: _selectedEquipmentId == 0
                        ? AppTheme.accent.withOpacity(0.06)
                        : AppTheme.success.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: _selectedEquipmentId == 0
                            ? AppTheme.accent.withOpacity(0.3)
                            : AppTheme.success.withOpacity(0.3))),
                child: Row(
                  children: [
                    Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(
                          color: (_selectedEquipmentId == 0
                                  ? AppTheme.accent
                                  : AppTheme.success)
                              .withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12)),
                      child: Icon(
                          _selectedEquipmentId == 0
                              ? Icons.add_circle_outline_rounded
                              : Icons.science_outlined,
                          color: _selectedEquipmentId == 0
                              ? AppTheme.accent
                              : AppTheme.success),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedEquipmentId == 0
                                ? 'Tap to Select Equipment'
                                : _selectedEquipmentName,
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: _selectedEquipmentId == 0
                                    ? AppTheme.accent
                                    : AppTheme.textDark),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _selectedEquipmentId == 0
                                ? 'Required — choose from available equipment'
                                : 'Tap to change selection',
                            style: const TextStyle(
                                fontSize: 12, color: AppTheme.textMid),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: _selectedEquipmentId == 0
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
            TextField(controller: _nameCtrl, decoration: const InputDecoration(hintText: 'Juan Santos')),
            const SizedBox(height: 16),
            _FieldLabel('Student ID'),
            const SizedBox(height: 8),
            TextField(controller: _idCtrl, decoration: const InputDecoration(hintText: '2024-00123')),
            const SizedBox(height: 16),
            _FieldLabel('Subject / Section'),
            const SizedBox(height: 8),
            TextField(controller: _subjectCtrl, decoration: const InputDecoration(hintText: 'PHYS101 - Sec A')),
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
            // Due time info — auto set to 5:00 PM today
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.warning.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.access_time_rounded, color: AppTheme.warning, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Return Deadline',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.warning)),
                    SizedBox(height: 2),
                    Text('All equipment must be returned today before 5:00 PM.',
                        style: TextStyle(fontSize: 12, color: AppTheme.textDark)),
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
            const SizedBox(height: 28),
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

  void _showReturnSheet(Map<String, dynamic> equipment) {
    final status      = equipment['status'] ?? 'Unknown';
    final isBorrowed  = status == 'Borrowed';
    final equipName   = equipment['equipment_name'] ?? '';
    final equipId     = int.tryParse('${equipment['equipment_id']}') ?? 0;

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
                color: (isBorrowed ? AppTheme.warning : AppTheme.success).withOpacity(0.12),
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
            const Text('Confirm that the student has returned this equipment.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.textMid)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  Navigator.pop(context); // close sheet
                  try {
                    await ApiService.returnEquipment(equipId, 'Good');
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('✅ "$equipName" marked as returned!'),
                      backgroundColor: AppTheme.success,
                      behavior: SnackBarBehavior.floating,
                    ));
                    setState(() => _scanning = true);
                  } catch (_) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Failed to update. Check connection.'),
                      backgroundColor: AppTheme.danger,
                      behavior: SnackBarBehavior.floating,
                    ));
                  }
                },
                icon: const Icon(Icons.assignment_return_rounded),
                label: const Text('Confirm Return'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: AppTheme.success.withOpacity(0.08),
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
    canvas.drawPath(path, Paint()..color = Colors.black.withOpacity(0.55));

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
  bool _loading = true;
  List<dynamic> _all = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getMyBorrowings(
          studentId: Session.studentId, studentNumber: Session.studentNumber);
      setState(() { _all = data; _loading = false; });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

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
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final active   = _all.where((e) => e['status'] == 'Approved').toList();
    final pending  = _all.where((e) => e['status'] == 'Pending').toList();
    final history  = _all.where((e) => e['status'] == 'Returned' || e['status'] == 'Rejected').toList();

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
            _LiveBorrowList(items: active, statusColorFn: _statusColor, onRefresh: _load),
            _LiveBorrowList(items: pending, statusColorFn: _statusColor, onRefresh: _load),
            _LiveBorrowList(items: history, statusColorFn: _statusColor, onRefresh: _load),
          ],
        ),
      ),
    );
  }
}

class _LiveBorrowList extends StatelessWidget {
  final List<dynamic> items;
  final Color Function(String) statusColorFn;
  final VoidCallback onRefresh;
  const _LiveBorrowList({required this.items, required this.statusColorFn, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.inbox_rounded, size: 48, color: AppTheme.textLight),
        const SizedBox(height: 8),
        const Text('No items', style: TextStyle(color: AppTheme.textMid)),
        const SizedBox(height: 12),
        TextButton.icon(onPressed: onRefresh, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
      ]));
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final e = items[i];
          final status = e['status'] ?? 'Pending';
          final dueDate = e['due_date'] ?? '';
          final txId = int.tryParse('${e['transaction_id']}') ?? 0;
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 46, height: 46,
                      decoration: BoxDecoration(
                          color: AppTheme.primary.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.science_outlined, color: AppTheme.primary),
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
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const DamageReportScreen())),
                        icon: const Icon(Icons.report_problem_outlined, size: 16),
                        label: const Text('Report'),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.warning,
                            side: const BorderSide(color: AppTheme.warning)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final confirm = await showDialog<bool>(context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Return Equipment'),
                              content: const Text('Confirm return of this equipment?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Return')),
                              ],
                            ));
                          if (confirm == true) {
                            try {
                              await ApiService.returnEquipment(txId, 'Good');
                              onRefresh();
                            } catch (_) {}
                          }
                        },
                        icon: const Icon(Icons.check_circle_outline_rounded, size: 16),
                        label: const Text('Return'),
                      ),
                    ),
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
  bool _loading = false;
  final _descCtrl = TextEditingController();

  @override
  void dispose() { _descCtrl.dispose(); super.dispose(); }

  Future<void> _submit() async {
    if (_descCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please describe the damage.'), backgroundColor: AppTheme.danger));
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ApiService.submitDamageReport({
        'equipment_id': int.tryParse(_selectedEquipmentId ?? '0') ?? 0,
        'student_id':   Session.studentId,
        'description':  '${_severity ?? 'Minor'}: ${_descCtrl.text.trim()}',
      });
      if (!mounted) return;
      if (res['success'] == true) {
        showDialog(context: context, barrierDismissible: false,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            icon: const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 52),
            title: const Text('Report Submitted'),
            content: const Text('Your damage report has been submitted. Lab staff will review it shortly.', textAlign: TextAlign.center),
            actions: [ElevatedButton(
              onPressed: () { Navigator.pop(context); Navigator.pop(context); },
              child: const Text('OK'))],
          ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res['message'] ?? 'Failed.'), backgroundColor: AppTheme.danger));
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot connect to server.'), backgroundColor: AppTheme.danger));
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
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: AppTheme.danger.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(16),
                  border:
                      Border.all(color: AppTheme.danger.withOpacity(0.2))),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: AppTheme.danger),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                        'Please report any damage to equipment immediately. This helps us maintain quality for all students.',
                        style: TextStyle(
                            fontSize: 13, color: AppTheme.textDark)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _FieldLabel('Equipment'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.divider)),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  hint: const Text('Select equipment',
                      style: TextStyle(color: AppTheme.textLight)),
                  items: ['Digital Multimeter (EQ-0042)', 'Oscilloscope (EQ-0018)']
                      .map((e) =>
                          DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (_) {},
                ),
              ),
            ),
            const SizedBox(height: 16),
            _FieldLabel('Severity'),
            const SizedBox(height: 8),
            Row(
              children: ['Minor', 'Moderate', 'Severe'].map((s) {
                final colors = {
                  'Minor': AppTheme.success,
                  'Moderate': AppTheme.warning,
                  'Severe': AppTheme.danger
                };
                final c = colors[s]!;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _severity = s),
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: _severity == s
                            ? c.withOpacity(0.15)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: _severity == s ? c : AppTheme.divider,
                            width: _severity == s ? 2 : 1),
                      ),
                      child: Center(
                          child: Text(s,
                              style: TextStyle(
                                  color: _severity == s ? c : AppTheme.textMid,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13))),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            _FieldLabel('Description of Damage'),
            const SizedBox(height: 8),
            TextField(
              maxLines: 4,
              decoration: const InputDecoration(
                  hintText: 'Describe the damage in detail...'),
            ),
            const SizedBox(height: 16),
            _FieldLabel('Photo Evidence (Optional)'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {},
              child: Container(
                height: 100,
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: AppTheme.divider, style: BorderStyle.solid)),
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_photo_alternate_outlined,
                          color: AppTheme.textLight, size: 32),
                      SizedBox(height: 6),
                      Text('Tap to add photos',
                          style: TextStyle(
                              color: AppTheme.textLight, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _submit,
                icon: _loading
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.send_rounded),
                label: const Text('Submit Report'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              ),
            ),
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
                      backgroundColor: AppTheme.accent.withOpacity(0.2),
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
                      '${Session.studentNumber}  •  ${Session.currentUser?['course'] ?? 'CEA'}',
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
  late TextEditingController _courseCtrl;
  late TextEditingController _yearCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl   = TextEditingController(text: Session.name);
    _courseCtrl = TextEditingController(text: Session.currentUser?['course'] ?? '');
    _yearCtrl   = TextEditingController(text: '${Session.currentUser?['year_level'] ?? ''}');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _courseCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name      = _nameCtrl.text.trim();
    final course    = _courseCtrl.text.trim();
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
                    backgroundColor: AppTheme.accent.withOpacity(0.15),
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
            TextField(
              controller: _courseCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                  hintText: 'e.g. BSECE',
                  prefixIcon: Icon(Icons.school_outlined, color: AppTheme.textMid)),
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
                  color: AppTheme.primary.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.primary.withOpacity(0.15))),
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
              hint: '••••••••',
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
  bool _borrowApproved  = true;
  bool _borrowRejected  = true;
  bool _dueSoon         = true;
  bool _overdue         = true;
  bool _returnConfirmed = true;
  bool _damageUpdate    = false;

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
        activeColor: activeColor ?? AppTheme.primary,
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
                onPressed: () {
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
                    color: Colors.white.withOpacity(0.15),
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
              separatorBuilder: (_, __) => const SizedBox(height: 8),
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
                          color: isOpen ? AppTheme.primary.withOpacity(0.3) : AppTheme.divider),
                      boxShadow: isOpen ? [
                        BoxShadow(color: AppTheme.primary.withOpacity(0.08),
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
              color: AppTheme.primary.withOpacity(0.08),
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
          if (Session.isDemoMode)
            Container(
              width: double.infinity,
              color: AppTheme.accent,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.play_circle_outline_rounded, color: Colors.white, size: 14),
                SizedBox(width: 6),
                Text('DEMO MODE — Data is not saved to the database',
                    style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ]),
            ),
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
      final stats    = await ApiService.getDashboardStats();
      final requests = await ApiService.getRequests();
      setState(() {
        _stats    = stats;
        _pending  = requests.where((e) => e['status'] == 'Pending').toList();
        _approved = requests.where((e) => e['status'] == 'Approved').toList();
        _loading  = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _approve(int txId) async {
    try {
      await ApiService.updateRequestStatus(txId, 'approve');
      _load();
    } catch (_) {}
  }

  Future<void> _reject(int txId) async {
    try {
      await ApiService.updateRequestStatus(txId, 'reject');
      _load();
    } catch (_) {}
  }

  Future<void> _return(int txId, String equipmentName) async {
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
              expandedHeight: 160,
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
                  padding: const EdgeInsets.fromLTRB(24, 60, 24, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                              color: AppTheme.accent.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(8)),
                          child: const Text('ADMIN',
                              style: TextStyle(color: AppTheme.accent, fontSize: 11,
                                  fontWeight: FontWeight.bold, letterSpacing: 1)),
                        ),
                        const SizedBox(width: 10),
                        Text(Session.name,
                            style: const TextStyle(color: Colors.white, fontSize: 20,
                                fontWeight: FontWeight.bold)),
                      ]),
                      const SizedBox(height: 4),
                      const Text('CEA Laboratory · New Era University',
                          style: TextStyle(color: AppTheme.textLight, fontSize: 12)),
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
                      const SizedBox(height: 24),

                      // ── Scan QR for Return ──
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
                          final txId = int.tryParse('${e['transaction_id']}') ?? 0;
                          final name = e['borrower_name'] ?? e['student_number'] ?? 'Student';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: AppTheme.accent.withOpacity(0.2))),
                              child: Column(children: [
                                Row(children: [
                                  CircleAvatar(
                                    radius: 18,
                                    backgroundColor: AppTheme.accent.withOpacity(0.1),
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
                          final txId = int.tryParse('${e['transaction_id']}') ?? 0;
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
                                  border: Border.all(color: AppTheme.success.withOpacity(0.2))),
                              child: Column(children: [
                                Row(children: [
                                  Container(
                                    width: 40, height: 40,
                                    decoration: BoxDecoration(
                                        color: AppTheme.success.withOpacity(0.1),
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
              color: color.withOpacity(0.1),
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
                color: color.withOpacity(0.12),
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

class _AdminRequestCard extends StatelessWidget {
  final String student, studentId, item, dueDate;
  const _AdminRequestCard(
      {required this.student,
      required this.studentId,
      required this.item,
      required this.dueDate});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppTheme.accent.withOpacity(0.1),
                child: Text(student[0],
                    style: const TextStyle(
                        color: AppTheme.accent,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(student,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: AppTheme.textDark)),
                    Text('$studentId  •  $item  •  Due $dueDate',
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textMid)),
                  ],
                ),
              ),
              StatusBadge(label: 'Pending', color: AppTheme.accent),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: AppTheme.divider, height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Deny'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                      side: const BorderSide(color: AppTheme.danger)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Approve'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.success),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OverdueCard extends StatelessWidget {
  final String student, item;
  final int overdueDays;
  const _OverdueCard(
      {required this.student,
      required this.item,
      required this.overdueDays});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.danger.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.danger.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.access_time_filled_rounded,
              color: AppTheme.danger, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(student,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: AppTheme.textDark)),
                Text('$item  •  $overdueDays day${overdueDays > 1 ? 's' : ''} overdue',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textMid)),
              ],
            ),
          ),
          TextButton(
              onPressed: () {},
              child: const Text('Notify',
                  style: TextStyle(
                      color: AppTheme.danger,
                      fontWeight: FontWeight.bold))),
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
  bool _loading = true;
  List<dynamic> _all = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getRequests();
      setState(() { _all = data; _loading = false; });
    } catch (_) { setState(() => _loading = false); }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'Pending':  return AppTheme.accent;
      case 'Approved': return AppTheme.success;
      case 'Returned': return AppTheme.textMid;
      case 'Rejected': return AppTheme.danger;
      default:         return AppTheme.textMid;
    }
  }

  Future<void> _action(int txId, String action) async {
    try {
      await ApiService.updateRequestStatus(txId, action);
      _load();
    } catch (_) {}
  }

  Widget _buildCard(dynamic e, {bool showActions = false}) {
    final status = e['status'] ?? '';
    final sc = _statusColor(status);
    final txId = int.tryParse('${e['transaction_id']}') ?? 0;
    final studentName = e['borrower_name'] ?? e['student_number'] ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: sc.withOpacity(0.25))),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 20, backgroundColor: sc.withOpacity(0.12),
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
          if (showActions && status == 'Pending') ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: () => _action(txId, 'reject'),
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final pending  = _all.where((e) => e['status'] == 'Pending').toList();
    final approved = _all.where((e) => e['status'] == 'Approved').toList();

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
          RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(16),
            children: pending.isEmpty
                ? [const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('No pending requests', style: TextStyle(color: AppTheme.textMid))))]
                : pending.map((e) => _buildCard(e, showActions: true)).toList())),
          RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(16),
            children: approved.isEmpty
                ? [const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('No approved requests', style: TextStyle(color: AppTheme.textMid))))]
                : approved.map((e) => _buildCard(e)).toList())),
          RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(16),
            children: _all.isEmpty
                ? [const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('No requests yet', style: TextStyle(color: AppTheme.textMid))))]
                : _all.map((e) => _buildCard(e)).toList())),
        ]),
      ),
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
  String _filter = 'All';
  final _categories = ['All', 'Electronics', 'Optics', 'Measurement', 'Tools', 'Microcontroller'];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _hasError = false; });
    try {
      final data = await ApiService.getEquipment();
      setState(() { _equipment = data; _loading = false; });
    } catch (_) { setState(() { _loading = false; _hasError = true; }); }
  }

  Color _conditionColor(String c) {
    switch (c) {
      case 'Available': return AppTheme.success;
      case 'Borrowed':  return AppTheme.warning;
      default:          return AppTheme.textMid;
    }
  }

  IconData _equipmentIcon(String category) {
    switch (category.toLowerCase()) {
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
            const Text('Check your connection and make sure Laragon is running.',
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

    final totalItems     = _equipment.length;
    final availableItems = _equipment.where((e) => e['status'] == 'Available').length;
    final unavailableItems = totalItems - availableItems;

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
                    fillColor: Colors.white.withOpacity(0.1),
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
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final c = _categories[i];
                      final sel = _filter == c;
                      return GestureDetector(
                        onTap: () => setState(() => _filter = c),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: sel ? AppTheme.accent : Colors.white.withOpacity(0.1),
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
            child: filtered.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.inventory_2_outlined, size: 52, color: AppTheme.textLight),
                        SizedBox(height: 12),
                        Text('No equipment found', style: TextStyle(color: AppTheme.textMid, fontSize: 14)),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final e = filtered[i];
                      final status = e['status'] ?? 'Available';
                      final condColor = _conditionColor(status);

                      return GestureDetector(
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => EquipmentDetailScreen(equipment: {
                                  'name': e['equipment_name'],
                                  'id':   e['qr_code'],
                                  'cat':  e['category'],
                                  'status': e['status'],
                                  'location': e['location'] ?? '',
                                  'qty': 1,
                                  'available': status == 'Available' ? 1 : 0,
                                  'condition': status,
                                }))),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border(left: BorderSide(color: condColor, width: 4)),
                          ),
                          child: Row(
                            children: [
                              // Icon box
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                    color: condColor.withOpacity(0.10),
                                    borderRadius: BorderRadius.circular(12)),
                                child: Icon(_equipmentIcon(e['category'] as String? ?? ''),
                                    color: condColor, size: 24),
                              ),
                              const SizedBox(width: 14),
                              // Info
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
                                    Row(
                                      children: [
                                        // Availability bar
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              StatusBadge(label: status, color: condColor),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        StatusBadge(label: e['category'] as String, color: AppTheme.primary),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.chevron_right_rounded, color: AppTheme.textLight),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final result = await Navigator.push<Map<String, dynamic>>(
              context,
              MaterialPageRoute(builder: (_) => const EquipmentRegistrationScreen()));
          if (result != null) {
            _load(); // reload from API
            ScaffoldMessenger.of(context).showSnackBar(
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
          color: Colors.white.withOpacity(0.1),
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

// ─── Equipment Detail Screen ───────────────────────────────────────────────────

class EquipmentDetailScreen extends StatelessWidget {
  final Map<String, dynamic> equipment;
  const EquipmentDetailScreen({super.key, required this.equipment});

  @override
  Widget build(BuildContext context) {
    final avail = equipment['available'] as int;
    final qty = equipment['qty'] as int;
    final borrowed = qty - avail;

    return Scaffold(
      appBar: AppBar(
        title: Text(equipment['id'] as String),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, color: Colors.white),
            onPressed: () {},
            tooltip: 'Edit',
          ),
        ],
      ),
      backgroundColor: AppTheme.surface,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hero card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(20)),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(Icons.science_outlined, color: Colors.white, size: 34),
                  ),
                  const SizedBox(height: 14),
                  Text(equipment['name'] as String,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 4),
                  Text('${equipment['id']}  ·  ${equipment['cat']}',
                      style: const TextStyle(color: AppTheme.textLight, fontSize: 13)),
                  const SizedBox(height: 16),
                  // Stats row
                  Row(
                    children: [
                      _DetailStat(label: 'Total', value: '$qty'),
                      _vDivider(),
                      _DetailStat(label: 'Available', value: '$avail', valueColor: AppTheme.success),
                      _vDivider(),
                      _DetailStat(label: 'Borrowed', value: '$borrowed', valueColor: AppTheme.warning),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Details card
            _SectionDivider(icon: Icons.info_outline_rounded, label: 'Equipment Details', color: AppTheme.primary),
            const SizedBox(height: 12),
            _DetailRow(label: 'Equipment ID', value: equipment['id'] as String),
            _DetailRow(label: 'Category', value: equipment['cat'] as String),
            _DetailRow(label: 'Total Quantity', value: '$qty units'),
            _DetailRow(label: 'Available', value: '$avail units'),
            _DetailRow(label: 'Condition', value: equipment['condition'] as String,
                valueColor: _condColor(equipment['condition'] as String)),
            const SizedBox(height: 20),

            // QR Code placeholder
            _SectionDivider(icon: Icons.qr_code_rounded, label: 'QR Code', color: AppTheme.primary),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(16)),
              child: Column(
                children: [
                  Container(
                    width: 140,
                    height: 140,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppTheme.divider, width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: CustomPaint(painter: _QrPlaceholderPainter()),
                  ),
                  const SizedBox(height: 12),
                  Text(equipment['id'] as String,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppTheme.textDark)),
                  const SizedBox(height: 4),
                  const Text('Scan to identify this equipment',
                      style: TextStyle(fontSize: 11, color: AppTheme.textMid)),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.share_outlined, size: 16),
                          label: const Text('Share QR'),
                          style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.primary,
                              side: const BorderSide(color: AppTheme.primary)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.print_rounded, size: 16),
                          label: const Text('Print QR'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _condColor(String c) {
    switch (c) {
      case 'Good': return AppTheme.success;
      case 'Fair': return AppTheme.warning;
      case 'Under Repair': return AppTheme.danger;
      default: return AppTheme.textMid;
    }
  }
}

Widget _vDivider() => Container(
    width: 1, height: 32, color: Colors.white24,
    margin: const EdgeInsets.symmetric(horizontal: 16));

class _DetailStat extends StatelessWidget {
  final String label, value;
  final Color valueColor;
  const _DetailStat({required this.label, required this.value, this.valueColor = Colors.white});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: TextStyle(color: valueColor, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: AppTheme.textLight, fontSize: 11)),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label, value;
  final Color? valueColor;
  const _DetailRow({required this.label, required this.value, this.valueColor});
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
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: valueColor ?? AppTheme.textDark)),
        ],
      ),
    );
  }
}

// Simple QR placeholder painter — looks like a real QR at a glance
class _QrPlaceholderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final dark = Paint()..color = const Color(0xFF1A2340);
    final s = size.width / 10;

    // Corner squares
    void corner(double x, double y) {
      canvas.drawRect(Rect.fromLTWH(x, y, s * 3, s * 3), dark);
      canvas.drawRect(Rect.fromLTWH(x + s * 0.5, y + s * 0.5, s * 2, s * 2),
          Paint()..color = Colors.white);
      canvas.drawRect(Rect.fromLTWH(x + s, y + s, s, s), dark);
    }
    corner(0, 0);
    corner(size.width - s * 3, 0);
    corner(0, size.height - s * 3);

    // Random data dots
    final positions = [
      [4,0],[5,0],[6,0],[4,1],[6,1],[4,2],[5,2],
      [0,4],[1,4],[0,5],[2,5],[0,6],[1,6],[2,6],
      [4,4],[6,4],[5,5],[4,6],[6,6],
      [7,3],[8,4],[9,4],[7,5],[9,5],[8,6],[7,7],[9,7],
      [3,7],[4,8],[6,8],[3,9],[5,9],
    ];
    for (final p in positions) {
      canvas.drawRect(
          Rect.fromLTWH(p[0] * s, p[1] * s, s * 0.85, s * 0.85), dark);
    }
  }

  @override
  bool shouldRepaint(_QrPlaceholderPainter _) => false;
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
  final _qtyCtrl = TextEditingController();

  String? _selectedCategory;
  String? _selectedCondition;
  bool _qrGenerated = false;
  String _generatedId = '';

  final _categories = ['Electronics', 'Optics', 'Measurement', 'Tools', 'Safety', 'Other'];
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

    // Generate a mock equipment ID
    final now = DateTime.now();
    final id = 'EQ-${now.millisecondsSinceEpoch % 9000 + 1000}';
    setState(() {
      _generatedId = id;
      _qrGenerated = true;
    });
  }

  Future<void> _confirmSave() async {
    showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final res = await ApiService.addEquipment({
        'equipment_name': _nameCtrl.text.trim(),
        'category':       _selectedCategory,
        'location':       _locationCtrl.text.trim(),
      });
      if (!mounted) return;
      Navigator.pop(context); // close loading
      if (res['success'] == true) {
        Navigator.pop(context, {
          'equipment_name': _nameCtrl.text.trim(),
          'qr_code':        res['qr_code'] ?? _generatedId,
          'category':       _selectedCategory,
          'status':         'Available',
          'location':       _locationCtrl.text.trim(),
        });
      } else {
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
                    color: AppTheme.primary.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.primary.withOpacity(0.15)),
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
                          color: AppTheme.success.withOpacity(0.2),
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
                          color: AppTheme.accent.withOpacity(0.15),
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
                    boxShadow: [BoxShadow(color: AppTheme.primary.withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 4))],
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
                        child: CustomPaint(painter: _QrPlaceholderPainter()),
                      ),
                      const SizedBox(height: 14),
                      Text(_generatedId,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.textDark, letterSpacing: 1.5)),
                      const SizedBox(height: 4),
                      Text(_nameCtrl.text,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMid)),
                      const SizedBox(height: 20),
                      // Action buttons
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {},
                              icon: const Icon(Icons.share_outlined, size: 16),
                              label: const Text('Share'),
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: AppTheme.primary,
                                  side: const BorderSide(color: AppTheme.primary),
                                  padding: const EdgeInsets.symmetric(vertical: 12)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {},
                              icon: const Icon(Icons.print_rounded, size: 16),
                              label: const Text('Print QR'),
                              style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 12)),
                            ),
                          ),
                        ],
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

class AdminReportsScreen extends StatelessWidget {
  const AdminReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Summary Cards
            Row(
              children: [
                _ReportCard(label: 'This Month\nBorrowings', value: '47', icon: Icons.trending_up_rounded, color: AppTheme.accent),
                const SizedBox(width: 12),
                _ReportCard(label: 'On-Time\nReturns', value: '91%', icon: Icons.check_circle_outline_rounded, color: AppTheme.success),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _ReportCard(label: 'Total\nOverdue', value: '3', icon: Icons.warning_amber_rounded, color: AppTheme.danger),
                const SizedBox(width: 12),
                _ReportCard(label: 'Damage\nReports', value: '2', icon: Icons.report_problem_outlined, color: AppTheme.warning),
              ],
            ),
            const SizedBox(height: 24),

            // Most Borrowed
            const SectionHeader(title: 'Most Borrowed Equipment'),
            const SizedBox(height: 12),
            ...[
              ('Digital Multimeter', 0.9, '18x'),
              ('Breadboard Kit', 0.72, '14x'),
              ('Oscilloscope', 0.55, '11x'),
              ('Soldering Iron Kit', 0.4, '8x'),
            ].map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.$1,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: AppTheme.textDark)),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: e.$2,
                                  minHeight: 6,
                                  backgroundColor: AppTheme.divider,
                                  valueColor: const AlwaysStoppedAnimation(AppTheme.accent),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(e.$3,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.accent)),
                      ],
                    ),
                  ),
                )),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.download_rounded),
                label: const Text('Export Full Report'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: const BorderSide(color: AppTheme.primary),
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ],
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
                  color: color.withOpacity(0.12),
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