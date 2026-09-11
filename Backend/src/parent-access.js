import { randomUUID } from 'node:crypto';
import { AppError } from './policy.js';

// Change this when the notice, purposes, recipients or beta terms change.
export const AGREEMENT_VERSION = '2026-09-11.2';
export const accessRef = (db, who) => db.collection('parentAccess').doc(who.uid);

export function consentInput(input) {
  if (input?.version !== AGREEMENT_VERSION || !['de', 'en'].includes(input.locale)
      || input.guardian !== true || input.privacyAcknowledged !== true || input.termsAccepted !== true
      || typeof input.voice !== 'boolean' || typeof input.hero !== 'boolean'
      || typeof input.adultTestOnly !== 'boolean'
      || ((input.voice || input.hero) && !input.adultTestOnly)) {
    throw new AppError('agreement_required', 403);
  }
  return { version: input.version, locale: input.locale, guardian: true,
    privacyAcknowledged: true, termsAccepted: true, voice: input.voice, hero: input.hero,
    adultTestOnly: input.adultTestOnly };
}

export function assertAccess(value, feature) {
  if (value?.status === 'deleting' || value?.status === 'deleted') throw new AppError('account_deleted', 403);
  if (value?.status !== 'active' || value.version !== AGREEMENT_VERSION
      || value.guardian !== true || value.privacyAcknowledged !== true || value.termsAccepted !== true
      || value[feature] !== true || value.adultTestOnly !== true) throw new AppError('agreement_required', 403);
}

export async function requireAccess(tx, db, who, feature) {
  const value = (await tx.get(accessRef(db, who))).data();
  assertAccess(value, feature);
  return value;
}

export function consentSummary(value) {
  const current = value?.status === 'active' && value.version === AGREEMENT_VERSION;
  return { version: value?.version ?? null, requiredVersion: AGREEMENT_VERSION, current,
    voice: current && value.voice === true, hero: current && value.hero === true,
    acceptedAt: value?.acceptedAt ?? null, updatedAt: value?.updatedAt ?? null,
    status: value?.status ?? 'missing' };
}

export async function saveConsent(db, who, input) {
  const consent = consentInput(input), ref = accessRef(db, who), now = Date.now();
  return db.runTransaction(async tx => {
    const previous = (await tx.get(ref)).data();
    if (['deleting', 'deleted'].includes(previous?.status)) throw new AppError('account_deleted', 403);
    const next = { ...consent, acceptedDocument: consent, status: 'active', acceptedAt: now, updatedAt: now,
      heroOperations: previous?.heroOperations ?? {},
      // Increment on every permission change so in-flight activation must recheck.
      revision: (previous?.revision ?? 0) + 1 };
    tx.set(ref, next);
    return consentSummary(next);
  });
}

export async function revokeAccess(db, who, { deleting = false } = {}) {
  const ref = accessRef(db, who), now = Date.now();
  return db.runTransaction(async tx => {
    const value = (await tx.get(ref)).data();
    const status = ['deleting', 'deleted'].includes(value?.status) ? value.status : (deleting ? 'deleting' : 'withdrawn');
    const next = { ...value, status,
      voice: false, hero: false, updatedAt: now, withdrawnAt: now,
      revision: (value?.revision ?? 0) + 1 };
    tx.set(ref, next);
    return next;
  });
}

export function hasPendingHero(value, now = Date.now()) {
  return Object.values(value?.heroOperations ?? {}).some(deadline => deadline > now);
}

// Admission is part of the same transaction as quota checks. Deletion first
// disables new admissions, then waits for admitted operations before succeeding.
export async function admitHero(tx, db, who) {
  const value = await requireAccess(tx, db, who, 'hero');
  const now = Date.now();
  const operations = Object.fromEntries(Object.entries(value.heroOperations ?? {}).filter(([, end]) => end > now));
  if (Object.keys(operations).length) throw new AppError('hero_busy', 429);
  return { id: randomUUID(), deadline: now + 240000, operations };
}

export async function finishHero(db, who, operation) {
  const ref = accessRef(db, who);
  await db.runTransaction(async tx => {
    const value = (await tx.get(ref)).data();
    if (!value) return;
    const operations = { ...value.heroOperations };
    delete operations[operation.id];
    tx.update(ref, { heroOperations: operations });
  });
}
