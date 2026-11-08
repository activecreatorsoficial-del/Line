# Development and architecture

Direct file sharing between Windows and Android. The device creating a room owns the selected files and the temporary sharing session. Files use an encrypted WebRTC DataChannel and are not uploaded to central storage.

Version **0.9.0** adds **Internet invitation + response** negotiation with free Cloudflare STUN. It no longer requires the receiver to reach a public room-listener port before WebRTC can start. No billing account, API key, public room directory or paid relay is configured. Nearby keeps its embedded encrypted room and existing same-network flow. The approved monochrome design and two-arrow icon remain.

## Downloads

- `release/Line-Setup-0.9.0.exe`: per-user Windows installer; no administrator install required.
- `release/Line-Windows-portable.zip`: extract the entire folder and open `line.exe`.
- `release/Line-Android-0.9.0-preview.apk`: preview APK signed with the existing local development identity.

Update both devices and create fresh invitations. Old versions cannot understand the new Internet exchange. Nearby v1 invitations remain supported. Close Line before updating. Windows is not commercially code-signed; the Android preview needs a production signing strategy before public distribution.

## Nearby - same local network

1. Connect both devices to the same local network, such as the same Wi-Fi or hotspot. An Ethernet PC and Wi-Fi phone can share the same LAN.
2. Sender: choose Send, Nearby and your files, then Create sharing room.
3. Share the full invitation and the separate **eight-digit** temporary code privately.
4. Receiver: open Receive, paste the invitation/code, then Join room.
5. Compare the security codes on both screens before choosing Accept and receive.

The sender runs an encrypted WSS room inside the app. Each room has its own temporary TLS certificate, a SHA-256 certificate pin, a salted PBKDF2 code verifier, a ten-minute lifetime and one receiver. The room listener closes after signaling; file transfer continues over WebRTC. No external discovery is used with default Nearby settings.

## Internet - exchange an invitation and a response

1. Sender: choose Internet, choose files and Create sharing room. Keep Line open while it gathers connection addresses.
2. Copy invitation and share it privately with the separate **12-digit Internet code**.
3. Receiver: open Receive, paste the sender invitation and code, then Join room.
4. Receiver: select **Copy response** and return that response to the sender through your chosen communication channel.
5. Sender: paste it into **Connection response** and select **Connect devices**.
6. Compare the security codes on both screens, then the receiver selects **Accept and receive**.

Keep both apps open and return the response promptly. Invitations expire after ten minutes. If either network changes, or the native connection attempt times out, create a new room and exchange fresh messages. The short room name identifies the session; it is not a global room directory. The full invitation/response carries the encrypted connection description. Automatic deep-link opening and QR scanning are not implemented; use copy/paste.

This mode does not start a WSS room listener or require UPnP port mapping. Both peers gather IPv4/IPv6 candidates and attempt a direct connection. STUN helps discover publicly observed UDP addresses; it does not carry file payloads. A shared free discovery service is not the same as a central file-storage service.

Cloudflare documents its public STUN endpoint as free and unlimited: [Cloudflare Realtime FAQ](https://developers.cloudflare.com/realtime/turn/faq/). Line uses that endpoint without an account or billing credentials. No TURN allocation or paid fallback is enabled in Internet exchange. Provider availability and terms can change; failure does not trigger a paid service. Internet access itself remains subject to each user's normal connectivity plan.

Direct access is not guaranteed on every router, CGNAT deployment, VPN or mobile provider. Some networks require a relay; this mode reports failure rather than configuring one. IPv6 is no longer a prerequisite simply because the host has IPv6: the exchange can also advertise native IPv4 and STUN-derived IPv4 candidates. A common usable path is still required. [ICE specification](https://www.rfc-editor.org/rfc/rfc8445.html), [WebRTC TURN guidance](https://webrtc.org/getting-started/turn-server).

## Security and files

- Internet envelopes use AES-256-GCM, fresh salt/nonce, PBKDF2-HMAC-SHA256 with 65,536 iterations off the UI isolate, a random 128-bit session ID and authenticated expiry/type metadata. Responses bind to the exact offered SDP/session/expiry. Only bounded data-channel SDP is accepted; audio/video and relay candidates are rejected. Internet codes are 12 digits because captured invitations allow offline code guessing; Nearby retains its online attempt budget and eight digits.
- Share invitations and codes privately. Compare DTLS-derived security codes through an independent trusted channel before accepting. Code encryption is not a replacement for that comparison. Peers and the STUN service can observe connection metadata; this is not an anonymity tool.
- Invitations contain no file data. Files are read/written in 16 KiB chunks with a maximum 256 KiB application window, acknowledged after disk writes. SHA-256 is incremental, and a partial file is renamed only when its size/hash match. Filenames and duplicate paths are handled safely.
- Up to 50 files per session. Protocol metadata rejects individual files above 8 TiB; that is a validation ceiling, not a measured size guarantee. Practical limits include free disk space, filesystem limits, network speed and device policy. Multi-gigabyte physical performance is not yet measured.
- On Windows, choose the destination before accepting. Android first receives into private Line storage; Save to a folder on your phone exports a copy with a fixed 64 KiB buffer, requiring space for both copies.
- Android keeps a foreground sharing notification and CPU/Wi-Fi locks during an active session. Switching apps is supported while the session remains alive. Force-stop, task removal, system time limits and manufacturer battery restrictions can terminate it.
- Cleanup is idempotent and native/network waits are bounded. Cancel stops local processing before waiting for remote notification. Partial-file cleanup continues through its single operation; each session has its own destination directory.
- No accounts, analytics or central transfer history. Connection preferences remain local. Invitation codes and optional relay passwords are not persisted.

## Development and verification

Flutter/Dart, Visual Studio C++ tooling for Windows, and the Android SDK/JDK are required. There are no new dependencies or vendor-cache modifications for this exchange feature. Build Flutter targets sequentially because plugin registration files are shared.

```powershell
flutter pub get
flutter test
flutter analyze
flutter test integration_test/p2p_test.dart -d windows --dart-define=LINE_TEST_STUN=true
flutter test integration_test/p2p_test.dart -d <android-emulator-id> --dart-define=LINE_TEST_STUN=true
flutter build windows --release -t lib/main.dart
powershell -NoProfile -ExecutionPolicy Bypass -File tools/package-windows.ps1 -SkipBuild
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify-installer.ps1
flutter build apk --release -t lib/main.dart
```

The native test transfers 8 MB with content/security-code verification. The STUN assertion checks real public discovery on the initiator and verifies the response candidates through the actual data transfer; ICE may use reachable host or peer-reflexive candidates without advertising a reflexive candidate on each peer. Neither local test proves a transfer across unrelated physical internet connections.

`tools/cross_device_peer.dart` and `tools/verify-cross-device.ps1 -Internet` exercise separate native Windows/Android processes in both directions. ADB carries only test invitation/response metadata, replacing a human copy/paste channel. Internet exchange uses no WSS forwarding or address override; file bytes still travel over WebRTC. The Android-host case backgrounds the app and turns its screen off. The emulator still shares the development machine's network infrastructure, so this is not a mobile-operator ingress test. Build the test entrypoint separately and always rebuild `lib/main.dart` for release packaging.

## Existing direct-address support

`hostDirect` retains addressed-room/legacy-router behavior for compatibility and targeted tests. Existing v1 invitations still pin the host certificate. Direct manual public endpoints and optional custom STUN/TURN preferences apply outside the new Internet exchange; configuring a custom relay can involve that provider's fees. They are not a default or fallback service.

`RouterAccess` retains finite owned 600-second UPnP mappings, renewal, bounded local-only discovery and safe cleanup tests. `dart run tools/probe_router.dart` is read-only. `tools/check-network.ps1` produces a read-only Windows IPv6 configuration report without printing IP addresses. The current Internet exchange no longer rejects a peer solely because a v1 IPv6-only invitation cannot be reached.

`server/` and the old Node launcher scripts are legacy references and are not bundled. The Windows package contains the Flutter app, app-local C++ runtime and approved `line-arrows.ico`; the installer verifies shortcuts against that icon. Original Active Creators art remains in `assets/brand/`; Inter includes its OFL license. Original project code is published under the MIT license in LICENSE. Third-party assets retain their own license notices.

See `VERIFICATION.md` for actual checks and remaining limitations.
