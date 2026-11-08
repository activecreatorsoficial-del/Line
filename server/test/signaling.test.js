import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';
import { createSignalingServer } from '../src/index.js';

async function fixture(t, options = {}) {
  const app = createSignalingServer({ port: 0, ...options });
  const addr = await app.listen();
  t.after(() => app.close());
  const connect = async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${addr.port}/ws`);
    const queue = []; const waits = [];
    ws.on('message', raw => {
      const message = JSON.parse(raw.toString());
      if (waits.length) waits.shift()(message); else queue.push(message);
    });
    await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
    return { ws, send: obj => ws.send(JSON.stringify(obj)),
      next: () => queue.length ? Promise.resolve(queue.shift()) :
        new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(Error('Message timed out')), 2000);
          waits.push(value => { clearTimeout(timer); resolve(value); });
        }) };
  };
  return { app, connect };
}

test('room credentials, SDP/ICE routing, and both-ready signaling shutdown', async t => {
  const { app, connect } = await fixture(t);
  const a = await connect(); const b = await connect();
  a.send({ type: 'create' }); const room = await a.next();
  assert.match(room.room, /^LINE-[A-F0-9]{8}$/); assert.match(room.code, /^\d{8}$/);
  assert.ok(room.expires > Date.now());
  b.send({ type: 'join', room: room.room.toLowerCase(), code: room.code });
  assert.equal((await b.next()).type, 'joined'); assert.equal((await a.next()).type, 'peer-joined');
  a.send({ type: 'signal', data: { type: 'offer', sdp: 'test SDP' } });
  assert.equal((await b.next()).data.sdp, 'test SDP');
  b.send({ type: 'signal', data: { type: 'candidate', candidate: 'candidate:1', sdpMid: '0', sdpMLineIndex: 0 } });
  assert.equal((await a.next()).data.candidate, 'candidate:1');
  a.send({ type: 'ready' });
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(app.rooms.size, 1);
  const closes = [a, b].map(c => new Promise(resolve => c.ws.once('close', resolve)));
  b.send({ type: 'ready' }); await Promise.all(closes);
  assert.equal(app.rooms.size, 0);
});

test('invalid code, nonexistent room, and occupied room share one error', async t => {
  const { connect } = await fixture(t);
  const a = await connect(); const b = await connect(); const c = await connect();
  a.send({ type: 'create' }); const room = await a.next();
  b.send({ type: 'join', room: room.room, code: room.code === '00000000' ? '11111111' : '00000000' });
  const bad = await b.next();
  c.send({ type: 'join', room: 'LINE-FFFFFFFF', code: '00000000' });
  assert.deepEqual(await c.next(), bad);
  b.send({ type: 'join', room: room.room, code: room.code }); await b.next(); await a.next();
  c.send({ type: 'join', room: room.room, code: room.code }); assert.deepEqual(await c.next(), bad);
});

test('role checks reject a receiver making an offer', async t => {
  const { connect } = await fixture(t); const a = await connect(); const b = await connect();
  a.send({ type: 'create' }); const room = await a.next();
  b.send({ type: 'join', room: room.room, code: room.code }); await b.next(); await a.next();
  b.send({ type: 'signal', data: { type: 'offer', sdp: 'bad' } });
  assert.equal((await b.next()).type, 'error');
});

test('disconnect deletes room and notifies other device', async t => {
  const { app, connect } = await fixture(t); const a = await connect(); const b = await connect();
  a.send({ type: 'create' }); const room = await a.next();
  b.send({ type: 'join', room: room.room, code: room.code }); await b.next(); await a.next();
  a.ws.close(); assert.equal((await b.next()).type, 'error'); assert.equal(app.rooms.size, 0);
});

test('room expiry removes credentials', async t => {
  const { app, connect } = await fixture(t, { ttl: 150 }); const a = await connect();
  a.send({ type: 'create' }); await a.next();
  assert.match((await a.next()).message, /expired/); assert.equal(app.rooms.size, 0);
});

test('binary file payloads are refused', async t => {
  const { connect } = await fixture(t); const a = await connect();
  const closed = new Promise(resolve => a.ws.once('close', resolve));
  a.ws.send(Buffer.from('file content'));
  assert.equal(await closed, 1008);
});

test('authentication attempts are limited across connections on the same address', async t => {
  const { connect } = await fixture(t); const a = await connect();
  for (let i = 0; i < 10; i++) {
    a.send({ type: 'join', room: 'LINE-12345678', code: '00000000' }); await a.next();
  }
  const b = await connect(); b.send({ type: 'create' });
  assert.match((await b.next()).message, /Too many attempts/);
});
