# Line 0.9.0 - Free STUN invitation/response exchange

Checked on 7 November 2026. The previous Internet flow required a reachable WSS room listener before WebRTC could start; the new normal Internet flow exchanges encrypted signaling directly through user copy/paste.

Implemented:

- Sender creates an offer; receiver opens it with the separate 12-digit Internet code and returns a response; sender imports that response. No WSS room listener, UPnP request, public room directory, account, API key or TURN allocation is started by this mode. Nearby retains v1 pinned WSS invitations and eight-digit codes. Explicit hostDirect keeps addressed-room/legacy router tests available.
- Cloudflare's free public STUN hostname plus bounded system-resolved public IPv4 endpoints are used for ICE discovery. No file payload goes to the STUN service. Direct-only data SDP is validated on import/export; audio/video and relay candidates are rejected. The sender owns the selected files and temporary session.
- Envelopes use a fresh 128-bit session ID, salt and nonce, AES-256-GCM, PBKDF2-HMAC-SHA256 (65,536 iterations) off the UI isolate, authenticated type/expiry metadata and exact offer binding in the response. A 12-digit code improves resistance to offline guessing relative to the Nearby eight-digit code, whose WSS verifier has an online attempt budget. Independent DTLS security-code comparison remains necessary.
- Invalid/wrong-session responses leave the sender waiting for a valid response. Expired, oversized, malformed or altered envelopes are rejected. Payload/SDP and input sizes are bounded. No code or live invitation is logged or persisted.
- New English response forms retain the monochrome identity and two-arrow icon. Sender/receiver mobile component previews and the desktop Internet selector were visually inspected. Help explains free external discovery and the additional response step, and is scrollable.
- Windows SDK configuration has eight reused native ICE-server slots. Each configuration now clears unused slots, including old credentials, so switching to Nearby cannot retain a previously configured STUN/TURN server. No vendor-cache file or dependency was modified.

Verification completed:

- All 50 unit/widget tests passed, including encrypted round trips, wrong/short code, authenticated-header tampering, wrong-session response binding, expiry, bounded payloads, media/relay rejection, existing disk-integrity/cancellation/authentication checks and mobile response form errors. Static analysis passed without suppressed diagnostics.
- Native Windows: failure/recovery, Nearby, simulated router and new encrypted exchange cases passed. Native Android API 35 emulator: network bridge, failure/recovery, Nearby, simulated router and new exchange cases passed. Every transfer case sends 8,388,608 bytes with matching SHA-256 and security codes.
- Native STUN checks saw real reflexive candidates on the initiator (Windows 1; Android 2 in the recorded runs). The responder may select local, directly public or peer-reflexive routes. An initial test incorrectly demanded reflexive/public candidates on every responder; it was corrected to retain the real STUN assertion and require successful end-to-end data verification. Actual candidate types/counts are recorded without printing addresses or credentials. No candidate relay was configured or observed.
- Separate native Windows/Android processes passed in both directions using the new Internet exchange. Android-host case: foreground service checked, app backgrounded and screen turned off before Windows joined. Both cases verified 8 MB, equal SHA-256, matching security codes and zero relay candidates. Both platforms recorded reflexive candidates in these separate-process runs.
- The exchange lab used no WSS port forwarding and no invitation address override. ADB only carried offer/response metadata as a substitute for human messaging; file bytes traveled over WebRTC. The emulator still shares the development machine's network infrastructure, so these are not unrelated physical internet or mobile-operator ingress tests.
- Logs: build/exchange-final-tests.log, build/exchange-final-analyze.log, build/exchange-native-windows.log, build/exchange-native-android.log, build/exchange-lab-android-host.log, build/exchange-lab-windows-host.log. Separate-process results: build/lan-lab/android-host-exchange-result.json and windows-host-exchange-result.json.

Release verification:

- Windows 0.9.0+14 release completed from lib/main.dart. All 32 extracted installer payload files matched the staged distribution by SHA-256. The actual installer shortcut helper uses the approved two-arrow icon. No Windows installation was performed. Logs: build/exchange-build-windows.log, build/exchange-package-windows.log, build/exchange-verify-installer.log.
- Android release reports version 0.9.0, code 14, minimum API 24 and target API 36. APK signature verification passed, and its signing identity matches 0.8.1. It installed and cold-started successfully in the owned API 35 emulator. The final main app screen was visually inspected; the scoped AndroidRuntime crash log was empty. Logs: build/exchange-build-android.log, build/exchange-apk-signature.log, build/exchange-release-crash-check.log. Screenshot: release/Line-Android-0.9.0.png. The test app and owned emulator were stopped after verification.

Remaining limits:

A physical transfer across two unrelated internet connections remains unverified in this session. Restrictive NAT/filtering, unavailable STUN or no common route can still prevent a direct connection. There is no paid relay fallback. The receiver should return a response promptly; native ICE attempts can time out before the envelope's ten-minute expiry. If either network changes, create fresh invitations. Long invitations can exceed a messaging service's text limit: send the complete text through a suitable channel or as a private text attachment. QR scanning/encoding, automatic deep-link opening, measured multi-gigabyte performance, production code signing and public repository licensing/publication are not newly supplied.

Sources: [Cloudflare public STUN pricing](https://developers.cloudflare.com/realtime/turn/faq/), [ICE connectivity and peer-reflexive candidates](https://www.rfc-editor.org/rfc/rfc8445.html), [WebRTC relay requirements](https://webrtc.org/getting-started/turn-server).

## Historical verification - Line 0.8.1

Checked on 7 November 2026. The user reported a Windows receiver stuck on Closing after a connection error, and Android Internet hosting without a discovered public IPv4/IPv6 route. These are separate conditions. The latest user clarification identifies the supplied public-address error as Internet hosting on Android, not a Nearby endpoint diagnostic.

Changes:

- Failed connections and user cancellation now share one idempotent cleanup future. Native channels/observers are disposed before the native peer is closed. Native/remote cleanup steps have bounded waits, and independent resources close even when one step errors or does not answer. Pending connectors, host listeners and Android sharing sessions are stopped as part of the same shutdown.
- The UI resets its session and Closing state in a finally block. Cancellation marks the file engine stopped before trying to notify the other device. Partial-file cleanup retains its single operation and unique per-session destination directory.
- Late channel callbacks cannot restart a closed session. A security-description read interrupted by closing is handled without leaving an unobserved native error.
- IPv6 hosting/receiver checks now merge Dart interfaces with Android LinkProperties on networks advertising Internet capability. The previous fallback consulted Dart only, even though Nearby already used Android's network API. Address filtering and deduplication are shared; documentation, link-local and transition ranges remain rejected. A unit case proves that native global IPv6 is retained when Dart omits the interface. The Wi-Fi bridge retains its behavior and native reads are bounded.
- No new server, relay, network mapping strategy, firewall rule or dependency was added. In particular, this patch does not turn an unavailable mobile public route into a working Internet listener.

Verification completed:

- All 46 unit/widget tests passed. Added checks cover one-time disposal order, a native close error, a stalled native dispose and local cancellation while the remote send is held. Static analysis passed with no issues. Desktop Internet UI reference was visually inspected; the approved identity is unchanged.
- Separate-process native peers transferred 8,388,608 bytes in both directions: Android host to Windows receiver, and Windows host to Android receiver. SHA-256 and independent security codes matched. For Android hosting, the sharing service was checked as foreground, then the app was backgrounded and its screen turned off before Windows joined. The room listener shut down after signaling.
- The emulator boundary used an explicit WSS test route: ADB forwarding for Android hosting, and 10.0.2.2 for Windows hosting. TLS pinning remained enabled and file bytes used WebRTC. This is not a physical same-Wi-Fi or mobile-operator ingress test. Results: `build/lan-lab/android-host-result.json`, `build/lan-lab/windows-host-result.json`; logs: `build/android-host-lab.log`, `build/windows-host-lab.log`.
- Unit/static logs: `build/android-host-final-tests.log`, `build/android-host-final-analyze.log`.
- Final Android native run passed four cases: the actual Internet-address bridge returned valid device addresses; two failed-handshake/fresh-room recovery cycles completed; Nearby and simulated-router transfers each verified 8 MB. Log: `build/android-host-native-android.log`. This validates the bridge on the emulator, not the existence of a public IPv6 on the user's mobile network.
- Native Windows recovery test passed: two consecutive invalid-certificate handshakes closed within the deadline, and a fresh room was successfully created and closed after each. The same native run also passed Nearby, simulated-router and IPv6-only 8 MB transfers. Log: `build/android-host-native-windows.log`. The recovery check waits for the asynchronous room-created event before assessing the fresh room.

Release verification:

- Windows 0.8.1+13 release completed. All 32 extracted installer payload files matched the staged distribution by SHA-256; the installer-created shortcut uses the approved two-arrow icon. No Windows installation was performed. Logs: `build/shutdown-build-windows.log`, `build/shutdown-verify-installer.log`.

- Final Android 0.8.1 release reports version code 13, minimum API 24 and target API 36. APK signature verification passed and the signing identity matches 0.8.0. It installed and cold-started successfully in the owned emulator; its screen was visually inspected and the scoped AndroidRuntime log showed no crash. The test app and emulator were stopped afterwards. Logs: `build/shutdown-build-android.log`, `build/shutdown-apk-signature.log`; screenshot: `release/Line-Android-0.8.1.png`.

Remaining network limit:

The reported Android Internet error means the previous version discovered no usable automatic public IPv4 route or native public IPv6 host address. The added Android-native fallback addresses a possible false negative; it has not been checked on the user's physical phone. Receiving connections from another internet requires a reachable route to that host. The patch fixes stuck cleanup; it does not promise incoming mobile-provider access where such a route is absent. Physical Android-host Nearby behavior and real Android mobile-provider IPv6 ingress were not observed in this session.

Android network API references: [LinkProperties.getLinkAddresses](https://developer.android.com/reference/android/net/LinkProperties#getLinkAddresses()) returns addresses assigned to a link; [NET_CAPABILITY_INTERNET](https://developer.android.com/reference/android/net/NetworkCapabilities#NET_CAPABILITY_INTERNET) describes intended Internet connectivity. Neither API verifies incoming access from another network.

## Historical verification - Line 0.8.0

Checked on 7 November 2026. Nearby works on the user's physical devices. The reported Internet failure exposed an IPv4-only route selection: CGNAT stopped discovery before Line considered native public IPv6 already assigned to the PC.

Implemented:

- After an IPv4 discovery failure, select existing native public IPv6 where available. Invitations contain at most four IPv6 WSS endpoints with the existing TLS certificate pin, expiry and separate access code. Both peers restrict this room's SDP/trickle ICE to usable IPv6 candidates; the DTLS fingerprint is preserved.
- Reject local, documentation and common transition-only addresses for Internet hosting. Receivers without a usable IPv6 interface get a specific error before dialing. An occupied port keeps a dual-stack listener when supported.
- English helper, waiting and error messages distinguish IPv4 CGNAT, IPv6 requirements and unverified incoming access. No external coordinator, relay, IP lookup, STUN service or firewall automation was added.
- Fixed a cleanup race found by the existing corrupt-file test: shutdown now waits for the same partial-file cleanup operation instead of racing a second cleanup against it.

Verification completed:

- All 41 unit/widget tests passed. Static analysis reported no issues. Updated desktop Internet and mobile UI references were visually inspected; approved monochrome design and two-arrow icon remain.
- Native Windows: Nearby, simulated UPnP and opt-in IPv6-only cases each transferred 8,388,608 bytes with matching SHA-256 and security codes. The IPv6 case used this PC's actual native public IPv6 addresses, no IPv4 candidates, no NAT mappings and no external signaling/STUN/TURN. The room listener closed before file transfer continued.
- Android API 35 emulator: Nearby and simulated-router native cases each transferred 8,388,608 bytes with matching content. Both peers run in the same native process in these tests. The emulator was not used to claim a public IPv6 or physical mobile-provider test.
- Logs: `build/ipv6-all-tests.log`, `build/ipv6-analyze.log`, `build/ipv6-native-windows.log`, `build/ipv6-native-android.log`.

Release artifacts:

- Windows release reports product/file version 0.8.0+12. Installer extraction verified all 32 staged payload files by SHA-256 and the actual installer-created shortcut points to the approved two-arrow icon. No Windows install was performed.
- Android release APK reports version 0.8.0/code 12, minimum API 24 and target API 36. Signature verification passed and the signing identity matches 0.7.1. The final release installed and cold-started successfully in the owned API 35 emulator. The screen was visually inspected and the scoped AndroidRuntime crash check reported no exception; the test app and owned emulator were stopped afterwards.
- Release logs: `build/ipv6-build-windows.log`, `build/ipv6-package-windows.log`, `build/ipv6-verify-installer.log`, `build/ipv6-build-android.log`, `build/ipv6-apk-signature.log`. Actual Android screenshot: `release/Line-Android-0.8.0.png`.
- The existing English video kit was refreshed to describe IPv4/IPv6 requirements accurately. Its 17-file ZIP passed integrity checks, and narration/captions remain identical on a continuous 70-second timeline. No video was rendered.

Network evidence and limits:

Read-only interface/gateway checks found native global IPv6 on Ethernet alongside shared carrier IPv4 (CGNAT). The gateway did not advertise WANIPv6FirewallControl. No real router mappings or OS firewall changes were requested. Local IPv6 success does not prove outside-in access through that router or the Android mobile provider. The Android physical mobile network's IPv6 availability remains unverified.

A physical transfer between independent internet connections, IPv6 incoming-filter traversal and real-router port mapping/renewal remain unverified. Networks that provide neither reachable public IPv4 nor reachable IPv6 cannot host a direct incoming session under the no-external-service constraint. Multi-gigabyte performance and manufacturer battery policies are not newly measured.

## Historical verification - Line 0.7.1

The Nearby selector now explains that devices share files on the same local network, such as the same Wi-Fi or hotspot. Its helper text uses the existing Internet text style and spacing. All six existing UI tests passed and desktop/mobile goldens were updated and visually inspected. Windows and Android 0.7.1 builds completed. All 32 Windows payload files and the installer-created two-arrow shortcut were verified. The APK reports version code 11 and its verified signing identity matches 0.7.0; the Nearby sentence was confirmed in its compiled ARM64 artifact. This patch changes copy and presentation only; the network verification and limitations of 0.7.0 below remain applicable.

## Line 0.7.0 - Direct internet hosting by the creating device

Checked on 7 November 2026. The user reports that physical same-Wi-Fi sharing now works. The requested constraint is unchanged: the device creating the room is its server, with no external coordinator, relay, VPN account or IP lookup API.

Implemented:

- Explicit Nearby / Internet selection, defaulting to Nearby. Internet requests temporary UPnP routes from a compatible local gateway. The manual public-host setting is retained outside automatic Internet mode; existing optional STUN/TURN fields must be empty in direct Internet mode.
- Bounded SSDP discovery on local interfaces and a SOAP client restricted to numeric local addresses. Redirects, external control URLs, oversized bodies and XML declarations for entities/DTDs are rejected. Several WAN services are checked so an inactive service does not hide a usable one.
- WAN IPv4 validation rejects private/shared/loopback/link-local/documentation/reserved ranges. CGNAT is explicitly reported before a port is opened.
- TCP access reaches the creating device's existing pinned WSS service. Matching native host UDP sockets get finite mappings, advertised as server-reflexive ICE candidates. Signaling waits for pending mappings before announcing readiness.
- Mapping requests have 600-second leases, refreshed every three minutes while needed. Existing rules are not overwritten. Deletion and renewal check internal client, port and per-session description. TCP access is released after signaling, UDP after completion/cancel/error. Failure to confirm cleanup during setup is reported; finite confirmed leases bound exposure after a lost network or process exit.
- The existing TLS pin, room password, security-code comparison, DTLS file channel, bounded disk streaming, Android sharing session and two-arrow icon remain.

Verification:

- 35 unit/widget tests passed, including gateway lifecycle, lease refusal, unconfirmed cleanup reporting, ownership changes, CGNAT rejection, safe discovery/control URLs, inactive WAN selection, discovery/mapping cancellation, room authentication, binary-file integrity, retry, mode preservation and responsive/animation checks.
- Flutter static analysis passed with no issues.
- Windows and Android release builds completed for 0.7.0. All 32 extracted Windows payload files matched the staged distribution by SHA-256, and the actual installer shortcut helper generated a shortcut pointing to the approved two-arrow icon. No Windows installation was performed.
- Final APK signature verification passed and matches the prior preview signing identity. Version code 10, minimum API 24, target API 36. The release APK installed and cold-started successfully in the owned API 35 emulator; the test app and emulator were stopped afterwards.
- Native Windows: Nearby and simulated-gateway cases each transferred 8,388,608 bytes with matching SHA-256 and security codes. The simulated-gateway case confirmed mapped ICE candidates, TCP cleanup before acceptance and UDP cleanup after completion.
- Android API 35 emulator: the same two native cases passed. Both peers in each case run in the same native process. A test-only route adapter keeps all packets local, and the test does not dial the public fixture address or use external signaling/STUN/TURN.
- Native logs: `build/internet-native-windows.log`, `build/internet-native-android.log`. Unit/static logs: `build/internet-final-tests.log`, `build/internet-final-analyze.log`.

Actual network finding:

A read-only `dart run tools/probe_router.dart` query found that the responding gateway advertises an IPv4 in shared carrier space (CGNAT). No port mappings were requested on the real router. A direct inbound internet path cannot be demonstrated through this connection under the no-external-service constraint. A reachable public connection and compatible gateway are required. This is not a universal Hamachi-style virtual LAN.

Not validated: a physical transfer between two independent internet connections, real-router port mapping/lease renewal, host firewall traversal, automatic IPv6 pinholes/PCP/NAT-PMP, multi-gigabyte performance, Android manufacturer battery policies and full Windows install/uninstall execution. Prior 0.6.1 separate-process Windows/Android cross-platform checks remain recorded in `build/lan-lab/`; they are not presented as a 0.7.0 internet test.
