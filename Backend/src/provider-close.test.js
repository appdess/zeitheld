import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { closeLiveProvider } from './provider-close.js';

class Socket extends EventEmitter {
  sent = [];
  send(value) { this.sent.push(JSON.parse(value)); }
  terminate() { this.emit('close'); }
}
function fixture(options = {}) {
  const socket = new Socket();
  let configuration;
  const result = closeLiveProvider('synthetic-session', 'synthetic-ledger', 'fake-key', {
    timeout: 200, ...options,
    createSocket: (_, config) => { configuration = config; return socket; },
  });
  return { socket, result, configuration };
}
test('late missing-session response releases the lock with unknown usage, never zero', async () => {
  const f = fixture();
  assert.equal(f.configuration.handshakeTimeout, 18000);
  setTimeout(() => f.socket.emit('unexpected-response', null, { statusCode: 404 }), 30);
  assert.equal(await f.result, undefined);
});
test('only session.closed supplies final seconds; closing the socket alone is not finalization', async () => {
  const f = fixture(); f.socket.emit('open');
  assert.deepEqual(f.socket.sent, [{ type: 'session.close' }]);
  f.socket.emit('message', Buffer.from(JSON.stringify({ type: 'session.closed', usage: { seconds: 12.25 } })));
  assert.equal(await f.result, 12.25);
  const lost = fixture(); lost.socket.emit('close');
  await assert.rejects(lost.result, { code: 'close_retry_needed' });
});
test('timeout and provider failures retain the reservation for retry', async () => {
  const timed = fixture({ timeout: 10 });
  await assert.rejects(timed.result, { code: 'close_retry_needed' });
  const failed = fixture(); failed.socket.emit('unexpected-response', null, { statusCode: 503 });
  await assert.rejects(failed.result, { code: 'close_retry_needed' });
});
