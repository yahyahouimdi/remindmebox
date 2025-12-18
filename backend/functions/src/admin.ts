import { getApps, initializeApp } from "firebase-admin/app";
import { FieldValue, getFirestore, Transaction, WriteBatch, DocumentReference } from "firebase-admin/firestore";

if (getApps().length === 0) initializeApp();

export const db = getFirestore();

export const REGION = "europe-west1";

export const DEFAULT_TIMEZONE = "Africa/Tunis";

export const DEFAULT_SETTINGS = {
  missedDoseDelayMin: 30,
  lowStockThreshold: 5,
};

export type AlertType =
  | "missed_dose"
  | "low_stock"
  | "geofence_breach"
  | "geofence_return"
  | "sos"
  | "device_error"
  | "device_offline"
  | "low_battery";

export interface AlertInput {
  type: AlertType;
  title: string;
  message: string;
  severity: "info" | "warning" | "critical";
  data?: Record<string, unknown>;
}

function alertDocument(alert: AlertInput) {
  return {
    ...alert,
    data: alert.data ?? {},
    acknowledged: false,
    acknowledgedBy: null,
    acknowledgedAt: null,
    createdAt: FieldValue.serverTimestamp(),
  };
}

// Alerts are plain documents; the `onAlertCreated` trigger pushes each one to every caregiver.

export async function addAlert(deviceRef: DocumentReference, alert: AlertInput): Promise<void> {
  await deviceRef.collection("alerts").add(alertDocument(alert));
}

export function setAlert(writer: Transaction | WriteBatch, deviceRef: DocumentReference, alert: AlertInput): void {
  // Transaction.set and WriteBatch.set share the same signature.
  (writer as WriteBatch).set(deviceRef.collection("alerts").doc(), alertDocument(alert));
}

/** Name used in notification texts: the patient's name when set, the box name otherwise. */
export function displayName(device: FirebaseFirestore.DocumentData): string {
  return (device.patientName as string) || (device.name as string) || "RemindMeBox";
}
