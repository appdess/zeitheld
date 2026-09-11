import WebSocket from 'ws';
import { AppError } from './policy.js';

// A missing/expired session can take longer to reject attachment than a live
// session takes to accept it. Keep the handshake within the overall deadline.
export async function closeLiveProvider(providerID, ledgerID, apiKey, {
  createSocket = (url, options) => new WebSocket(url, options),
  handshakeTimeout = 18000,
  timeout = 23000,
} = {}) {
  return new Promise((resolve, reject) => {
    const ws = createSocket(`wss://api.openai.com/v1/live/sessions/${encodeURIComponent(providerID)}/attach`, {
      headers: { Authorization: `Bearer ${apiKey}`, 'OpenAI-Safety-Identifier': ledgerID }, handshakeTimeout,
    });
    let done = false;
    const finish = (error, usage) => {
      if (done) return;
      done = true; clearTimeout(timer); ws.terminate();
      error ? reject(error) : resolve(usage);
    };
    const timer = setTimeout(() => finish(new AppError('close_retry_needed', 503)), timeout);
    ws.on('open', () => ws.send(JSON.stringify({ type: 'session.close' })));
    ws.on('message', raw => {
      try {
        const event = JSON.parse(raw.toString());
        if (event.type === 'session.closed') finish(null, event.usage?.seconds);
        // Ignore mirrored content; only authoritative final usage is retained.
      } catch { finish(new AppError('close_retry_needed', 503)); }
    });
    ws.on('unexpected-response', (_, response) => {
      if ([404, 410].includes(response.statusCode)) finish(null, undefined);
      else finish(new AppError('close_retry_needed', 503));
    });
    ws.on('error', () => finish(new AppError('close_retry_needed', 503)));
    ws.on('close', () => { if (!done) finish(new AppError('close_retry_needed', 503)); });
  });
}
