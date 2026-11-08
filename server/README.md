# Legacy signaling prototype

This directory preserves Line's earlier Node.js/WebSocket signaling prototype. The current Flutter app implements Nearby room hosting in lib/core/local_room_server.dart and Internet invitation exchange in lib/core/exchange_invite.dart.

For the current application, follow the root README. [Line usage and downloads](../README.md)

To inspect the prototype separately, use Node.js 22 or later.

```sh
npm ci
npm test
npm start
```

The default listener is 127.0.0.1 on port 8787. .env.example documents its settings. The prototype exchanges signaling messages and applies room lifetimes, attempt limits and payload bounds.
