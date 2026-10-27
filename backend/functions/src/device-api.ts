// HTTPS API used by the ESP32 firmware once it is on WiFi.
//
//   Authorization: Bearer <deviceId>:<deviceSecret>
//
//   GET  /config     -> schedules, compartments and settings to run offline
//   POST /telemetry  -> heartbeat: battery, WiFi signal, GPS position
//   POST /events     -> queued dose reports, SOS presses and hardware errors
import { logger } from "firebase-functions";
import { onRequest } from "firebase-functions/v2/https";
import { DocumentData, FieldValue } from "firebase-admin/firestore";
import { addAlert, db, DEFAULT_SETTINGS, DEFAULT_TIMEZONE, displayName, REGION, setAlert } from "./admin";
import { recordDeviceDose } from "./dose-records";
import { hashDeviceSecret, parseDeviceAuthorization, safeEqualHex } from "./lib/crypto";
import { DOSE_STATUSES, DoseStatus, normalizeDoses } from "./lib/doses";
import { distanceMeters, isValidCoordinate } from "./lib/geo";
import { isValidTimeZone, parseDateKey, parseTime, utcOffsetMinutes, zonedTimeToUtc } from "./lib/time";

class BadRequest extends Error {}

const MAX_EVENTS_PER_REQUEST = 50;
const LOCATION_HISTORY_MIN_MOVE_M = 15;
const LOCATION_HISTORY_MIN_INTERVAL_MS = 10 * 60 * 1000;
const LOW_BATTERY_PERCENT = 15;
const BATTERY_RECOVERED_PERCENT = 25;
const SCHEDULE_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

async function authenticate(header: unknown): Promise<string | null> {
  const parsed = parseDeviceAuthorization(header);
  if (!parsed) return null;
  const secret = await db.doc(`deviceSecrets/${parsed.deviceId}`).get();
  const expected = secret.get("secretHash");
  if (typeof expected !== "string") return null;
  return safeEqualHex(hashDeviceSecret(parsed.deviceId, parsed.secret), expected) ? parsed.deviceId : null;
}

function timezoneOf(device: DocumentData): string {
  return isValidTimeZone(device.timezone) ? device.timezone : DEFAULT_TIMEZONE;
}

function num(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

/** Device timestamps are epoch seconds; fall back to "now" when the clock is clearly wrong. */
function eventTime(value: unknown): Date {
  const seconds = num(value);
  const now = Date.now();
  if (seconds === null) return new Date(now);
  const ms = seconds * 1000;
  const lowerBound = Date.UTC(2024, 0, 1);
  return ms < lowerBound || ms > now + 24 * 3600 * 1000 ? new Date(now) : new Date(ms);
}

async function buildConfig(deviceId: string) {
  const ref = db.doc(`devices/${deviceId}`);
  const [snap, schedules, compartments] = await Promise.all([
    ref.get(),
    ref.collection("schedules").where("enabled", "==", true).get(),
    ref.collection("compartments").get(),
  ]);
  const device = snap.data() ?? {};
  const count = Number(device.compartmentCount ?? 0);
  const claimed = typeof device.ownerUid === "string";
  const now = new Date();

  return {
    deviceId,
    claimed,
    name: device.name ?? deviceId,
    patientName: device.patientName ?? "",
    compartmentCount: count,
    serverTime: Math.floor(now.getTime() / 1000),
    utcOffsetMinutes: utcOffsetMinutes(now, timezoneOf(device)),
    missedDoseDelayMin: Number(device.settings?.missedDoseDelayMin ?? DEFAULT_SETTINGS.missedDoseDelayMin),
    schedules: !claimed
      ? []
      : schedules.docs
          .map((s) => ({
            id: s.id,
            time: s.get("time") as string,
            days: ((s.get("days") as unknown[]) ?? []).filter(
              (d): d is number => Number.isInteger(d) && (d as number) >= 1 && (d as number) <= 7,
            ),
            doses: normalizeDoses(s.get("doses"), count),
          }))
          .filter((s) => SCHEDULE_ID_PATTERN.test(s.id) && parseTime(s.time) && s.days.length && s.doses.length),
    compartments: compartments.docs
      .map((c) => ({
        index: Number(c.get("index")),
        medicationName: (c.get("medicationName") as string) ?? "",
        quantity: Number(c.get("quantity") ?? 0),
      }))
      .sort((a, b) => a.index - b.index),
  };
}

async function handleTelemetry(deviceId: string, body: Record<string, unknown>) {
  const ref = db.doc(`devices/${deviceId}`);
  const device = (await ref.get()).data() ?? {};
  const claimed = typeof device.ownerUid === "string";
  const name = displayName(device);
  const batch = db.batch();
  const update: DocumentData = {
    "status.lastSeen": FieldValue.serverTimestamp(),
    "status.offlineAlerted": false,
    utcOffsetMinutes: utcOffsetMinutes(new Date(), timezoneOf(device)),
  };

  const battery = num(body.battery);
  if (battery !== null && battery >= 0 && battery <= 100) {
    update["status.battery"] = Math.round(battery);
    if (claimed && battery <= LOW_BATTERY_PERCENT && !device.status?.lowBatteryAlerted) {
      update["status.lowBatteryAlerted"] = true;
      setAlert(batch, ref, {
        type: "low_battery",
        severity: "warning",
        title: `Low battery: ${name}`,
        message: `The box battery is at ${Math.round(battery)}%. Please plug it in so no dose is missed.`,
      });
    } else if (battery >= BATTERY_RECOVERED_PERCENT && device.status?.lowBatteryAlerted) {
      update["status.lowBatteryAlerted"] = false;
    }
  }
  const rssi = num(body.rssi);
  if (rssi !== null) update["status.wifiRssi"] = Math.round(rssi);
  if (typeof body.firmware === "string") update["status.firmware"] = body.firmware.slice(0, 20);

  // Location is only stored once the box belongs to someone.
  if (claimed && isValidCoordinate(body.lat, body.lng)) {
    const lat = body.lat as number;
    const lng = body.lng as number;
    const accuracy = num(body.accuracy);
    update.location = { lat, lng, accuracy, updatedAt: FieldValue.serverTimestamp() };

    const prev = device.location;
    const moved = prev && isValidCoordinate(prev.lat, prev.lng) ? distanceMeters(prev.lat, prev.lng, lat, lng) : Infinity;
    const prevAt = prev?.updatedAt?.toMillis?.() ?? 0;
    if (moved >= LOCATION_HISTORY_MIN_MOVE_M || Date.now() - prevAt >= LOCATION_HISTORY_MIN_INTERVAL_MS) {
      batch.set(ref.collection("locations").doc(), { lat, lng, accuracy, at: FieldValue.serverTimestamp() });
    }

    const fence = device.geofence;
    if (fence?.enabled && isValidCoordinate(fence.lat, fence.lng) && num(fence.radiusM)) {
      const distance = distanceMeters(fence.lat, fence.lng, lat, lng);
      const inside = distance <= fence.radiusM;
      const wasInside = device.status?.geofenceInside !== false;
      update["status.geofenceInside"] = inside;
      if (wasInside && !inside) {
        setAlert(batch, ref, {
          type: "geofence_breach",
          severity: "critical",
          title: `${name} left the safe zone`,
          message: `${name} is now about ${Math.round(distance)} m from the safe-zone centre (limit ${Math.round(fence.radiusM)} m).`,
          data: { lat, lng },
        });
      } else if (!wasInside && inside) {
        setAlert(batch, ref, {
          type: "geofence_return",
          severity: "info",
          title: `${name} is back in the safe zone`,
          message: `${name} returned inside the safe zone.`,
          data: { lat, lng },
        });
      }
    }
  }

  batch.update(ref, update);
  await batch.commit();
  return { ok: true };
}

async function handleEvents(deviceId: string, body: Record<string, unknown>) {
  if (!Array.isArray(body.events)) throw new BadRequest("events must be an array");
  const events = body.events.slice(0, MAX_EVENTS_PER_REQUEST) as Record<string, unknown>[];
  const ref = db.doc(`devices/${deviceId}`);
  const device = (await ref.get()).data() ?? {};
  // An unclaimed box has nobody to report to; the firmware simply drops its queue.
  if (typeof device.ownerUid !== "string") return { accepted: 0, ignored: events.length };

  const tz = timezoneOf(device);
  const name = displayName(device);
  const count = Number(device.compartmentCount ?? 0);
  let accepted = 0;

  for (const ev of events) {
    if (!ev || typeof ev !== "object") continue;
    const at = eventTime(ev.at);

    if (ev.type === "dose") {
      const date = parseDateKey(ev.date);
      const time = parseTime(ev.time);
      const status = ev.status as DoseStatus;
      if (
        typeof ev.scheduleId !== "string" ||
        !SCHEDULE_ID_PATTERN.test(ev.scheduleId) ||
        !date ||
        !time ||
        !DOSE_STATUSES.includes(status)
      ) {
        logger.warn("Ignoring malformed dose event", { deviceId, ev });
        continue;
      }
      await recordDeviceDose(
        ref,
        device,
        {
          scheduleId: ev.scheduleId,
          date,
          time: ev.time as string,
          scheduledAt: zonedTimeToUtc(date, time.hour, time.minute, tz),
          doses: normalizeDoses(ev.doses, count),
        },
        status,
        at,
        typeof ev.error === "string" ? ev.error.slice(0, 120) : undefined,
      );
      accepted++;
    } else if (ev.type === "sos") {
      const hasFix = isValidCoordinate(ev.lat, ev.lng);
      await addAlert(ref, {
        type: "sos",
        severity: "critical",
        title: `SOS from ${name}`,
        message: `${name} pressed the emergency button${hasFix ? "" : " (no GPS fix — check the last known position)"}. Call them or send help now.`,
        data: hasFix ? { lat: ev.lat, lng: ev.lng, at: at.toISOString() } : { at: at.toISOString() },
      });
      accepted++;
    } else if (ev.type === "error") {
      const message = typeof ev.message === "string" ? ev.message.slice(0, 200) : "Unknown hardware error";
      await addAlert(ref, {
        type: "device_error",
        severity: "warning",
        title: `Box problem: ${name}`,
        message,
        data: { code: typeof ev.code === "string" ? ev.code.slice(0, 40) : "unknown", at: at.toISOString() },
      });
      accepted++;
    }
  }

  await ref.update({ "status.lastSeen": FieldValue.serverTimestamp(), "status.offlineAlerted": false });
  return { accepted, ignored: events.length - accepted };
}

export const deviceApi = onRequest({ region: REGION, maxInstances: 20, timeoutSeconds: 30 }, async (req, res) => {
  const deviceId = await authenticate(req.get("authorization"));
  if (!deviceId) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  const route = `${req.method} ${req.path.replace(/\/+$/, "") || "/"}`;
  const body = req.body && typeof req.body === "object" ? (req.body as Record<string, unknown>) : {};
  try {
    switch (route) {
      case "GET /config":
        res.json(await buildConfig(deviceId));
        return;
      case "POST /telemetry":
        res.json(await handleTelemetry(deviceId, body));
        return;
      case "POST /events":
        res.json(await handleEvents(deviceId, body));
        return;
      default:
        res.status(404).json({ error: "not_found" });
    }
  } catch (err) {
    if (err instanceof BadRequest) {
      res.status(400).json({ error: err.message });
      return;
    }
    logger.error("deviceApi failure", { deviceId, route, err });
    res.status(500).json({ error: "internal" });
  }
});
