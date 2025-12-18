import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";

export const DEVICE_ID_PATTERN = /^[A-Za-z0-9_-]{4,40}$/;

// No 0/O/1/I/L so the code is easy to read off the OLED screen.
const PAIRING_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";

export function sha256Hex(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

export function hashDeviceSecret(deviceId: string, secret: string): string {
  return sha256Hex(`device:${deviceId}:${secret}`);
}

export function hashPairingCode(deviceId: string, code: string): string {
  return sha256Hex(`pair:${deviceId}:${normalizePairingCode(code)}`);
}

export function normalizePairingCode(code: string): string {
  return code.toUpperCase().replace(/[^A-Z0-9]/g, "");
}

export function safeEqualHex(a: string, b: string): boolean {
  const ba = Buffer.from(a, "hex");
  const bb = Buffer.from(b, "hex");
  return ba.length === bb.length && ba.length > 0 && timingSafeEqual(ba, bb);
}

export function generateDeviceSecret(): string {
  return randomBytes(24).toString("base64url");
}

/** e.g. "K7Q2-M9XD" */
export function generatePairingCode(): string {
  let code = "";
  for (let i = 0; i < 8; i++) code += PAIRING_ALPHABET[randomInt(PAIRING_ALPHABET.length)];
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

/** Parses `Authorization: Bearer <deviceId>:<secret>`. */
export function parseDeviceAuthorization(header: unknown): { deviceId: string; secret: string } | null {
  if (typeof header !== "string") return null;
  const m = /^Bearer\s+([^:\s]+):(\S+)$/.exec(header.trim());
  if (!m || !DEVICE_ID_PATTERN.test(m[1])) return null;
  return { deviceId: m[1], secret: m[2] };
}
