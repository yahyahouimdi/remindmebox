import { CallableRequest, HttpsError, onCall } from "firebase-functions/v2/https";
import { DocumentData, FieldValue } from "firebase-admin/firestore";
import { db, DEFAULT_SETTINGS, DEFAULT_TIMEZONE, REGION } from "./admin";
import { DEVICE_ID_PATTERN, hashPairingCode, safeEqualHex } from "./lib/crypto";

const MAX_FAILED_PAIRINGS = 10;
const PAIRING_LOCKOUT_MS = 60 * 60 * 1000;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function requireAuth(request: CallableRequest): string {
  if (!request.auth) throw new HttpsError("unauthenticated", "Please sign in first.");
  return request.auth.uid;
}

function requireString(value: unknown, field: string, max = 80): string {
  if (typeof value !== "string" || value.trim().length === 0 || value.length > max) {
    throw new HttpsError("invalid-argument", `"${field}" is required.`);
  }
  return value.trim();
}

function optionalString(value: unknown, max = 80): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, max) : undefined;
}

async function requireOwnedDevice(uid: string, deviceId: unknown) {
  if (typeof deviceId !== "string" || !DEVICE_ID_PATTERN.test(deviceId)) {
    throw new HttpsError("invalid-argument", "Invalid device id.");
  }
  const ref = db.doc(`devices/${deviceId}`);
  const snap = await ref.get();
  if (!snap.exists || snap.get("ownerUid") !== uid) {
    throw new HttpsError("permission-denied", "Only the box owner can do this.");
  }
  return { ref, device: snap.data() as DocumentData };
}

async function userProfile(uid: string): Promise<DocumentData> {
  const snap = await db.doc(`users/${uid}`).get();
  if (!snap.exists) throw new HttpsError("failed-precondition", "Complete your profile first.");
  return snap.data() as DocumentData;
}

/**
 * A Super User takes ownership of a box with the pairing code shown on its screen
 * (and printed on its label). The box itself was registered beforehand with
 * `npm run register-device`.
 */
export const claimDevice = onCall({ region: REGION }, async (request) => {
  const uid = requireAuth(request);
  const deviceId = requireString(request.data?.deviceId, "deviceId", 40);
  const pairingCode = requireString(request.data?.pairingCode, "pairingCode", 20);
  if (!DEVICE_ID_PATTERN.test(deviceId)) throw new HttpsError("invalid-argument", "Invalid device id.");

  const profile = await userProfile(uid);
  if (profile.role !== "super") {
    throw new HttpsError("permission-denied", "Only a Super User can connect a box.");
  }

  const secretRef = db.doc(`deviceSecrets/${deviceId}`);
  const deviceRef = db.doc(`devices/${deviceId}`);
  const secret = await secretRef.get();
  if (!secret.exists) throw new HttpsError("not-found", "No box with this ID exists.");

  const lockedUntil = secret.get("pairingLockedUntil")?.toMillis?.() ?? 0;
  if (lockedUntil > Date.now()) {
    throw new HttpsError("resource-exhausted", "Too many wrong codes. Try again in an hour.");
  }
  if (!safeEqualHex(hashPairingCode(deviceId, pairingCode), secret.get("pairingCodeHash"))) {
    const failures = Number(secret.get("failedPairings") ?? 0) + 1;
    await secretRef.update({
      failedPairings: failures >= MAX_FAILED_PAIRINGS ? 0 : failures,
      ...(failures >= MAX_FAILED_PAIRINGS ? { pairingLockedUntil: new Date(Date.now() + PAIRING_LOCKOUT_MS) } : {}),
    });
    throw new HttpsError("permission-denied", "Wrong pairing code.");
  }

  const name = optionalString(request.data?.name) ?? `RemindMeBox ${deviceId.slice(-4)}`;
  const patientName = optionalString(request.data?.patientName) ?? "";

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(deviceRef);
    const device = snap.data();
    if (!device) throw new HttpsError("not-found", "No box with this ID exists.");
    if (device.ownerUid && device.ownerUid !== uid) {
      throw new HttpsError("already-exists", "This box already belongs to another account. Ask its owner to release it.");
    }
    const count = Number(device.compartmentCount ?? 0);
    const existing = await tx.get(deviceRef.collection("compartments"));
    const existingIds = new Set(existing.docs.map((d) => d.id));

    tx.update(deviceRef, {
      ownerUid: uid,
      memberUids: FieldValue.arrayUnion(uid),
      [`members.${uid}`]: { name: profile.name, email: profile.email, role: "owner" },
      name,
      patientName,
      claimedAt: device.ownerUid === uid ? device.claimedAt : FieldValue.serverTimestamp(),
      timezone: device.timezone ?? DEFAULT_TIMEZONE,
      settings: device.settings ?? DEFAULT_SETTINGS,
      geofence: device.geofence ?? { enabled: false, lat: 0, lng: 0, radiusM: 500 },
    });
    for (let i = 1; i <= count; i++) {
      if (existingIds.has(String(i))) continue;
      tx.set(deviceRef.collection("compartments").doc(String(i)), {
        index: i,
        medicationName: "",
        quantity: 0,
        notes: "",
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    tx.update(secretRef, { failedPairings: 0 });
  });

  return { deviceId };
});

/** Owner gives the box back (e.g. before handing it to another family): wipes its history. */
export const releaseDevice = onCall({ region: REGION }, async (request) => {
  const uid = requireAuth(request);
  const { ref, device } = await requireOwnedDevice(uid, request.data?.deviceId);

  for (const sub of ["schedules", "doseEvents", "alerts", "locations"]) {
    await db.recursiveDelete(ref.collection(sub));
  }
  const batch = db.batch();
  const compartments = await ref.collection("compartments").get();
  compartments.forEach((c) =>
    batch.update(c.ref, { medicationName: "", quantity: 0, notes: "", updatedAt: FieldValue.serverTimestamp() }),
  );
  const invites = await db.collection("invitations").where("deviceId", "==", ref.id).get();
  invites.forEach((inv) => batch.delete(inv.ref));
  batch.update(ref, {
    ownerUid: null,
    memberUids: [],
    members: {},
    pendingInvites: [],
    name: ref.id,
    patientName: "",
    claimedAt: null,
    location: FieldValue.delete(),
    geofence: { enabled: false, lat: 0, lng: 0, radiusM: device.geofence?.radiusM ?? 500 },
  });
  await batch.commit();
  return { ok: true };
});

/**
 * Adds a caregiver (Simple User or another Super User) to a box by email.
 * If they don't have an account yet, an invitation is kept and resolved on sign-up.
 */
export const addCaregiver = onCall({ region: REGION }, async (request) => {
  const uid = requireAuth(request);
  const { ref, device } = await requireOwnedDevice(uid, request.data?.deviceId);
  const email = requireString(request.data?.email, "email", 120).toLowerCase();
  if (!EMAIL_PATTERN.test(email)) throw new HttpsError("invalid-argument", "Invalid email address.");

  const users = await db.collection("users").where("emailLower", "==", email).limit(1).get();
  if (!users.empty) {
    const user = users.docs[0];
    if ((device.memberUids ?? []).includes(user.id)) return { status: "already_member" };
    await ref.update({
      memberUids: FieldValue.arrayUnion(user.id),
      [`members.${user.id}`]: { name: user.get("name"), email: user.get("email"), role: "caregiver" },
      pendingInvites: FieldValue.arrayRemove(email),
    });
    return { status: "added", name: user.get("name") };
  }

  await db.doc(`invitations/${ref.id}_${email}`).set({
    deviceId: ref.id,
    emailLower: email,
    invitedBy: uid,
    createdAt: FieldValue.serverTimestamp(),
  });
  await ref.update({ pendingInvites: FieldValue.arrayUnion(email) });
  return { status: "invited" };
});

/** Removes a caregiver (by uid) or cancels a pending invitation (by email). */
export const removeCaregiver = onCall({ region: REGION }, async (request) => {
  const uid = requireAuth(request);
  const { ref } = await requireOwnedDevice(uid, request.data?.deviceId);
  const memberUid = optionalString(request.data?.uid, 128);
  const email = optionalString(request.data?.email, 120)?.toLowerCase();

  if (memberUid) {
    if (memberUid === uid) throw new HttpsError("invalid-argument", "The owner can't be removed. Release the box instead.");
    await ref.update({
      memberUids: FieldValue.arrayRemove(memberUid),
      [`members.${memberUid}`]: FieldValue.delete(),
    });
  }
  if (email) {
    await db.doc(`invitations/${ref.id}_${email}`).delete();
    await ref.update({ pendingInvites: FieldValue.arrayRemove(email) });
  }
  return { ok: true };
});
