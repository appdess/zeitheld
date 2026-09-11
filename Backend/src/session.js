import prompts from './prompts.json' with { type: 'json' };
export function sessionStart(language) {
  if (!['de', 'en'].includes(language)) throw new Error('invalid_language');
  return { type: 'session.start', session: {
    model: 'gpt-live-1', store: false,
    instructions: prompts.voice.replace('{languageRule}', language === 'de' ? 'Speak simple German.' : 'Speak simple English.')
      .replace('delegate to the backend for report_clock_answer.', 'delegate to the client for clock-answer extraction and app grading.'),
    audio: { output: { voice: 'marin' } },
    delegation: { type: 'client' },
  } };
}
