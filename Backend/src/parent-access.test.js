import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AGREEMENT_VERSION, consentInput, saveConsent, revokeAccess, accessRef,
  requireAccess, hasPendingHero, finishHero } from './parent-access.js';
import { Ledger } from './ledger.js';
import { reserveHero, transcribeHero, withParserSlot } from './heroes.js';

// Transactions serialize competing requests and prohibit reads after writes,
// matching the two Firestore properties this state-transition test relies on.
class TransactionDatabase {
  rows = new Map(); queue = Promise.resolve();
  collection(collection) {
    return { doc: id => {
      const key = `${collection}/${id}`;
      return { key, get: async () => ({data: () => structuredClone(this.rows.get(key))}) };
    } };
  }
  runTransaction(work) {
    const task = this.queue.then(async () => {
      const writes = [];
      const tx = {
        get: async ref => {
          assert.equal(writes.length,0,'Firestore transactions must read before writing');
          return {data: () => structuredClone(this.rows.get(ref.key))};
        },
        set: (ref,value,options) => writes.push([ref.key,value,options?.merge]),
        update: (ref,value) => writes.push([ref.key,value,true]),
      };
      const result = await work(tx);
      for (const [key,value,merge] of writes) this.rows.set(key,structuredClone(merge ? {...this.rows.get(key),...value} : value));
      return result;
    });
    this.queue = task.catch(() => {});
    return task;
  }
}
const who = {uid:'synthetic-parent',ledgerID:'synthetic-family',unlimited:false};
const agreement = {version:AGREEMENT_VERSION,locale:'de',guardian:true,privacyAcknowledged:true,
  termsAccepted:true,voice:true,hero:true,adultTestOnly:true};
async function setup() {
  const db = new TransactionDatabase();
  await saveConsent(db,who,agreement);
  return db;
}
test('agreement requires current version, adult affirmation, notice and terms; optional purposes remain separate',()=>{
  assert.equal(consentInput({...agreement,voice:false,hero:false,adultTestOnly:false}).voice,false);
  for (const change of [{version:'old'},{guardian:false},{privacyAcknowledged:false},{termsAccepted:false},
    {voice:'yes'},{locale:'xx'},{adultTestOnly:false}]) {
    assert.throws(()=>consentInput({...agreement,...change}),e=>e.code==='agreement_required');
  }
});
test('no consent and withdrawn purpose block both voice and hero admission without charging quota',async()=>{
  const db = new TransactionDatabase(), ledger = new Ledger(db);
  await assert.rejects(ledger.reserve(who,'missing',30),e=>e.code==='agreement_required');
  await saveConsent(db,who,{...agreement,hero:false});
  await assert.rejects(reserveHero(db,who,'image'),e=>e.code==='agreement_required');
  assert.equal(db.rows.get('trialLedgers/synthetic-family'),undefined);
  await ledger.reserve(who,'allowed-voice',30);
  assert.equal((await ledger.account(who)).remainingSeconds,270);
});
test('previously authenticated delayed work is denied after deletion; consent cannot resurrect deleting/deleted account',async()=>{
  const db = await setup(), ledger = new Ledger(db);
  let finishBody;
  const body = new Promise(resolve => { finishBody=resolve; });
  const retainedIdentity = {...who};
  const pending = body.then(()=>ledger.reserve(retainedIdentity,'late-session',30));
  await revokeAccess(db,who,{deleting:true});
  finishBody();
  await assert.rejects(pending,e=>e.code==='account_deleted');
  await assert.rejects(reserveHero(db,who,'image'),e=>e.code==='account_deleted');
  await assert.rejects(saveConsent(db,who,agreement),e=>e.code==='account_deleted');
  await revokeAccess(db,who); // Withdrawal must never remove a deletion tombstone.
  await assert.rejects(saveConsent(db,who,agreement),e=>e.code==='account_deleted');
  assert.equal((await ledger.account(who)).remainingSeconds,300);
});
test('withdrawal prevents activation checks and retains in-flight hero work until cleanup',async()=>{
  const db = await setup();
  const operation = await reserveHero(db,who,'image');
  const value = await revokeAccess(db,who,{deleting:true});
  assert.equal(hasPendingHero(value),true);
  await assert.rejects(db.runTransaction(tx=>requireAccess(tx,db,who,'voice')),e=>e.code==='account_deleted');
  await finishHero(db,who,operation);
  assert.equal(hasPendingHero((await accessRef(db,who).get()).data()),false);
  assert.equal((await accessRef(db,who).get()).data().status,'deleting');
});
test('malformed media consumes admission and a repeated/exhausted upload is rejected before parsing',async()=>{
  const db = await setup(), input={language:'en',audio:Buffer.alloc(64).toString('base64')};
  await assert.rejects(transcribeHero(db,who,'synthetic-not-a-key',input),e=>e.code==='invalid_audio');
  assert.equal(db.rows.get('trialLedgers/synthetic-family').heroRecordings,1);
  await assert.rejects(transcribeHero(db,who,'synthetic-not-a-key',input),e=>e.code==='hero_cooldown');
  db.rows.set('trialLedgers/synthetic-family',{heroRecordings:10});
  await assert.rejects(transcribeHero(db,who,'synthetic-not-a-key',input),e=>e.code==='hero_trial_limit');
});
test('simultaneous admissions share account limits and native parser concurrency is bounded',async()=>{
  const db = await setup();
  const attempts=await Promise.allSettled(Array.from({length:8},()=>reserveHero(db,who,'transcription')));
  assert.equal(attempts.filter(x=>x.status==='fulfilled').length,1);
  let release; const held=new Promise(resolve=>{release=resolve;});
  const first=withParserSlot(()=>held), second=withParserSlot(()=>held);
  await assert.rejects(withParserSlot(()=>Promise.resolve()),e=>e.code==='hero_busy');
  release(); await Promise.all([first,second]);
  await withParserSlot(()=>Promise.resolve());
});
