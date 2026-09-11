// Explicit paid-project integration, synthetic identities only. No provider API calls.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {Firestore} from '@google-cloud/firestore';
import grpc from '@grpc/grpc-js';
import {Ledger} from './ledger.js';
import {AGREEMENT_VERSION,saveConsent,revokeAccess,accessRef} from './parent-access.js';
if(process.env.ZEITHELD_RUN_LEDGER_INTEGRATION!=='1') throw Error('Explicit integration opt-in required');
const accessToken=execFileSync('gcloud',['auth','print-access-token'],{encoding:'utf8'}).trim();
const sslCreds=grpc.credentials.combineChannelCredentials(grpc.credentials.createSsl(),grpc.credentials.createFromMetadataGenerator((_,callback)=>{const data=new grpc.Metadata();data.set('authorization','Bearer '+accessToken);callback(null,data)}));
const projectId=process.env.ZEITHELD_FIREBASE_PROJECT;
if(!projectId) throw Error('Set ZEITHELD_FIREBASE_PROJECT explicitly');
const firestore=new Firestore({projectId,sslCreds}),runID=randomUUID();
// Real Firestore transactions in a synthetic namespace; never consumes the
// production trial/service ledger or modifies another test run's data.
const db={collection:name=>firestore.collection('qaIntegration').doc(runID).collection(name),
 runTransaction:work=>firestore.runTransaction(work)};
const ledger=new Ledger(db),who={uid:randomUUID(),ledgerID:'synthetic-qa-'+randomUUID(),unlimited:false};
const day=new Date().toISOString().slice(0,10);
const ids=Array.from({length:8},()=>randomUUID());
try {
 await saveConsent(db,who,{version:AGREEMENT_VERSION,locale:'en',guardian:true,privacyAcknowledged:true,
  termsAccepted:true,voice:true,hero:true,adultTestOnly:true});
 const results=await Promise.allSettled(ids.map(id=>ledger.reserve(who,id,30)));
 console.log('Admission results',results.map(r=>r.status==='fulfilled'?'admitted':(r.reason.code??r.reason.message)));
 assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 const index=results.findIndex(r=>r.status==='fulfilled'),id=ids[index];
 assert.equal((await ledger.account(who)).remainingSeconds,270);
 assert.equal((await db.collection('liveSessions').doc(id).get()).data().status,'creating');
 await Promise.all([ledger.settle(who,id,12.2),ledger.settle(who,id,12.2)]);
 assert.equal((await ledger.account(who)).remainingSeconds,287);
 assert.equal((await ledger.account(who)).active,false);
 const id2=randomUUID();ids.push(id2);
 await ledger.reserve(who,id2,600);
 assert.equal((await ledger.account(who)).remainingSeconds,0);
 await ledger.settle(who,id2,undefined);
 await assert.rejects(ledger.reserve(who,randomUUID(),30),e=>e.code==='trial_exhausted');
 await revokeAccess(db,who,{deleting:true});
 await assert.rejects(ledger.reserve(who,randomUUID(),30),e=>e.code==='account_deleted');
 console.log('PASS real Firestore: 8 simultaneous reservations admit exactly 1; atomic session record; duplicate settlement refunds once; unknown final usage cannot replenish trial.');
} finally {
 await Promise.allSettled([ledger.ref(who).delete(),accessRef(db,who).delete(),
  db.collection('operations').doc(day).delete(),...ids.map(id=>db.collection('liveSessions').doc(id).delete())]);
 await firestore.terminate();
}
