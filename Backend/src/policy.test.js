import { test } from 'node:test';
import assert from 'node:assert/strict';
import { identity, hash, remainingTrialSeconds, reserveTrial, settleTrial, hostedAccessEnabled } from './policy.js';

test('trial is tied to verified Apple identity, not Firebase UID or claimed email', () => {
  const auth = {uid:'first', email:'Tester@Example.com', email_verified:true,
    firebase:{sign_in_provider:'apple.com', identities:{'apple.com':['stable-apple-id']}}};
  const first = identity(auth, 'secret', hash('tester@example.com'));
  assert.equal(first.unlimited, true);
  assert.equal(identity({...auth, uid:'recreated'}, 'secret', '').ledgerID, first.ledgerID);
  assert.equal(identity({...auth, email_verified:false}, 'secret', hash('tester@example.com')).unlimited, false);
  assert.throws(() => identity({...auth, firebase:{sign_in_provider:'password'}}, 'secret', ''), /apple_sign_in_required/);
});
test('reservation blocks concurrent devices and refunds only final measured usage', () => {
  const first = reserveTrial(null, {now:0, sessionID:'one', unlimited:false});
  assert.equal(first.usedSeconds, 300);
  assert.throws(() => reserveTrial(first, {now:100, sessionID:'two', unlimited:false}), /session_already_active/);
  const settled = settleTrial(first, 'one', 31.2);
  assert.equal(settled.usedSeconds, 32);
  assert.equal(settleTrial(settled, 'one', 0), null);
  const next = reserveTrial(settled, {now:200, sessionID:'two', unlimited:false});
  assert.equal(next.active.reservedSeconds, 268);
  assert.equal(settleTrial(next, 'one', 0), null);
});
test('lost final usage cannot replenish a trial and less than initialization minimum is refused', () => {
  const reserved = reserveTrial(null, {now:0, sessionID:'one', unlimited:false});
  assert.equal(settleTrial(reserved, 'one', undefined).usedSeconds, 300);
  assert.throws(() => reserveTrial({usedSeconds:286}, {now:0, sessionID:'two', unlimited:false}), /trial_exhausted/);
});
test('five-minute allowance preserves consumed time and never resets an existing trial', () => {
  assert.equal(remainingTrialSeconds(null), 300);
  assert.equal(remainingTrialSeconds({usedSeconds:120}), 180);
  for (const usedSeconds of [300, 450, 600]) {
    assert.equal(remainingTrialSeconds({usedSeconds}), 0);
    assert.throws(() => reserveTrial({usedSeconds}, {now:0, sessionID:'later', unlimited:false}), /trial_exhausted/);
  }
  const last = reserveTrial({usedSeconds:285}, {now:0, sessionID:'last', unlimited:false});
  assert.equal(last.active.reservedSeconds, 15);
});
test('unlimited bypasses trial balance while preserving a session deadline', () => {
  const reserved = reserveTrial({usedSeconds:600}, {now:1000, sessionID:'one', unlimited:true});
  assert.equal(reserved.usedSeconds, 600);
  assert.equal(reserved.active.reservedSeconds, 600);
  assert.equal(settleTrial(reserved, 'one', 59).usedSeconds, 600);
});

test('support credit adds time without erasing usage or weakening reservation and cutoff', () => {
  const account = {usedSeconds: 120, grantedSeconds: 300};
  assert.equal(remainingTrialSeconds(account), 480);
  const reserved = reserveTrial(account, {now: 0, sessionID: 'credited', unlimited: false});
  assert.equal(reserved.active.reservedSeconds, 480);
  assert.equal(remainingTrialSeconds(reserved), 0);
  assert.throws(() => reserveTrial(reserved, {now: 1, sessionID: 'parallel', unlimited: false}), /session_already_active/);
  const settled = settleTrial(reserved, 'credited', 30);
  assert.equal(settled.usedSeconds, 150);
  assert.equal(remainingTrialSeconds(settled), 450);
  const last = reserveTrial(settled, {now: 2, sessionID: 'last', unlimited: false});
  const exhausted = settleTrial(last, 'last', undefined);
  assert.equal(remainingTrialSeconds(exhausted), 0);
  assert.throws(() => reserveTrial(exhausted, {now: 3, sessionID: 'again', unlimited: false}), /trial_exhausted/);
  for (const invalid of [-300, '300', Infinity, 0.5]) assert.equal(remainingTrialSeconds({grantedSeconds: invalid}), 300);
});

test('a verified private tester receives the ordinary trial without public or unlimited access', () => {
  const auth = { uid: 'tester', email: 'Tester@Example.com', email_verified: true,
    firebase: { sign_in_provider: 'apple.com', identities: { 'apple.com': ['stable-apple-id'] } } };
  const who = identity(auth, 'secret', undefined, hash('tester@example.com'));
  const config = { apiKeyConfigured: true, publicAccess: false };
  assert.equal(who.unlimited, false);
  assert.equal(who.trialTester, true);
  assert.equal(hostedAccessEnabled(who, config), true);
  assert.equal(hostedAccessEnabled(who, { ...config, apiKeyConfigured: false }), false);
  const reserved = reserveTrial(null, { now: 0, sessionID: 'trial', unlimited: who.unlimited });
  assert.equal(reserved.active.reservedSeconds, 300);
  const spent = settleTrial(reserved, 'trial', 300);
  assert.throws(() => reserveTrial(spent, { now: 301000, sessionID: 'again', unlimited: who.unlimited }), /trial_exhausted/);
  for (const changed of [{ email_verified: false }, { email: 'someone-else@example.com' }, { email: undefined }]) {
    const other = identity({ ...auth, ...changed }, 'secret', undefined, hash('tester@example.com'));
    assert.equal(other.trialTester, false);
    assert.equal(hostedAccessEnabled(other, config), false);
  }
  assert.equal(hostedAccessEnabled({ unlimited: 'true', trialTester: 'true' }, config), false);
  assert.equal(hostedAccessEnabled({ unlimited: false, trialTester: false }, { ...config, publicAccess: true }), true);
});
