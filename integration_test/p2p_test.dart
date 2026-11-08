import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:integration_test/integration_test.dart';
import 'package:line/core/connection.dart';
import 'package:line/core/transfer.dart';
import 'package:line/core/router_access.dart';
import 'package:line/core/room_invitation.dart';
import 'package:line/core/internet_route.dart';
import 'package:line/core/local_room_server.dart';
import 'package:line/core/host_addresses.dart';
import 'package:line/core/exchange_invite.dart';
import 'package:path/path.dart' as p;

import '../test/support/mock_router.dart';
import '../test/support/local_router_route.dart';

Future<void> waitFor(bool Function() predicate, String label) async {
  final until = DateTime.now().add(const Duration(seconds: 35));
  while (!predicate()) {
    if (DateTime.now().isAfter(until)) throw TimeoutException(label);
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    testWidgets(
      'Android native Internet address bridge returns device addresses',
      (tester) async {
        await tester.runAsync(() async {
          final addresses = await readAndroidNetworkAddresses(internet: true);
          expect(addresses, isNotEmpty);
          expect(
            addresses.every((text) => InternetAddress.tryParse(text) != null),
            isTrue,
          );
        });
      },
    );
  }
  testWidgets('native failed handshake can close and create a fresh room', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final host = await LocalRoomServer.start(port: 0);
      try {
        for (var i = 0; i < 2; i++) {
          final failed = LineConnection();
          await failed.join(
            LineSettings(),
            RoomInvitation(
              room: host.room,
              fingerprint: '0' * 64,
              addresses: [host.loopback],
              expires: host.expires,
            ).encode(),
            '12345678',
          );
          expect(failed.phase, LinkPhase.error);
          await failed.close().timeout(const Duration(seconds: 5));
          failed.dispose();
          final fresh = LineConnection();
          try {
            await fresh.host(LineSettings(), []);
            await waitFor(
              () =>
                  fresh.phase == LinkPhase.waiting ||
                  fresh.phase == LinkPhase.error,
              'Fresh room after failed handshake',
            );
            expect(fresh.phase, LinkPhase.waiting, reason: fresh.error);
            expect(fresh.isRoomServerRunning, isTrue);
          } finally {
            await fresh.close().timeout(const Duration(seconds: 5));
            expect(fresh.isRoomServerRunning, isFalse);
            fresh.dispose();
          }
        }
      } finally {
        await host.close();
      }
    });
  });
  for (final mode in [
    'nearby',
    'router',
    'exchange',
    if (const bool.fromEnvironment('LINE_TEST_PUBLIC_IPV6')) 'ipv6',
  ]) {
    final internet = mode != 'nearby';
    final ipv6 = mode == 'ipv6';
    final exchange = mode == 'exchange';
    testWidgets(
      'native WebRTC transfers 8 MB with ${exchange
          ? 'encrypted invitation/response and free STUN'
          : ipv6
          ? 'IPv6-only signaling and ICE'
          : internet
          ? 'temporary router mappings (simulated gateway)'
          : 'Nearby hosting'}',
      (tester) async {
        await tester.runAsync(() async {
          final local =
              (await NetworkInterface.list(type: InternetAddressType.IPv4))
                  .expand((n) => n.addresses)
                  .where((a) => !a.isLoopback && !a.isLinkLocal)
                  .first;
          final mock = mode == 'router'
              ? await MockRouter.start(address: local)
              : null;
          final a = LineConnection(
            discoverRouter: ipv6
                ? () => discoverInternetRoute(
                    ipv4Discovery: () async => throw RouterAccessException(
                      'Simulated CGNAT; no real router writes',
                    ),
                  )
                : mock == null
                ? null
                : () async => LocalRouterRoute(
                    await RouterAccess.fromDescription(mock.description, local),
                    local.address,
                  ),
          );
          final b = LineConnection();
          final tmp = await Directory.systemTemp.createTemp(
            'line-native-test-',
          );
          try {
            final file = File(p.join(tmp.path, 'video.bin'));
            final output = file.openWrite();
            final buffer = Uint8List.fromList(
              List.generate(65536, (i) => i % 251),
            );
            for (var i = 0; i < 128; i++) {
              output.add(buffer);
            }
            await output.close();
            final settings = LineSettings(
              listenPort: 18790,
              stun: '',
              internetHosting: internet,
            );
            final hosting = exchange ? a.host : a.hostDirect;
            await hosting(settings, [
              TransferFile(
                id: '0',
                name: 'video.bin',
                size: await file.length(),
                path: file.path,
              ),
            ]);
            await waitFor(
              () => a.phase == LinkPhase.waiting || a.phase == LinkPhase.error,
              'Room creation',
            );
            expect(a.phase, LinkPhase.waiting, reason: a.error);
            expect(a.isRoomServerRunning, !exchange);
            var invite = a.invitation!;
            if (mock != null) {
              final parsed = RoomInvitation.parse(invite);
              expect(parsed.addresses.first, a.internetEndpoint);
              // The lab adapter keeps the route local. Use the actual listener
              // because the mock router does not forward its reserved TCP port.
              invite = RoomInvitation(
                room: parsed.room,
                fingerprint: parsed.fingerprint,
                addresses: parsed.addresses
                    .where((u) => u != a.internetEndpoint)
                    .toList(),
                expires: parsed.expires,
              ).encode();
            }
            await b.join(LineSettings(), invite, a.code!);
            if (exchange) {
              expect(b.phase, LinkPhase.waiting, reason: b.error);
              expect(b.isRoomServerRunning, isFalse);
              await expectLater(a.applyAnswer(invite), throwsFormatException);
              expect(a.phase, LinkPhase.waiting);
              await a.applyAnswer(b.invitation!);
              expect(a.relayCandidates + b.relayCandidates, 0);
              if (const bool.fromEnvironment('LINE_TEST_STUN')) {
                final exported = await ExchangeInvite.decode(
                  a.invitation!,
                  a.code!,
                );
                final kinds = RegExp(r'\btyp (\w+)')
                    .allMatches(exported.sdp)
                    .map((m) => m.group(1))
                    .toList();
                final returned = await ExchangeInvite.decode(
                  b.invitation!,
                  a.code!,
                );
                final returnedKinds = RegExp(r'\btyp (\w+)')
                    .allMatches(returned.sdp)
                    .map((m) => m.group(1))
                    .toList();
                final publicHosts = returned.sdp
                    .split('\n')
                    .where((line) => line.startsWith('a=candidate:'))
                    .where((line) {
                      final parts = line.trim().split(RegExp(r'\s+'));
                      final address = parts.length >= 8
                          ? InternetAddress.tryParse(parts[4])
                          : null;
                      return address != null &&
                          (isPublicIpv6(address) || isPublicV4(address));
                    })
                    .length;
                debugPrint(
                  'Exchange candidate types A=$kinds B=$returnedKinds; reflexive A=${a.reflexiveCandidates}, B=${b.reflexiveCandidates}; public B=$publicHosts.',
                );
                expect(a.reflexiveCandidates, greaterThan(0));
                // A local/peer-reflexive reply is valid when a candidate pair
                // is reachable; verify that path with the actual transfer below.
                expect(returnedKinds, isNotEmpty);
              }
            }
            await waitFor(
              () =>
                  b.transfer?.phase == TransferPhase.waitingApproval ||
                  b.phase == LinkPhase.error,
              'DataChannel opening: ${a.error}, ${b.error}',
            );
            expect(b.phase, LinkPhase.connected, reason: b.error);
            expect(a.safetyCode, isNotNull);
            expect(a.safetyCode, b.safetyCode);
            await waitFor(
              () => !a.isRoomServerRunning,
              'Embedded room service shutdown after peer connection',
            );
            if (ipv6) {
              expect(a.usesIpv6, isTrue);
              expect(b.usesIpv6, isTrue);
              expect(a.localIpv6Candidates, greaterThan(0));
              expect(b.localIpv6Candidates, greaterThan(0));
              expect(a.mappedUdpCandidates, 0);
              expect(
                isIpv6OnlyInvitation(
                  RoomInvitation.parse(a.invitation!).addresses,
                ),
                isTrue,
              );
            }
            if (mock != null) {
              await waitFor(
                () => !mock.entries.keys.any((k) => k.startsWith('TCP:')),
                'TCP mapping cleanup',
              );
              expect(a.mappedUdpCandidates, greaterThan(0));
              expect(
                mock.entries.keys.any((k) => k.startsWith('UDP:')),
                isTrue,
              );
            }
            await b.transfer!.accept(p.join(tmp.path, 'received'));
            await waitFor(
              () =>
                  a.transfer?.phase == TransferPhase.complete ||
                  a.transfer?.phase == TransferPhase.error,
              'File completion',
            );
            expect(
              a.transfer!.phase,
              TransferPhase.complete,
              reason: a.transfer!.error,
            );
            expect(b.transfer!.phase, TransferPhase.complete);
            expect(
              await sha256
                  .bind(File(b.transfer!.files.single.path!).openRead())
                  .first,
              await sha256.bind(file.openRead()).first,
            );
            expect(a.transfer!.transferredBytes, 8 * 1024 * 1024);
            if (mock != null) {
              await waitFor(
                () => mock.entries.isEmpty,
                'UDP cleanup after file completion',
              );
            }
          } finally {
            await a.close();
            await b.close();
            await mock?.close();
            a.dispose();
            b.dispose();
            await tmp.delete(recursive: true);
          }
        });
      },
    );
  }
}
