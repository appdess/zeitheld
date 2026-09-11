import { test } from 'node:test';
import assert from 'node:assert/strict';
import { identity, hash, remainingTrialSeconds, reserveTrial, settleTrial } from './policy.js';

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
