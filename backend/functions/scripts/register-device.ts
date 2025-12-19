// Registers a newly assembled box so it can talk to the backend and be claimed.
//
//   # against the local emulator
//   FIRESTORE_EMULATOR_HOST=localhost:8080 npm run register-device -- --id RMB-0001 --compartments 6 --project demo-remindmebox
//   # against production (service account with Firestore access)
//   GOOGLE_APPLICATION_CREDENTIALS=./service-account.json npm run register-device -- --id RMB-0001 --compartments 6 --project <id>
//
// Prints the secrets.h block to flash into the firmware and the pairing code to put on the label.
import { initializeApp } from "firebase-admin/app";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import {
  DEVICE_ID_PATTERN,
  generateDeviceSecret,
  generatePairingCode,
  hashDeviceSecret,
  hashPairingCode,
} from "../src/lib/crypto";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

async function main() {
  const deviceId = arg("id");
  const compartments = Number(arg("compartments") ?? 6);
  const projectId = arg("project") ?? process.env.GCLOUD_PROJECT;
  const region = arg("region") ?? "europe-west1";
  const force = process.argv.includes("--force");

  if (!deviceId || !DEVICE_ID_PATTERN.test(deviceId)) {
    throw new Error("--id is required (4-40 chars: letters, digits, - or _), e.g. --id RMB-0001");
  }
  if (!Number.isInteger(compartments) || compartments < 1 || compartments > 12) {
    throw new Error("--compartments must be between 1 and 12");
  }
  if (!projectId) throw new Error("--project is required");

  initializeApp({ projectId });
  const db = getFirestore();
  const deviceRef = db.doc(`devices/${deviceId}`);
  const existing = await deviceRef.get();
  if (existing.exists && !force) {
    throw new Error(`${deviceId} is already registered. Use --force to issue new credentials (the box must be re-flashed).`);
  }

  const secret = generateDeviceSecret();
  const pairingCode = generatePairingCode();
  const batch = db.batch();
  batch.set(db.doc(`deviceSecrets/${deviceId}`), {
    secretHash: hashDeviceSecret(deviceId, secret),
    pairingCodeHash: hashPairingCode(deviceId, pairingCode),
    failedPairings: 0,
    createdAt: FieldValue.serverTimestamp(),
  });
  if (!existing.exists) {
    batch.set(deviceRef, {
      name: deviceId,
      patientName: "",
      compartmentCount: compartments,
      ownerUid: null,
      memberUids: [],
      members: {},
      pendingInvites: [],
      claimedAt: null,
      status: { lastSeen: null, battery: null, firmware: null, offlineAlerted: false },
      registeredAt: FieldValue.serverTimestamp(),
    });
  }
  await batch.commit();

  const emulator = process.env.FIRESTORE_EMULATOR_HOST;
  const apiBase = emulator
    ? `http://<your-computer-ip>:5001/${projectId}/${region}/deviceApi`
    : `https://${region}-${projectId}.cloudfunctions.net/deviceApi`;

  console.log(`\nRegistered ${deviceId} (${compartments} compartments) in project ${projectId}.\n`);
  console.log("Pairing code (label + OLED):", pairingCode);
  console.log("\n---- firmware/remindmebox_esp32/secrets.h ----");
  console.log(`#pragma once
#define DEVICE_ID "${deviceId}"
#define DEVICE_SECRET "${secret}"
#define PAIRING_CODE "${pairingCode}"
#define API_BASE_URL "${apiBase}"
#define COMPARTMENT_COUNT ${compartments}`);
  console.log("----------------------------------------------\n");
  console.log("The secret is shown only once. Keep it out of git.");
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
