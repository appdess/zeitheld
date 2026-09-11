import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { sessionStart } from './session.js';
import prompts from './prompts.json' with { type: 'json' };

test('managed Live uses the same teaching policy as the own-key client', () => {
  const swift=readFileSync(new URL('../../WatchLearn/Services/Live/LiveEventCodec.swift', import.meta.url), 'utf8');
  const voice=swift.match(/static func instructions\(language: RealtimeCoachLanguage\)[\s\S]*?return """\n([\s\S]*?)\n        """/)[1]
    .replace('\\(languageRule)','{languageRule}');
  assert.equal(prompts.voice,voice,'Managed and own-key prompts must not drift');
});

test('both languages retain direct Live media, silent grading and exact half-hour teaching', () => {
  for(const language of ['de','en']) {
    const {session}=sessionStart(language);
    assert.equal(session.model,'gpt-live-1');
    assert.equal(session.store,false);
    assert.equal(session.delegation.type,'client');
    assert.equal(session.audio.output.voice,'marin');
    assert.equal(session.turn_detection,undefined);
    assert.match(session.instructions,/halb fünf=4:30, halb sechs=5:30, halb sieben=6:30/);
    assert.match(session.instructions,/half past five=5:30 and half past six=6:30/);
    assert.match(session.instructions,/Delegate silently/);
    assert.match(session.instructions,/Never announce a check/);
  }
  assert.throws(()=>sessionStart('invalid'));
});
