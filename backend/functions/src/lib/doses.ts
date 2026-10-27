export type DoseStatus = "dispensed" | "taken" | "missed" | "failed";
export type DoseSource = "device" | "server";

export const DOSE_STATUSES: readonly DoseStatus[] = ["dispensed", "taken", "missed", "failed"];

const FINAL_STATUSES = new Set<DoseStatus>(["taken", "missed", "failed"]);

export interface DoseLine {
  compartment: number;
  count: number;
}

export interface StoredDoseState {
  status: DoseStatus;
  source: DoseSource;
}

/**
 * Decides whether a status reported by the box replaces the stored one.
 *
 * - The server only *infers* a missed dose (box silent past the deadline), so anything
 *   the box later reports from its offline queue wins over it.
 * - Box reports can arrive out of order after an outage: a final state
 *   (taken / missed / failed) is never downgraded back to "dispensed".
 */
export function shouldApplyDeviceStatus(current: StoredDoseState | undefined, incoming: DoseStatus): boolean {
  if (!current) return true;
  if (current.source === "server") return true;
  if (current.status === incoming) return false;
  return !FINAL_STATUSES.has(current.status);
}

/** Whether a dose with this status physically left the box (and must be removed from stock). */
export function consumesStock(status: DoseStatus): boolean {
  return status === "dispensed" || status === "taken";
}

/**
 * Accepts either the Firestore form `{ "1": 2, "3": 1 }` or the device form
 * `[{ compartment: 1, count: 2 }]` and returns a clean, sorted list.
 */
export function normalizeDoses(raw: unknown, maxCompartment: number): DoseLine[] {
  const lines = new Map<number, number>();
  const add = (compartment: unknown, count: unknown) => {
    const c = Number(compartment);
    const n = Number(count);
    if (!Number.isInteger(c) || c < 1 || c > maxCompartment) return;
    if (!Number.isInteger(n) || n < 1 || n > 10) return;
    lines.set(c, (lines.get(c) ?? 0) + n);
  };
  if (Array.isArray(raw)) {
    for (const item of raw) {
      if (item && typeof item === "object") add((item as DoseLine).compartment, (item as DoseLine).count);
    }
  } else if (raw && typeof raw === "object") {
    for (const [compartment, count] of Object.entries(raw)) add(compartment, count);
  }
  return [...lines.entries()].sort((a, b) => a[0] - b[0]).map(([compartment, count]) => ({ compartment, count }));
}

/** Low-stock alerts fire once, when the quantity crosses the threshold. */
export function crossesLowStock(before: number, after: number, threshold: number): boolean {
  return before > threshold && after <= threshold;
}
