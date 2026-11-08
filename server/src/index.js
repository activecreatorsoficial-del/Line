import http from 'node:http';
import { randomBytes, randomInt, scryptSync, timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { WebSocket, WebSocketServer } from 'ws';

// This process accepts control messages only. It never accepts file uploads.
export function createSignalingServer({ port = 8787, host = '127.0.0.1', ttl = 10 * 60_000,
  maxRooms = 1000, allowedOrigins = [], maxClients = 200 } = {}) {
  const rooms = new Map();
  const budgets = new Map();
  const send = (ws, message) => {
    if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
  };
  const server = http.createServer((req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ service: 'Line signaling', ok: true }));
    } else { res.writeHead(404); res.end(); }
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024, perMessageDeflate: false });
  const destroyRoom = (id, reason) => {
    const room = rooms.get(id);
    if (!room) return;
    rooms.delete(id);
    for (const ws of [room.owner, room.guest]) {
      if (!ws) continue;
      ws.roomId = null;
      if (reason) send(ws, { type: 'error', message: reason });
      ws.close(1000, reason ? 'Room closed' : 'P2P established');
    }
  };
  server.on('upgrade', (req, socket, head) => {
    const origin = req.headers.origin;
    const address = req.socket.remoteAddress;
    const count = [...wss.clients].filter(ws => ws.address === address).length;
    if (req.url !== '/ws' || wss.clients.size >= maxClients || count >= 20 ||
        (origin && !allowedOrigins.includes(origin))) {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return;
    }
    wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req));
  });
  wss.on('connection', (ws, req) => {
    ws.address = req.socket.remoteAddress;
    ws.alive = true;
    ws.on('pong', () => { ws.alive = true; });
    ws.on('error', () => {});
    ws.on('message', (raw, binary) => {
      try {
        const now = Date.now();
        if (!ws.window || now - ws.window > 1000) { ws.window = now; ws.messages = 0; }
        if (++ws.messages > 80) { ws.close(1008, 'Rate limit'); return; }
        if (binary) { ws.close(1008, 'Control messages only'); return; }
        const msg = JSON.parse(raw.toString());
        if (!msg || typeof msg !== 'object' || Array.isArray(msg)) throw Error();
        if (msg.type === 'create' || msg.type === 'join') {
          if (ws.roomId) throw Error();
          let budget = budgets.get(ws.address);
          if (!budget || now - budget.since > 60_000) {
            budget = { since: now, attempts: 0 }; budgets.set(ws.address, budget);
          }
          if (++budget.attempts > 10) {
            send(ws, { type: 'error', message: 'Too many attempts. Please wait a minute.' }); return;
          }
          if (msg.type === 'create') {
            if (rooms.size >= maxRooms) throw Error();
            let id;
            do { id = `LINE-${randomBytes(4).toString('hex').toUpperCase()}`; } while (rooms.has(id));
            const code = String(randomInt(0, 100_000_000)).padStart(8, '0');
            const salt = randomBytes(16);
            const room = { owner: ws, guest: null, salt,
              hash: scryptSync(code, salt, 32), expires: now + ttl, ready: new Set() };
            rooms.set(id, room); ws.roomId = id;
            send(ws, { type: 'created', room: id, code, expires: room.expires });
            return;
          }
          const roomId = typeof msg.room === 'string' ? msg.room.trim().toUpperCase() : '';
          const room = rooms.get(roomId);
          const validCode = typeof msg.code === 'string' && /^\d{8}$/.test(msg.code);
          const hash = scryptSync(validCode ? msg.code : '', room?.salt ?? Buffer.alloc(16), 32);
          if (!room || !validCode || room.guest || room.expires <= now ||
              !timingSafeEqual(hash, room.hash)) {
            send(ws, { type: 'error', message: 'The room or code is invalid, in use or expired.' }); return;
          }
          room.guest = ws; ws.roomId = roomId;
          send(ws, { type: 'joined', room: roomId });
          send(room.owner, { type: 'peer-joined' });
          return;
        }
        const room = rooms.get(ws.roomId);
        if (!room || room.expires <= now) throw Error();
        const other = room.owner === ws ? room.guest : room.owner;
        if (msg.type === 'signal') {
          const data = msg.data;
          if (!other || !data || typeof data !== 'object') throw Error();
          if (data.type === 'offer' || data.type === 'answer') {
            if ((data.type === 'offer') !== (room.owner === ws) ||
                typeof data.sdp !== 'string' || data.sdp.length > 48_000) throw Error();
            send(other, { type: 'signal', data: { type: data.type, sdp: data.sdp } });
          } else if (data.type === 'candidate') {
            if (typeof data.candidate !== 'string' || data.candidate.length > 4096 ||
                (data.sdpMid !== null && typeof data.sdpMid !== 'string') ||
                (data.sdpMLineIndex !== null && !Number.isInteger(data.sdpMLineIndex))) throw Error();
            send(other, { type: 'signal', data: { type: 'candidate', candidate: data.candidate,
              sdpMid: data.sdpMid, sdpMLineIndex: data.sdpMLineIndex } });
          } else throw Error();
        } else if (msg.type === 'ready') {
          room.ready.add(ws);
          if (room.ready.size === 2) destroyRoom(ws.roomId);
        } else throw Error();
      } catch {
        send(ws, { type: 'error', message: 'Invalid signaling request.' });
      }
    });
    ws.on('close', () => {
      if (ws.roomId) destroyRoom(ws.roomId, 'The other device left the room.');
    });
  });
  const maintenance = setInterval(() => {
    const now = Date.now();
    for (const [id, room] of rooms) if (room.expires <= now) destroyRoom(id, 'The room has expired. Create a new room.');
    for (const [ip, b] of budgets) if (now - b.since > 60_000) budgets.delete(ip);
    for (const ws of wss.clients) {
      if (!ws.alive) { ws.terminate(); continue; }
      ws.alive = false; ws.ping();
    }
  }, Math.min(ttl, 30_000));
  maintenance.unref();
  return {
    server, rooms,
    listen: () => new Promise(resolve => server.listen(port, host, () => resolve(server.address()))),
    close: () => new Promise(resolve => {
      clearInterval(maintenance);
      for (const ws of wss.clients) ws.terminate();
      wss.close(() => server.close(resolve));
    }),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const app = createSignalingServer({
    port: Number(process.env.PORT ?? 8787), host: process.env.HOST ?? '127.0.0.1',
    allowedOrigins: (process.env.ALLOWED_ORIGINS ?? '').split(',').filter(Boolean),
  });
  const address = await app.listen();
  console.log(`Line signaling: ${address.address}:${address.port} (no file storage)`);
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => app.close().then(() => process.exit(0)));
}
