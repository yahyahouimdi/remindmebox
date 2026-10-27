// End-to-end smoke test of the backend against the Firebase Emulator Suite.
//
//   npm run e2e
//
// Plays every actor through the real HTTP surfaces (Auth REST, Firestore REST with
// security rules, callable functions, device API) and checks the resulting data.
import assert from "node:assert/strict";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { generateDeviceSecret, generatePairingCode, hashDeviceSecret, hashPairingCode } from "../src/lib/crypto";

const PROJECT = "demo-remindmebox";
const REGION = "europe-west1";
const AUTH = "http://127.0.0.1:9099";
const FIRESTORE = `http://127.0.0.1:8080/v1/projects/${PROJECT}/databases/(default)/documents`;
const FUNCTIONS = `http://127.0.0.1:5001/${PROJECT}/${REGION}`;

initializeApp({ projectId: PROJECT });
const db = getFirestore();

// After initializeApp so the shared admin module reuses this app.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { checkDevice } = require("../src/monitor") as typeof import("../src/monitor");

type Json = Record<string, unknown>;

// ---- Firestore REST value encoding ------------------------------------------
function encode(v: unknown): Json {
  if (v === null) return { nullValue: null };
  if (typeof v === "boolean") return { booleanValue: v };
  if (typeof v === "number") return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === "string") return { stringValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(encode) } };
  return { mapValue: { fields: fields(v as Json) } };
}
const fields = (o: Json) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, encode(v)]));

async function signUp(email: string): Promise<{ uid: string; token: string }> {
  const res = await fetch(`${AUTH}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: "password123", returnSecureToken: true }),
  });
  const json = (await res.json()) as Json;
  assert.equal(res.status, 200, JSON.stringify(json));
  return { uid: json.localId as string, token: json.idToken as string };
}

async function rest(method: string, path: string, token: string, body?: Json): Promise<number> {
  const res = await fetch(`${FIRESTORE}/${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify({ fields: fields(body) }) : undefined,
  });
  await res.text();
  return res.status;
}

async function callable(name: string, token: string, data: Json): Promise<{ status: number; result: Json }> {
  const res = await fetch(`${FUNCTIONS}/${name}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ data }),
  });
  const json = (await res.json()) as Json;
  return { status: res.status, result: (json.result ?? json.error) as Json };
}

async function deviceApi(method: string, path: string, auth: string, body?: Json) {
  const res = await fetch(`${FUNCTIONS}/deviceApi${path}`, {
    method,
    headers: { Authorization: `Bearer ${auth}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, json: (await res.json()) as Json };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function alertTypes(deviceId: string): Promise<string[]> {
  const snap = await db.collection(`devices/${deviceId}/alerts`).get();
  return snap.docs.map((d) => d.get("type") as string);
}

function step(name: string) {
  console.log(`✓ ${name}`);
}

async function main() {
  // 1. Factory registration of a box (what `npm run register-device` does).
  const deviceId = `RMB-E2E${Date.now() % 100000}`;
  const secret = generateDeviceSecret();
  const code = generatePairingCode();
  await db.doc(`deviceSecrets/${deviceId}`).set({
    secretHash: hashDeviceSecret(deviceId, secret),
    pairingCodeHash: hashPairingCode(deviceId, code),
    failedPairings: 0,
  });
  await db.doc(`devices/${deviceId}`).set({
    name: deviceId, patientName: "", compartmentCount: 3, ownerUid: null,
    memberUids: [], members: {}, pendingInvites: [], claimedAt: null, status: {},
  });
  const boxAuth = `${deviceId}:${secret}`;
  step("box registered");

  // 2. Bad device credentials are rejected.
  assert.equal((await deviceApi("GET", "/config", `${deviceId}:wrong`)).status, 401);
  const unclaimed = await deviceApi("GET", "/config", boxAuth);
  assert.equal(unclaimed.status, 200);
  assert.equal(unclaimed.json.claimed, false);
  step("device API authenticates boxes");

  // 3. Super User registers; profile write goes through security rules.
  const suffix = Date.now();
  const owner = await signUp(`owner${suffix}@example.com`);
  assert.equal(
    await rest("POST", `users?documentId=${owner.uid}`, owner.token, {
      name: "Amira", email: `owner${suffix}@example.com`, emailLower: `owner${suffix}@example.com`,
      role: "super", pushIds: [],
    }),
    200,
  );
  // Can't create a profile pretending to be someone else's email.
  const intruder = await signUp(`intruder${suffix}@example.com`);
  assert.equal(
    await rest("POST", `users?documentId=${intruder.uid}`, intruder.token, {
      name: "X", email: "owner@example.com", emailLower: "owner@example.com", role: "super", pushIds: [],
    }),
    403,
  );
  step("profiles created under rules");

  // 4. Claim: wrong code refused, right code accepted.
  assert.equal((await callable("claimDevice", owner.token, { deviceId, pairingCode: "AAAA-AAAA" })).status, 403);
  const claim = await callable("claimDevice", owner.token, {
    deviceId, pairingCode: code.toLowerCase(), patientName: "Grandma Fatma",
  });
  assert.equal(claim.status, 200, JSON.stringify(claim.result));
  const claimed = (await db.doc(`devices/${deviceId}`).get()).data()!;
  assert.equal(claimed.ownerUid, owner.uid);
  assert.equal((await db.collection(`devices/${deviceId}/compartments`).get()).size, 3);
  step("box claimed with pairing code");

  // 5. Owner fills compartments and creates a schedule (rules-validated writes).
  assert.equal(
    await rest("PATCH", `devices/${deviceId}/compartments/1`, owner.token, {
      index: 1, medicationName: "Paracetamol", quantity: 6, notes: "500 mg",
    }),
    200,
  );
  assert.equal(
    await rest("PATCH", `devices/${deviceId}/compartments/2`, owner.token, {
      index: 2, medicationName: "Aspirin", quantity: 20, notes: "",
    }),
    200,
  );
  // Compartment 9 does not exist on a 3-compartment box.
  assert.equal(
    await rest("PATCH", `devices/${deviceId}/compartments/9`, owner.token, {
      index: 9, medicationName: "X", quantity: 1, notes: "",
    }),
    403,
  );
  assert.equal(
    await rest("POST", `devices/${deviceId}/schedules?documentId=morning`, owner.token, {
      label: "Breakfast", time: "08:00", days: [1, 2, 3, 4, 5, 6, 7], doses: { "1": 1, "2": 1 }, enabled: true,
    }),
    200,
  );
  assert.equal(
    await rest("POST", `devices/${deviceId}/schedules?documentId=bad`, owner.token, {
      label: "", time: "25:00", days: [1], doses: { "1": 1 }, enabled: true,
    }),
    403,
  );
  step("owner configured medications and schedule");

  // 6. The box pulls its configuration.
  const config = await deviceApi("GET", "/config", boxAuth);
  assert.equal(config.json.claimed, true);
  const schedules = config.json.schedules as Json[];
  assert.equal(schedules.length, 1);
  assert.deepEqual(schedules[0].doses, [{ compartment: 1, count: 1 }, { compartment: 2, count: 1 }]);
  assert.equal(config.json.utcOffsetMinutes, 60);
  step("box received its schedule");

  // 7. The box dispenses, then the pill is taken; replaying the queue changes nothing.
  const at = Math.floor(Date.now() / 1000);
  const dose = { type: "dose", scheduleId: "morning", date: "2025-11-20", time: "08:00", doses: [{ compartment: 1, count: 1 }, { compartment: 2, count: 1 }] };
  let r = await deviceApi("POST", "/events", boxAuth, { events: [{ ...dose, status: "dispensed", at }] });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  r = await deviceApi("POST", "/events", boxAuth, {
    events: [{ ...dose, status: "taken", at: at + 60 }, { ...dose, status: "dispensed", at }],
  });
  assert.equal(r.status, 200);
  const event = (await db.doc(`devices/${deviceId}/doseEvents/morning_20251120`).get()).data()!;
  assert.equal(event.status, "taken");
  assert.equal(event.scheduledAt.toDate().toISOString(), "2025-11-20T07:00:00.000Z");
  const para = (await db.doc(`devices/${deviceId}/compartments/1`).get()).data()!;
  assert.equal(para.quantity, 5, "stock decremented exactly once");
  step("dose dispensed → taken, stock updated once");

  // 8. Crossing the low-stock threshold (5) raised an alert; a missed dose too.
  await deviceApi("POST", "/events", boxAuth, {
    events: [{ ...dose, date: "2025-11-21", status: "dispensed", at }, { ...dose, date: "2025-11-21", status: "missed", at: at + 1800 }],
  });
  await sleep(500);
  let types = await alertTypes(deviceId);
  assert.ok(types.includes("low_stock"), `alerts: ${types}`);
  assert.ok(types.includes("missed_dose"), `alerts: ${types}`);
  step("low-stock and missed-dose alerts");

  // 9. Geofence: owner sets a zone, box reports a position 2 km away.
  assert.equal(
    await rest("PATCH", `devices/${deviceId}?updateMask.fieldPaths=geofence`, owner.token, {
      geofence: { enabled: true, lat: 36.8065, lng: 10.1815, radiusM: 500 },
    }),
    200,
  );
  await deviceApi("POST", "/telemetry", boxAuth, { battery: 12, rssi: -60, firmware: "1.0.0", lat: 36.8245, lng: 10.1815 });
  types = await alertTypes(deviceId);
  assert.ok(types.includes("geofence_breach"), `alerts: ${types}`);
  assert.ok(types.includes("low_battery"), `alerts: ${types}`);
  const status = (await db.doc(`devices/${deviceId}`).get()).get("status");
  assert.equal(status.geofenceInside, false);
  step("geofence breach and low battery detected");

  // 10. SOS button.
  await deviceApi("POST", "/events", boxAuth, { events: [{ type: "sos", at, lat: 36.8245, lng: 10.1815 }] });
  assert.ok((await alertTypes(deviceId)).includes("sos"));
  step("SOS alert");

  // 11. Caregiver: invited before signing up, gets access on registration.
  const caregiverEmail = `caregiver${suffix}@example.com`;
  const invite = await callable("addCaregiver", owner.token, { deviceId, email: caregiverEmail });
  assert.equal(invite.result.status, "invited");
  const caregiver = await signUp(caregiverEmail);
  assert.equal(
    await rest("POST", `users?documentId=${caregiver.uid}`, caregiver.token, {
      name: "Sami", email: caregiverEmail, emailLower: caregiverEmail, role: "simple", pushIds: [],
    }),
    200,
  );
  for (let i = 0; i < 20; i++) {
    const members: string[] = (await db.doc(`devices/${deviceId}`).get()).get("memberUids");
    if (members.includes(caregiver.uid)) break;
    await sleep(500);
  }
  assert.equal(await rest("GET", `devices/${deviceId}`, caregiver.token), 200);
  assert.equal(
    await rest("PATCH", `devices/${deviceId}/schedules/morning?updateMask.fieldPaths=enabled`, caregiver.token, { enabled: false }),
    403,
    "caregivers can't change schedules",
  );
  assert.equal(await rest("GET", `devices/${deviceId}`, intruder.token), 403, "strangers can't read the box");
  // Caregivers can acknowledge alerts.
  const alertId = (await db.collection(`devices/${deviceId}/alerts`).limit(1).get()).docs[0].id;
  const ackPath = `devices/${deviceId}/alerts/${alertId}?updateMask.fieldPaths=acknowledged&updateMask.fieldPaths=acknowledgedBy`;
  assert.equal(await rest("PATCH", ackPath, caregiver.token, { acknowledged: true, acknowledgedBy: caregiver.uid }), 200);
  step("caregiver invitation, read access and acknowledgements");

  // 12. Server-side monitor marks an unconfirmed dose as missed when the box is silent.
  const twoHoursAgo = new Date(Date.now() - 2 * 3600 * 1000);
  const tunis = new Intl.DateTimeFormat("en-GB", { timeZone: "Africa/Tunis", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  await db.doc(`devices/${deviceId}/schedules/silent`).set({
    label: "", time: tunis.format(twoHoursAgo), days: [1, 2, 3, 4, 5, 6, 7], doses: { "2": 1 }, enabled: true,
    createdAt: Timestamp.fromMillis(Date.now() - 2 * 86400 * 1000),
  });
  await db.doc(`devices/${deviceId}`).update({
    claimedAt: Timestamp.fromMillis(Date.now() - 2 * 86400 * 1000),
    "status.lastSeen": Timestamp.fromMillis(Date.now() - 3600 * 1000),
  });
  await checkDevice(await db.doc(`devices/${deviceId}`).get(), new Date());
  const silent = await db.collection(`devices/${deviceId}/doseEvents`).where("scheduleId", "==", "silent").get();
  assert.equal(silent.size, 1);
  assert.equal(silent.docs[0].get("source"), "server");
  types = await alertTypes(deviceId);
  assert.ok(types.includes("device_offline"), `alerts: ${types}`);
  step("monitor flags offline box and unconfirmed dose");

  // 13. Release wipes the box.
  assert.equal((await callable("releaseDevice", owner.token, { deviceId })).status, 200);
  const released = (await db.doc(`devices/${deviceId}`).get()).data()!;
  assert.equal(released.ownerUid, null);
  assert.equal((await db.collection(`devices/${deviceId}/schedules`).get()).size, 0);
  step("box released");

  console.log("\nAll end-to-end checks passed.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
