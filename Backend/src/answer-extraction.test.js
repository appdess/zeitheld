import {test} from 'node:test';
import assert from 'node:assert/strict';
import {extractionRequest,parseExtraction,extractClockAnswer} from './answer-extraction.js';
const complete = answer => ({status:'completed',output:[{content:[{type:'output_text',text:JSON.stringify(answer)}]}]});
test('short extraction has a bounded non-reasoning budget and no target-clock answer',()=>{
  const body=extractionRequest('elf Uhr');
  assert.deepEqual(body.reasoning,{effort:'none'});
  assert.equal(body.max_output_tokens,512);
  assert.equal(body.input,'elf Uhr');
  assert.equal(body.store,false);
  assert.equal(body.text.format.strict,true);
});
test('incomplete, missing, refused and invalid output never become a guessed grade',()=>{
  const answer={attempt:true,unknown:false,hour:11,minute:0};
  assert.deepEqual(parseExtraction(complete(answer)),answer);
  for (const output of [{...complete(answer),status:'incomplete'}, {status:'completed',output:[]},
    complete(null),complete({...answer,hour:24}),complete({...answer,minute:60}),complete({...answer,hour:null})]) {
    assert.throws(()=>parseExtraction(output));
  }
  assert.deepEqual(parseExtraction(complete({...answer,unknown:true,hour:null,minute:null})),
    {...answer,unknown:true,hour:null,minute:null});
});
test('provider failure emits only bounded operational metadata and does not poison a later attempt',async()=>{
  const logs=[]; let calls=0;
  const options={diagnostic:value=>logs.push(value),fetcher:async()=>++calls===1
    ? {ok:true,status:200,json:async()=>({status:'incomplete',incomplete_details:{reason:'max_output_tokens'},output:[]})}
    : {ok:true,status:200,json:async()=>complete({attempt:true,unknown:false,hour:11,minute:0})}};
  await assert.rejects(extractClockAnswer('synthetic-key','private child words',options),e=>e.code==='answer_unavailable');
  assert.equal((await extractClockAnswer('synthetic-key','eleven o clock',options)).hour,11);
  assert.equal(JSON.parse(logs[0]).reason,'incomplete');
  assert.equal(logs.length,1);
  assert.ok(!logs[0].includes('private') && !logs[0].includes('synthetic-key'));
});
