import { test } from "node:test";
import assert from "node:assert/strict";
import {
  addDays,
  dateKey,
  doseEventId,
  isoWeekday,
  parseDateKey,
  parseTime,
  utcOffsetMinutes,
  zonedParts,
  zonedTimeToUtc,
} from "../src/lib/time";
import { consumesStock, crossesLowStock, normalizeDoses, shouldApplyDeviceStatus } from "../src/lib/doses";
import { distanceMeters, isValidCoordinate } from "../src/lib/geo";
import {
  generatePairingCode,
  hashDeviceSecret,
  hashPairingCode,
  parseDeviceAuthorization,
  safeEqualHex,
} from "../src/lib/crypto";

test("Tunis is UTC+1 all year", () => {
  assert.equal(utcOffsetMinutes(new Date("2025-01-15T12:00:00Z"), "Africa/Tunis"), 60);
  assert.equal(utcOffsetMinutes(new Date("2025-07-15T12:00:00Z"), "Africa/Tunis"), 60);
});

test("zonedTimeToUtc converts box-local wall clock to an instant", () => {
  const at = zonedTimeToUtc({ year: 2025, month: 11, day: 20 }, 8, 0, "Africa/Tunis");
  assert.equal(at.toISOString(), "2025-11-20T07:00:00.000Z");
  // Paris summer time (UTC+2) and across the DST switch.
  assert.equal(zonedTimeToUtc({ year: 2025, month: 7, day: 1 }, 8, 0, "Europe/Paris").toISOString(), "2025-07-01T06:00:00.000Z");
  assert.equal(zonedTimeToUtc({ year: 2025, month: 3, day: 30 }, 12, 0, "Europe/Paris").toISOString(), "2025-03-30T10:00:00.000Z");
});

test("zonedParts gives the local date near midnight", () => {
  const p = zonedParts(new Date("2025-11-20T23:30:00Z"), "Africa/Tunis");
  assert.deepEqual([p.year, p.month, p.day, p.hour, p.minute], [2025, 11, 21, 0, 30]);
  assert.equal(p.weekday, 5); // Friday
});

test("date helpers", () => {
  assert.equal(isoWeekday({ year: 2025, month: 11, day: 23 }), 7); // Sunday
  assert.equal(dateKey(addDays({ year: 2025, month: 3, day: 1 }, -1)), "2025-02-28");
  assert.deepEqual(parseDateKey("2025-11-20"), { year: 2025, month: 11, day: 20 });
  assert.equal(parseDateKey("2025-13-01"), null);
  assert.deepEqual(parseTime("08:05"), { hour: 8, minute: 5 });
  assert.equal(parseTime("24:00"), null);
  assert.equal(doseEventId("abc", "2025-11-20"), "abc_20251120");
});

test("device reports override server inference but never regress", () => {
  assert.equal(shouldApplyDeviceStatus(undefined, "dispensed"), true);
  assert.equal(shouldApplyDeviceStatus({ status: "missed", source: "server" }, "taken"), true);
  assert.equal(shouldApplyDeviceStatus({ status: "dispensed", source: "device" }, "taken"), true);
  assert.equal(shouldApplyDeviceStatus({ status: "taken", source: "device" }, "dispensed"), false);
  assert.equal(shouldApplyDeviceStatus({ status: "taken", source: "device" }, "taken"), false);
  assert.equal(shouldApplyDeviceStatus({ status: "missed", source: "device" }, "taken"), false);
});

test("stock helpers", () => {
  assert.equal(consumesStock("dispensed"), true);
  assert.equal(consumesStock("failed"), false);
  assert.equal(crossesLowStock(6, 5, 5), true);
  assert.equal(crossesLowStock(5, 4, 5), false);
});

test("normalizeDoses accepts both formats and drops invalid lines", () => {
  assert.deepEqual(normalizeDoses({ "3": 1, "1": 2, "9": 1, "2": 0 }, 6), [
    { compartment: 1, count: 2 },
    { compartment: 3, count: 1 },
  ]);
  assert.deepEqual(normalizeDoses([{ compartment: 2, count: 1 }, { compartment: 2, count: 1 }], 6), [
    { compartment: 2, count: 2 },
  ]);
  assert.deepEqual(normalizeDoses("junk", 6), []);
});

test("geo helpers", () => {
  // Tunis centre -> Carthage is about 15 km.
  const d = distanceMeters(36.8065, 10.1815, 36.8529, 10.3233);
  assert.ok(d > 13000 && d < 15000, `got ${d}`);
  assert.equal(isValidCoordinate(0, 0), false);
  assert.equal(isValidCoordinate(36.8, 10.1), true);
  assert.equal(isValidCoordinate(91, 10), false);
});

test("device credentials", () => {
  assert.deepEqual(parseDeviceAuthorization("Bearer RMB-0001:s3cr3t"), { deviceId: "RMB-0001", secret: "s3cr3t" });
  assert.equal(parseDeviceAuthorization("Bearer bad id:x"), null);
  assert.equal(parseDeviceAuthorization(undefined), null);
  const h = hashDeviceSecret("RMB-0001", "s3cr3t");
  assert.equal(safeEqualHex(h, hashDeviceSecret("RMB-0001", "s3cr3t")), true);
  assert.equal(safeEqualHex(h, hashDeviceSecret("RMB-0001", "other")), false);
  const code = generatePairingCode();
  assert.match(code, /^[2-9A-Z]{4}-[2-9A-Z]{4}$/);
  assert.equal(hashPairingCode("RMB-0001", code.toLowerCase().replace("-", " ")), hashPairingCode("RMB-0001", code));
});
