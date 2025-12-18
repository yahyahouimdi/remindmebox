// Time-zone helpers. Schedules are expressed in the box's local time ("08:00"),
// while Firestore stores instants, so every comparison goes through these.

export interface LocalDate {
  year: number;
  month: number; // 1-12
  day: number;
}

export interface ZonedParts extends LocalDate {
  hour: number;
  minute: number;
  second: number;
  /** ISO weekday: 1 = Monday ... 7 = Sunday */
  weekday: number;
}

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatterFor(timeZone: string): Intl.DateTimeFormat {
  let f = formatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
    formatters.set(timeZone, f);
  }
  return f;
}

export function isValidTimeZone(timeZone: unknown): timeZone is string {
  if (typeof timeZone !== "string" || timeZone.length === 0) return false;
  try {
    formatterFor(timeZone);
    return true;
  } catch {
    return false;
  }
}

export function zonedParts(date: Date, timeZone: string): ZonedParts {
  const parts: Record<string, number> = {};
  for (const p of formatterFor(timeZone).formatToParts(date)) {
    if (p.type !== "literal") parts[p.type] = Number(p.value);
  }
  const { year, month, day } = parts;
  return {
    year,
    month,
    day,
    hour: parts.hour,
    minute: parts.minute,
    second: parts.second,
    weekday: isoWeekday({ year, month, day }),
  };
}

/** Offset of `timeZone` from UTC at `date`, in minutes (Tunis = +60). */
export function utcOffsetMinutes(date: Date, timeZone: string): number {
  const p = zonedParts(date, timeZone);
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  const truncated = Math.floor(date.getTime() / 1000) * 1000;
  return Math.round((asUtc - truncated) / 60000);
}

/** Converts a wall-clock time in `timeZone` to the corresponding instant. */
export function zonedTimeToUtc(local: LocalDate, hour: number, minute: number, timeZone: string): Date {
  const guess = Date.UTC(local.year, local.month - 1, local.day, hour, minute);
  const firstOffset = utcOffsetMinutes(new Date(guess), timeZone);
  let instant = guess - firstOffset * 60000;
  // Around DST transitions the offset at the guessed instant can differ from the real one.
  const secondOffset = utcOffsetMinutes(new Date(instant), timeZone);
  if (secondOffset !== firstOffset) instant = guess - secondOffset * 60000;
  return new Date(instant);
}

export function isoWeekday(d: LocalDate): number {
  const js = new Date(Date.UTC(d.year, d.month - 1, d.day)).getUTCDay(); // 0 = Sunday
  return js === 0 ? 7 : js;
}

export function addDays(d: LocalDate, days: number): LocalDate {
  const t = new Date(Date.UTC(d.year, d.month - 1, d.day + days));
  return { year: t.getUTCFullYear(), month: t.getUTCMonth() + 1, day: t.getUTCDate() };
}

const pad = (n: number) => String(n).padStart(2, "0");

/** "2025-11-20" */
export function dateKey(d: LocalDate): string {
  return `${d.year}-${pad(d.month)}-${pad(d.day)}`;
}

export function parseDateKey(key: unknown): LocalDate | null {
  if (typeof key !== "string") return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(key);
  if (!m) return null;
  const d = { year: Number(m[1]), month: Number(m[2]), day: Number(m[3]) };
  if (d.month < 1 || d.month > 12 || d.day < 1 || d.day > 31) return null;
  return d;
}

/** "08:30" -> { hour: 8, minute: 30 } */
export function parseTime(value: unknown): { hour: number; minute: number } | null {
  if (typeof value !== "string") return null;
  const m = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(value);
  return m ? { hour: Number(m[1]), minute: Number(m[2]) } : null;
}

/**
 * Deterministic id for one occurrence of a schedule, shared by the firmware,
 * the server and the app so that reports for the same dose never duplicate.
 */
export function doseEventId(scheduleId: string, key: string): string {
  return `${scheduleId}_${key.replace(/-/g, "")}`;
}
