import { AppError, reserveTrial, settleTrial } from './policy.js';
import { requireAccess } from './parent-access.js';

export class Ledger {
  constructor(db) { this.db = db; }
  ref(identity) { return this.db.collection('trialLedgers').doc(identity.ledgerID); }
  async account(identity) {
    const data = (await this.ref(identity).get()).data();
    const remaining = Math.max(0, 600 - (data?.usedSeconds ?? 0));
    return { unlimited: identity.unlimited, remainingSeconds: identity.unlimited ? null : remaining >= 15 ? remaining : 0, active: Boolean(data?.active) };
  }
  async reserve(identity, sessionID, maxSeconds) {
    const ref = this.ref(identity);
    const global = this.db.collection('operations').doc(new Date().toISOString().slice(0, 10));
    return this.db.runTransaction(async tx => {
      const [snapshot, daily] = await Promise.all([tx.get(ref), tx.get(global)]);
      await requireAccess(tx, this.db, identity, 'voice');
      const now = Date.now();
      const updated = reserveTrial(snapshot.data(), { now, sessionID, unlimited: identity.unlimited, maxSeconds });
      const sessionExpiresAt = now + Math.max(1, updated.active.reservedSeconds - 5) * 1000;
      const dailySeconds = daily.data()?.reservedSeconds ?? 0;
      const cap = Number(process.env.GLOBAL_DAILY_SECONDS ?? 7200);
      if (dailySeconds + updated.active.reservedSeconds > cap) throw new AppError('service_daily_limit', 503);
      tx.set(ref, updated, { merge: true });
      // Conservative global reservations are not refunded: bounded even if finalization fails.
      tx.set(global, { reservedSeconds: dailySeconds + updated.active.reservedSeconds }, { merge: true });
      tx.set(this.db.collection('liveSessions').doc(sessionID), {
        ledgerID:identity.ledgerID,uid:identity.uid,status:'creating',expiresAt:sessionExpiresAt,calls:0,
        createdAt:now,deleteAfter:new Date(now+30*86400000),
      });
      return {...updated.active,sessionExpiresAt};
    });
  }
  async settle(identity, sessionID, seconds) {
    const ref = this.ref(identity);
    await this.db.runTransaction(async tx => {
      const updated = settleTrial((await tx.get(ref)).data(), sessionID, seconds);
      if (updated) tx.set(ref, updated, { merge: true });
    });
  }
}
