import { createHash, createHmac } from 'node:crypto';

export class AppError extends Error {
  constructor(code, status = 400) { super(code); this.code = code; this.status = status; }
}
export const hash = value => createHash('sha256').update(value).digest('hex');
export const TRIAL_SECONDS = 5 * 60;
export const remainingTrialSeconds = account => Math.max(0, TRIAL_SECONDS - (account?.usedSeconds ?? 0));
export function identity(auth, secret, unlimitedEmailHash) {
  const apple = auth.firebase?.identities?.['apple.com']?.[0];
  if (!apple || auth.firebase?.sign_in_provider !== 'apple.com') throw new AppError('apple_sign_in_required', 403);
  return {
    uid: auth.uid,
    ledgerID: createHmac('sha256', secret).update(`apple:${apple}`).digest('hex'),
    unlimited: auth.email_verified === true && typeof auth.email === 'string'
      && hash(auth.email.trim().toLowerCase()) === unlimitedEmailHash,
  };
}

export function reserveTrial(account, { now, sessionID, unlimited, maxSeconds = 600 }) {
  if (account?.active) throw new AppError('session_already_active', 409);
  const usedSeconds = account?.usedSeconds ?? 0;
  const seconds = unlimited ? maxSeconds : Math.min(maxSeconds, remainingTrialSeconds(account));
  if (seconds < 15) throw new AppError('trial_exhausted', 402);
  return {
    usedSeconds: usedSeconds + (unlimited ? 0 : seconds),
    active: { sessionID, reservedSeconds: seconds, unlimited, expiresAt: now + (seconds + 30) * 1000 },
  };
}
export function settleTrial(account, sessionID, seconds) {
  if (account?.active?.sessionID !== sessionID) return null;
  const active = account.active;
  // Missing final usage keeps the reservation charged. Never refund on a guessed duration.
  const billed = Number.isFinite(seconds) && seconds >= 0 ? Math.ceil(seconds) : active.reservedSeconds;
  const usedSeconds = active.unlimited ? account.usedSeconds
    : Math.max(0, account.usedSeconds - active.reservedSeconds + billed);
  return { usedSeconds, active: null };
}
