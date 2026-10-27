// Server-side safety net, every 5 minutes:
//  - a box that stopped reporting raises a "device offline" alert;
//  - a dose the box never confirmed before the deadline is marked missed,
//    so caregivers are warned even when the box itself is down.
import { logger } from "firebase-functions";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { DocumentSnapshot, FieldValue } from "firebase-admin/firestore";
import { addAlert, db, DEFAULT_SETTINGS, DEFAULT_TIMEZONE, displayName, REGION } from "./admin";
import { markMissedByServer } from "./dose-records";
import { normalizeDoses } from "./lib/doses";
import { addDays, isoWeekday, isValidTimeZone, parseTime, utcOffsetMinutes, zonedParts, zonedTimeToUtc } from "./lib/time";

const OFFLINE_AFTER_MS = 15 * 60 * 1000;
// Extra time for the box to upload its own report before the server decides.
const REPORT_GRACE_MS = 5 * 60 * 1000;
const LOOKBACK_MS = 36 * 3600 * 1000;

function millis(value: unknown): number | null {
  const ts = value as { toMillis?: () => number } | undefined;
  return typeof ts?.toMillis === "function" ? ts.toMillis() : null;
}

export async function checkDevice(snap: DocumentSnapshot, now: Date): Promise<void> {
  const device = snap.data();
  if (!device || typeof device.ownerUid !== "string") return;
  const ref = snap.ref;
  const tz = isValidTimeZone(device.timezone) ? device.timezone : DEFAULT_TIMEZONE;
  const delayMs = Number(device.settings?.missedDoseDelayMin ?? DEFAULT_SETTINGS.missedDoseDelayMin) * 60000;
  const count = Number(device.compartmentCount ?? 0);

  const lastSeen = millis(device.status?.lastSeen);
  if (lastSeen !== null && now.getTime() - lastSeen > OFFLINE_AFTER_MS && !device.status?.offlineAlerted) {
    await ref.update({ "status.offlineAlerted": true });
    await addAlert(ref, {
      type: "device_offline",
      severity: "warning",
      title: `Box offline: ${displayName(device)}`,
      message: `The box has not reported for ${Math.round((now.getTime() - lastSeen) / 60000)} minutes. Check its power and WiFi. It keeps dispensing on its own schedule while offline.`,
    });
  }
  const offset = utcOffsetMinutes(now, tz);
  if (device.utcOffsetMinutes !== offset) await ref.update({ utcOffsetMinutes: offset });

  const claimedAt = millis(device.claimedAt) ?? 0;
  const schedules = await ref.collection("schedules").where("enabled", "==", true).get();
  const today = zonedParts(now, tz);

  for (const schedule of schedules.docs) {
    const time = parseTime(schedule.get("time"));
    const days: number[] = schedule.get("days") ?? [];
    const doses = normalizeDoses(schedule.get("doses"), count);
    if (!time || doses.length === 0) continue;
    const createdAt = millis(schedule.get("createdAt")) ?? 0;

    // Today and yesterday, so a dose shortly before midnight is still checked after it.
    for (const offsetDays of [-1, 0]) {
      const date = addDays(today, offsetDays);
      if (!days.includes(isoWeekday(date))) continue;
      const scheduledAt = zonedTimeToUtc(date, time.hour, time.minute, tz);
      const at = scheduledAt.getTime();
      if (at + delayMs + REPORT_GRACE_MS > now.getTime()) continue;
      if (at < claimedAt || at < createdAt || at < now.getTime() - LOOKBACK_MS) continue;

      const marked = await markMissedByServer(ref, device, {
        scheduleId: schedule.id,
        date,
        time: schedule.get("time"),
        scheduledAt,
        doses,
      });
      if (marked) logger.info("Dose marked missed by server", { deviceId: ref.id, scheduleId: schedule.id, date });
    }
  }
}

export const monitorDevices = onSchedule(
  { schedule: "every 5 minutes", region: REGION, timeoutSeconds: 300 },
  async () => {
    const now = new Date();
    const devices = await db.collection("devices").where("ownerUid", "!=", null).get();
    for (const snap of devices.docs) {
      try {
        await checkDevice(snap, now);
      } catch (err) {
        logger.error("Monitor failed for device", { deviceId: snap.id, err });
      }
    }
    await db.doc("system/monitor").set({ lastRun: FieldValue.serverTimestamp(), devices: devices.size });
  },
);
