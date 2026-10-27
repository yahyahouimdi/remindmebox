import { logger } from "firebase-functions";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { FieldValue } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { db, REGION } from "./admin";

/** When someone registers with an invited email, give them access to the boxes they were invited to. */
export const onUserCreated = onDocumentCreated({ document: "users/{uid}", region: REGION }, async (event) => {
  const user = event.data?.data();
  if (!user?.emailLower) return;
  const uid = event.params.uid;
  const invitations = await db.collection("invitations").where("emailLower", "==", user.emailLower).get();
  if (invitations.empty) return;

  const batch = db.batch();
  for (const inv of invitations.docs) {
    const deviceRef = db.doc(`devices/${inv.get("deviceId")}`);
    batch.update(deviceRef, {
      memberUids: FieldValue.arrayUnion(uid),
      [`members.${uid}`]: { name: user.name, email: user.email, role: "caregiver" },
      pendingInvites: FieldValue.arrayRemove(user.emailLower),
    });
    batch.delete(inv.ref);
  }
  await batch.commit();
  logger.info("Resolved invitations", { uid, count: invitations.size });
});

const STALE_PUSH_ID_ERRORS = new Set(["messaging/installation-id-not-registered", "messaging/invalid-argument"]);

/**
 * Pushes every new alert to the phones of all caregivers of the box (FCM).
 * Phones are addressed by their Firebase Installation ID, stored in `users/{uid}.pushIds`.
 */
export const onAlertCreated = onDocumentCreated(
  { document: "devices/{deviceId}/alerts/{alertId}", region: REGION },
  async (event) => {
    const alert = event.data?.data();
    if (!alert) return;
    const device = await db.doc(`devices/${event.params.deviceId}`).get();
    const memberUids: string[] = device.get("memberUids") ?? [];
    if (memberUids.length === 0) return;

    const users = await db.getAll(...memberUids.map((uid) => db.doc(`users/${uid}`)));
    const owners = new Map<string, string>();
    for (const u of users) {
      for (const id of (u.get("pushIds") as string[] | undefined) ?? []) owners.set(id, u.id);
    }
    const fids = [...owners.keys()];
    if (fids.length === 0) return;

    const critical = alert.severity === "critical";
    const response = await getMessaging().sendEachForMulticast({
      fids,
      notification: { title: alert.title, body: alert.message },
      data: {
        deviceId: event.params.deviceId,
        alertId: event.params.alertId,
        type: String(alert.type),
      },
      android: { priority: "high", notification: { sound: "default", priority: critical ? "max" : "high" } },
      apns: { payload: { aps: { sound: "default", ...(critical ? { "interruption-level": "time-sensitive" } : {}) } } },
    });

    // Forget installations of uninstalled apps so they don't pile up.
    const stale = new Map<string, string[]>();
    response.responses.forEach((r, i) => {
      if (!r.success && r.error && STALE_PUSH_ID_ERRORS.has(r.error.code)) {
        const owner = owners.get(fids[i])!;
        stale.set(owner, [...(stale.get(owner) ?? []), fids[i]]);
      }
    });
    await Promise.all(
      [...stale].map(([uid, list]) => db.doc(`users/${uid}`).update({ pushIds: FieldValue.arrayRemove(...list) })),
    );
    logger.info("Alert pushed", {
      alertId: event.params.alertId,
      sent: response.successCount,
      failed: response.failureCount,
    });
  },
);
