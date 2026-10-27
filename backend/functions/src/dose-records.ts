import { DocumentData, DocumentReference, DocumentSnapshot, FieldValue, Timestamp } from "firebase-admin/firestore";
import { DEFAULT_SETTINGS, db, displayName, setAlert } from "./admin";
import { consumesStock, crossesLowStock, DoseLine, DoseStatus, shouldApplyDeviceStatus } from "./lib/doses";
import { dateKey, doseEventId, LocalDate } from "./lib/time";

export interface DoseOccurrence {
  scheduleId: string;
  date: LocalDate;
  time: string; // "HH:mm", box local time
  scheduledAt: Date;
  doses: DoseLine[];
}

function describeDoses(doses: DoseLine[], compartments: DocumentSnapshot[]): string {
  return doses
    .map((line, i) => {
      const med = (compartments[i]?.get("medicationName") as string) || `compartment ${line.compartment}`;
      return `${med} ×${line.count}`;
    })
    .join(", ");
}

function compartmentRefs(deviceRef: DocumentReference, doses: DoseLine[]) {
  return doses.map((line) => deviceRef.collection("compartments").doc(String(line.compartment)));
}

/**
 * Stores a dose status reported by the box (from its live loop or its offline queue),
 * updates the compartment stock once per dose, and raises the matching alerts.
 * Returns false when the report was stale and ignored.
 */
export async function recordDeviceDose(
  deviceRef: DocumentReference,
  device: DocumentData,
  occurrence: DoseOccurrence,
  status: DoseStatus,
  at: Date,
  error?: string,
): Promise<boolean> {
  const key = dateKey(occurrence.date);
  const eventRef = deviceRef.collection("doseEvents").doc(doseEventId(occurrence.scheduleId, key));
  const threshold = Number(device.settings?.lowStockThreshold ?? DEFAULT_SETTINGS.lowStockThreshold);
  const name = displayName(device);

  return db.runTransaction(async (tx) => {
    const current = await tx.get(eventRef);
    const cur = current.data();
    if (!shouldApplyDeviceStatus(cur && { status: cur.status, source: cur.source }, status)) return false;

    const refs = compartmentRefs(deviceRef, occurrence.doses);
    const compartments = refs.length ? await tx.getAll(...refs) : [];
    const applyStock = consumesStock(status) && !cur?.stockApplied;
    const atTs = Timestamp.fromDate(at);

    const update: DocumentData = {
      scheduleId: occurrence.scheduleId,
      date: key,
      time: occurrence.time,
      scheduledAt: Timestamp.fromDate(occurrence.scheduledAt),
      doses: occurrence.doses,
      status,
      source: "device",
      updatedAt: FieldValue.serverTimestamp(),
    };
    if (status === "dispensed") update.dispensedAt = atTs;
    if (status === "taken") {
      update.takenAt = atTs;
      if (!cur?.dispensedAt) update.dispensedAt = atTs;
    }
    if (status === "missed") update.missedAt = atTs;
    if (status === "failed") {
      update.failedAt = atTs;
      update.error = error ?? "unknown";
    }
    if (applyStock) update.stockApplied = true;
    tx.set(eventRef, update, { merge: true });

    if (applyStock) {
      compartments.forEach((snap, i) => {
        if (!snap.exists) return;
        const before = Number(snap.get("quantity") ?? 0);
        const after = Math.max(0, before - occurrence.doses[i].count);
        tx.update(snap.ref, { quantity: after, updatedAt: FieldValue.serverTimestamp() });
        if (crossesLowStock(before, after, threshold)) {
          const med = (snap.get("medicationName") as string) || `Compartment ${occurrence.doses[i].compartment}`;
          setAlert(tx, deviceRef, {
            type: "low_stock",
            severity: "warning",
            title: `Low stock: ${med}`,
            message: `Only ${after} pill(s) of ${med} left in ${name}'s box. Please refill compartment ${occurrence.doses[i].compartment}.`,
            data: { compartment: occurrence.doses[i].compartment, quantity: after },
          });
        }
      });
    }

    const what = describeDoses(occurrence.doses, compartments);
    if (status === "missed" && cur?.status !== "missed") {
      setAlert(tx, deviceRef, {
        type: "missed_dose",
        severity: "critical",
        title: `Missed dose: ${name}`,
        message: `The ${occurrence.time} dose (${what}) was dispensed but not picked up.`,
        data: { scheduleId: occurrence.scheduleId, date: key, time: occurrence.time },
      });
    }
    if (status === "failed") {
      setAlert(tx, deviceRef, {
        type: "device_error",
        severity: "critical",
        title: `Dispensing failed: ${name}`,
        message: `The box could not dispense the ${occurrence.time} dose (${what}). Please give it manually and check the box. (${update.error})`,
        data: { scheduleId: occurrence.scheduleId, date: key, time: occurrence.time },
      });
    }
    return true;
  });
}

/**
 * Called by the monitor when the box never confirmed a dose before the deadline
 * (usually because it is offline or powered off). The box can still override this
 * later with what really happened, from its offline queue.
 */
export async function markMissedByServer(
  deviceRef: DocumentReference,
  device: DocumentData,
  occurrence: DoseOccurrence,
): Promise<boolean> {
  const key = dateKey(occurrence.date);
  const eventRef = deviceRef.collection("doseEvents").doc(doseEventId(occurrence.scheduleId, key));
  const name = displayName(device);

  return db.runTransaction(async (tx) => {
    const current = await tx.get(eventRef);
    const status = current.get("status") as DoseStatus | undefined;
    if (current.exists && status !== "dispensed") return false;

    const compartments = occurrence.doses.length
      ? await tx.getAll(...compartmentRefs(deviceRef, occurrence.doses))
      : [];
    tx.set(
      eventRef,
      {
        scheduleId: occurrence.scheduleId,
        date: key,
        time: occurrence.time,
        scheduledAt: Timestamp.fromDate(occurrence.scheduledAt),
        doses: occurrence.doses,
        status: "missed",
        source: "server",
        missedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    const what = describeDoses(occurrence.doses, compartments);
    setAlert(tx, deviceRef, {
      type: "missed_dose",
      severity: "critical",
      title: `Missed dose: ${name}`,
      message: status === "dispensed"
        ? `The ${occurrence.time} dose (${what}) was dispensed but pickup was never confirmed.`
        : `The box did not confirm the ${occurrence.time} dose (${what}). It may be offline — please check on ${name}.`,
      data: { scheduleId: occurrence.scheduleId, date: key, time: occurrence.time },
    });
    return true;
  });
}
