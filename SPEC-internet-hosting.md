# Historical direct internet hosting design

The 0.9.0 Internet invitation exchange supersedes this earlier default flow. The implementation is retained for legacy invitations and targeted tests.

The user requires the device creating the room to remain its only server. Do not add a public coordinator, relay, VPN account, IP lookup API or file storage service. The user confirmed same-Wi-Fi sharing works.

Implement an explicit Internet hosting option that discovers a local UPnP Internet Gateway, checks that its WAN IPv4 is publicly routable, and requests short-lived TCP (pinned WSS room) and UDP (host ICE candidate) mappings. The invitation carries the mapped endpoint. WebRTC receives mapped server-reflexive candidates, while its existing DTLS and bounded file stream remain unchanged. This supplies a direct route for compatible routers; it is not a full system VPN and cannot bypass CGNAT or unsupported/blocked router controls.

Boundaries: no enabling UPnP in router settings, no Windows firewall changes, no permanent mappings, no overwriting mappings owned by other applications, no arbitrary SSDP URLs or redirects. Mapping descriptions are per-session and do not contain filenames or credentials. Leases are at most 600 seconds and are renewed only during an active session. Close TCP access after signaling; retain UDP during transfer and remove owned mappings on terminal states/cancellation. Leases bound cleanup after process death. Local-only sharing remains the default.

Implementation slices:
1. Bounded discovery, SOAP client, WAN validation and mapping lifecycle with a local mock router.
2. Host integration: publish TCP endpoint, map matching UDP host candidates, wait for mapping tasks before releasing signaling, clean up on all terminal paths.
3. English mode control and actionable failure messages; preserve approved icons/design. Version 0.7.0.
4. Unit/widget checks, native regression and Windows/Android preview packages. Report physical/router limitations and do not claim universal internet access.

Commands: `flutter test test/router_access_test.dart`, `flutter test`, `flutter analyze`, then sequential native Windows/Android builds. Existing installer payload/icon verification remains required.

Success: mock-router checks prove finite owned leases, public-address rejection, safe discovery, non-overwriting mappings, mapped ICE candidates, renewal and cleanup including cancellation. Native existing Wi-Fi transfer must still pass. Actual cross-internet connectivity additionally requires a compatible router/public WAN and an external participant, and must be recorded separately from simulated checks.


## Native IPv6 fallback - 0.8.0

The reported mobile-data/PC failure exposed an IPv4-only selection: CGNAT aborted discovery even when the host had native public IPv6. Preserve the no-external-service constraint and add an independent native IPv6 route after IPv4 discovery fails. Do not remove IPv4 reachability validation or imply that every public IPv6 accepts incoming traffic.

Publish only native public IPv6 addresses (bounded to four), rejecting local, documentation and common transition ranges. Retain the same pinned TLS listener, invitation format, separate access code and DTLS identity comparison. Both peers exchange only usable IPv6 ICE candidates for these rooms. Receivers without a usable IPv6 interface fail with a specific explanation. Port-busy fallback preserves a dual-stack listener where supported. No IPv6 firewall automation, PCP, NAT-PMP, external IP lookup, STUN or relay is added.

Validate CGNAT-to-IPv6 fallback, IPv4-only rejection, receiver diagnostics, address/candidate filtering and port conflict handling in unit tests. Run a native 8 MB Windows transfer over IPv6 only when the machine has a native public address; do not substitute IPv4 candidates. Keep Nearby and simulated-router regression tests on Windows and Android. External IPv6 ingress remains unverified until devices on independent internet connections complete a real transfer.


## Failed-session shutdown - 0.8.1

Reproduce failed and stalled native cleanup. Stop local file processing before waiting for the remote cancel message. Share a single shutdown future between automatic failure cleanup and UI actions; dispose native observers/channels while the peer still exists, then close it. Bound native/network waits without blocking independent cleanup. Reset UI controls in finally, and ignore late callbacks after shutdown. Verify recovery in the native Windows runtime and test separate Windows/Android processes in both directions. Preserve public-route restrictions and distinguish the user's Android Internet discovery error from a physical Nearby diagnosis.


IPv6 discovery must merge Android LinkProperties addresses on Internet-capable networks with Dart interfaces, including receiver preflight. Retain address-range validation and bound bridge calls. Test a native-only IPv6 fixture and invoke the actual Android bridge in the emulator; do not infer external reachability from the capability flag.
