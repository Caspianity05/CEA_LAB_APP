// -----------------------------------------------------------------------------
// LabTrack - notification preferences (persisted)
//
// Extracted from firstFile.dart on 2026-08-03 as step 8 (final) of the module
// split. firstFile.dart is retired by this step.
// -----------------------------------------------------------------------------

import 'package:shared_preferences/shared_preferences.dart';

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
