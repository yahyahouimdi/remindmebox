// Dr. AI: the in-app health assistant, backed by the Gemini API.
// The API key never leaves the server; the assistant gets the user's own
// medication plan as context so it can answer "what do I take tonight?".
import { logger } from "firebase-functions";
import { defineSecret, defineString } from "firebase-functions/params";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import { db, displayName, REGION } from "./admin";
import { normalizeDoses } from "./lib/doses";

const GEMINI_API_KEY = defineSecret("GEMINI_API_KEY");
const GEMINI_MODEL = defineString("GEMINI_MODEL", { default: "gemini-flash-latest" });

const HISTORY_LENGTH = 20;
const MAX_MESSAGE_LENGTH = 2000;
const MAX_USER_MESSAGES_PER_HOUR = 30;
const DAY_NAMES = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

const SYSTEM_PROMPT = `You are "Dr. AI", the assistant inside RemindMeBox, a smart pill dispenser used by elderly people and their caregivers in Tunisia.
- Answer in the language the user writes in (Tunisian Arabic / Darija, Modern Standard Arabic, French or English).
- Be warm, short and clear: elderly users read on a phone. Prefer short paragraphs or bullet points.
- You can explain what medications are generally used for, common side effects, how to take them (with food, water, timing), what to do after a missed dose in general terms, and general wellbeing and first-aid guidance.
- You are not a doctor: never change prescribed doses, never tell someone to stop a medication, never diagnose. For anything specific, tell them to ask their doctor or pharmacist.
- If the user describes an emergency (chest pain, trouble breathing, fainting, stroke signs, overdose, severe bleeding), tell them immediately to call SAMU on 190 (or 198 for civil protection) and to press the SOS button on their RemindMeBox.
- Use the medication plan below when the user asks about their own schedule. If it is empty, say the plan has not been set up yet.`;

interface GeminiContent {
  role: "user" | "model";
  parts: { text: string }[];
}

async function medicationContext(uid: string): Promise<string> {
  const devices = await db.collection("devices").where("memberUids", "array-contains", uid).get();
  if (devices.empty) return "No RemindMeBox is linked to this account yet.";
  const sections: string[] = [];
  for (const device of devices.docs) {
    const [compartments, schedules] = await Promise.all([
      device.ref.collection("compartments").get(),
      device.ref.collection("schedules").where("enabled", "==", true).get(),
    ]);
    const meds = new Map<number, string>();
    const lines = [`Box "${device.get("name")}" for ${displayName(device.data())}:`];
    for (const c of compartments.docs) {
      const name = c.get("medicationName");
      if (!name) continue;
      meds.set(Number(c.get("index")), name);
      const notes = c.get("notes") ? ` (notes: ${c.get("notes")})` : "";
      lines.push(`- Compartment ${c.get("index")}: ${name}, ${c.get("quantity")} pills left${notes}`);
    }
    const count = Number(device.get("compartmentCount") ?? 0);
    const sorted = schedules.docs.sort((a, b) => String(a.get("time")).localeCompare(String(b.get("time"))));
    for (const s of sorted) {
      const what = normalizeDoses(s.get("doses"), count)
        .map((d) => `${d.count} × ${meds.get(d.compartment) ?? `compartment ${d.compartment}`}`)
        .join(", ");
      const days: number[] = s.get("days") ?? [];
      const when = days.length === 7 ? "every day" : days.map((d) => DAY_NAMES[d]).join(", ");
      lines.push(`- Dose at ${s.get("time")} (${when}): ${what}`);
    }
    sections.push(lines.join("\n"));
  }
  return sections.join("\n\n");
}

/** Gemini expects alternating turns starting with the user. */
function toContents(history: { role: string; text: string }[], message: string): GeminiContent[] {
  const contents: GeminiContent[] = [];
  for (const m of [...history, { role: "user", text: message }]) {
    const role = m.role === "model" ? "model" : "user";
    if (contents.length === 0 && role === "model") continue;
    const last = contents[contents.length - 1];
    if (last && last.role === role) last.parts[0].text += `\n${m.text}`;
    else contents.push({ role, parts: [{ text: m.text }] });
  }
  return contents;
}

async function callGemini(systemText: string, contents: GeminiContent[]): Promise<string> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(GEMINI_MODEL.value())}:generateContent`;
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": GEMINI_API_KEY.value() },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: systemText }] },
      contents,
      generationConfig: { temperature: 0.4, maxOutputTokens: 1024 },
    }),
    signal: AbortSignal.timeout(45000),
  });
  if (!response.ok) {
    logger.error("Gemini error", { status: response.status, body: (await response.text()).slice(0, 500) });
    throw new HttpsError("unavailable", "Dr. AI is unavailable right now. Please try again later.");
  }
  const json = (await response.json()) as {
    candidates?: { content?: { parts?: { text?: string }[] }; finishReason?: string }[];
  };
  const text = json.candidates?.[0]?.content?.parts?.map((p) => p.text ?? "").join("").trim();
  if (!text) {
    return "I'm sorry, I can't answer that. Please ask your doctor or pharmacist. In an emergency call SAMU on 190.";
  }
  return text;
}

export const chatWithAssistant = onCall(
  { region: REGION, secrets: [GEMINI_API_KEY], timeoutSeconds: 60 },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "Please sign in first.");
    const uid = request.auth.uid;
    const message = typeof request.data?.message === "string" ? request.data.message.trim() : "";
    if (!message) throw new HttpsError("invalid-argument", "Message is empty.");
    if (message.length > MAX_MESSAGE_LENGTH) throw new HttpsError("invalid-argument", "Message is too long.");

    const messages = db.collection(`users/${uid}/messages`);
    const hourAgo = Timestamp.fromMillis(Date.now() - 3600 * 1000);
    const recent = await messages.where("createdAt", ">", hourAgo).count().get();
    // Each exchange stores two messages.
    if (recent.data().count >= MAX_USER_MESSAGES_PER_HOUR * 2) {
      throw new HttpsError("resource-exhausted", "You've sent a lot of messages. Please wait a little before asking again.");
    }

    const [historySnap, context] = await Promise.all([
      messages.orderBy("createdAt", "desc").limit(HISTORY_LENGTH).get(),
      medicationContext(uid),
    ]);
    const history = historySnap.docs.reverse().map((d) => ({ role: d.get("role"), text: d.get("text") }));
    const reply = await callGemini(
      `${SYSTEM_PROMPT}\n\nToday is ${new Date().toISOString().slice(0, 10)}.\n\nMedication plan:\n${context}`,
      toContents(history, message),
    );

    // The user turn is stored with the reply so the conversation never shows an unanswered question.
    const now = Date.now();
    const batch = db.batch();
    batch.set(messages.doc(), { role: "user", text: message, createdAt: Timestamp.fromMillis(now) });
    batch.set(messages.doc(), { role: "model", text: reply, createdAt: Timestamp.fromMillis(now + 1) });
    await batch.commit();
    return { reply };
  },
);
