#!/usr/bin/env node
// -----------------------------------------------------------------------------
// LabTrack — provision staff/admin accounts on the LIVE Firebase project.
//
// Why this exists: firestore.rules closes /staff/{uid} to every client
// (`allow create: if false`), so an admin account cannot be made from the app —
// by design, and the security-rule suite asserts it (S12, S36, SP01-SP11). The
// only ways in are the Firebase console by hand, or a privileged credential.
// This is the second one, so seven accounts take one pass instead of fourteen
// console forms with a UID copied between them.
//
// It needs a service-account key: Firebase console → Project settings →
// Service accounts → Generate new private key. DELETE THE KEY FILE AFTERWARDS;
// it is a full-project credential.
//
//   node scripts/create-admins.js --key ./sa.json                  # dry run
//   node scripts/create-admins.js --key ./sa.json --yes            # writes
//   node scripts/create-admins.js --key ./sa.json --yes --count 3
//   node scripts/create-admins.js --key ./sa.json --yes --password 'Shared#1234'
//
// Safe to re-run: an account that already exists keeps its UID and password,
// and only its staff document is brought back in line ("existing" in the
// summary). Nothing is ever deleted.
//
// Node needs the firebase-admin package. The QA kit already has it:
//   node scripts/create-admins.js --key ./sa.json \
//        --modules ../../qa-2026-09-19/kit/node_modules
// -----------------------------------------------------------------------------

const fs   = require('fs');
const path = require('path');
const crypto = require('crypto');

// ─── Arguments ───────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const flag = (name, fallback = null) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : fallback;
};
const has = (name) => argv.includes('--' + name);

const KEY      = flag('key');
const MODULES  = flag('modules');
const COUNT    = parseInt(flag('count', '7'), 10);
const DOMAIN   = flag('domain', 'neu.edu.ph');
const PREFIX   = flag('prefix', 'admin');
const ROLE     = flag('role', 'admin');
const FIXED_PW = flag('password');
const APPLY    = has('yes');
const PROJECT  = flag('project', 'cea-lab-system');

// --emulator is the rehearsal: the same code against the local Firebase
// emulators, where no credential exists or is needed.
if ((!KEY && !has('emulator')) || has('help')) {
  console.log('usage: node scripts/create-admins.js --key <service-account.json> [--yes]');
  console.log('       [--count 7] [--prefix admin] [--domain neu.edu.ph] [--role admin]');
  console.log('       [--password <shared>] [--project cea-lab-system] [--modules <node_modules>]');
  console.log('       [--emulator]   rehearse against the local emulators (no key needed)');
  process.exit(KEY || has('emulator') ? 0 : 1);
}
if (!Number.isInteger(COUNT) || COUNT < 1 || COUNT > 50) {
  console.error('--count must be between 1 and 50.');
  process.exit(1);
}
if (!['superadmin', 'admin', 'staff', 'viewer'].includes(ROLE)) {
  console.error("--role must be one of: superadmin, admin, staff, viewer (firestore.rules knows no others).");
  process.exit(1);
}

// ─── firebase-admin, wherever it lives ───────────────────────────────────────
// This repo is a Flutter app and carries no node_modules of its own, so allow
// the caller to point at one (the QA kit's, usually).
function load(name) {
  const paths = [__dirname, process.cwd()];
  if (MODULES) paths.unshift(path.resolve(MODULES));
  try {
    return require(require.resolve(name, { paths }));
  } catch (e) {
    console.error(`Cannot find the "${name}" package.`);
    console.error('Install it (npm i firebase-admin) or point at an existing copy:');
    console.error('  --modules ../../qa-2026-09-19/kit/node_modules');
    process.exit(1);
  }
}

// ─── The accounts ────────────────────────────────────────────────────────────
// admin1@neu.edu.ph … adminN@neu.edu.ph, "Lab Admin 1" … "Lab Admin N".
// The display name is the only part the account holder can change later (Staff
// Profile screen); email and role are provisioned here and nowhere else.
const pw = () => crypto.randomBytes(9).toString('base64').replace(/[^A-Za-z0-9]/g, 'x') + '1!';
const accounts = Array.from({ length: COUNT }, (_, i) => ({
  email:    `${PREFIX}${i + 1}@${DOMAIN}`,
  name:     `Lab Admin ${i + 1}`,
  password: FIXED_PW || pw(),
}));

(async () => {
  const useEmulator = has('emulator');
  if (useEmulator) {
    // Rehearsal mode: same code path, local emulators, no credential at all.
    process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
    process.env.FIREBASE_AUTH_EMULATOR_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || '127.0.0.1:9099';
  }

  const { initializeApp, cert } = load('firebase-admin/app');
  const { getFirestore, FieldValue } = load('firebase-admin/firestore');
  const { getAuth } = load('firebase-admin/auth');

  let projectId = PROJECT;
  if (useEmulator) {
    initializeApp({ projectId });
  } else {
    if (!fs.existsSync(KEY)) {
      console.error(`Service-account key not found: ${KEY}`);
      process.exit(1);
    }
    const sa = JSON.parse(fs.readFileSync(KEY, 'utf8'));
    if (sa.project_id !== PROJECT) {
      // The one mistake with no undo: provisioning admins into the wrong project.
      console.error(`Key is for project "${sa.project_id}" but --project is "${PROJECT}". Refusing.`);
      process.exit(1);
    }
    projectId = sa.project_id;
    initializeApp({ credential: cert(sa), projectId });
  }

  const auth = getAuth();
  const db   = getFirestore();

  console.log(`\nProject : ${projectId}${useEmulator ? '  (LOCAL EMULATORS)' : '  (LIVE)'}`);
  console.log(`Role    : ${ROLE}`);
  console.log(`Accounts: ${accounts.map((a) => a.email).join(', ')}`);
  console.log(`Mode    : ${APPLY ? 'APPLY — this writes' : 'dry run — nothing will be written (pass --yes to apply)'}\n`);
  const rows = [];
  for (const a of accounts) {
    const row = { email: a.email, uid: '-', auth: '', doc: '', password: a.password };
    try {
      let user = null;
      try {
        user = await auth.getUserByEmail(a.email);
      } catch (e) {
        if (e.code !== 'auth/user-not-found') throw e;
      }

      if (user) {
        row.uid = user.uid;
        row.auth = 'existing';
        row.password = '(unchanged)';
      } else if (APPLY) {
        // emailVerified is set because these are provisioned addresses with no
        // mailbox behind them. An `admin` account skips the verification gate
        // anyway (api_service.dart, passesVerificationGate), but if one is ever
        // demoted to plain `staff` an unverified, undeliverable address would
        // lock it out for good.
        user = await auth.createUser({
          email: a.email, password: a.password, displayName: a.name, emailVerified: true,
        });
        row.uid = user.uid;
        row.auth = 'created';
      } else {
        row.auth = 'would create';
        row.password = '(generated on apply)';
      }

      if (APPLY && user) {
        const ref  = db.doc(`staff/${user.uid}`);
        const snap = await ref.get();
        if (!snap.exists) {
          row.doc = 'created';
          await ref.set({
            name: a.name, email: a.email, role: ROLE, created_at: FieldValue.serverTimestamp(),
          });
        } else {
          // A re-run must never undo a name the holder changed on the Staff
          // Profile screen, so `name` is left exactly as it is. Only the two
          // fields that decide authorisation and login are brought back in line.
          const cur = snap.data() || {};
          const patch = {};
          if (cur.email !== a.email) patch.email = a.email;
          if (cur.role  !== ROLE)    patch.role  = ROLE;
          if (Object.keys(patch).length) {
            await ref.update(patch);
            row.doc = 'repaired: ' + Object.keys(patch).join(', ');
          } else {
            row.doc = 'already correct';
          }
        }
      } else if (!APPLY) {
        row.doc = 'would write staff/<uid>';
      }
    } catch (e) {
      row.auth = 'FAILED';
      row.doc  = (e.message || String(e)).split('\n')[0];
    }
    rows.push(row);
  }

  // ─── Summary ───────────────────────────────────────────────────────────────
  const pad = (s, n) => (String(s) + ' '.repeat(n)).slice(0, n);
  console.log(pad('EMAIL', 26) + pad('UID', 30) + pad('AUTH', 14) + pad('STAFF DOC', 24) + 'PASSWORD');
  for (const r of rows) {
    console.log(pad(r.email, 26) + pad(r.uid, 30) + pad(r.auth, 14) + pad(r.doc, 24) + r.password);
  }

  const failed = rows.filter((r) => r.auth === 'FAILED').length;
  console.log(`\n${rows.length - failed}/${rows.length} accounts ${APPLY ? 'provisioned' : 'checked'}` +
              (failed ? ` — ${failed} FAILED` : ''));
  if (APPLY) {
    console.log('\nWrite the passwords down now — they are shown once and nowhere else.');
    console.log('Each holder can change theirs in the app: My Profile → Change Password.');
    console.log('Names can be corrected there too; email and role stay console-only.');
    if (!useEmulator) console.log('Now DELETE the service-account key file.');
  } else {
    console.log('\nNothing was written. Re-run with --yes to apply.');
  }
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
