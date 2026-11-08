import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:line/core/internet_route.dart';
import 'package:line/core/router_access.dart';
import 'package:line/core/connection.dart';
import 'package:line/core/room_invitation.dart';
import 'package:line/core/local_room_server.dart';
import 'package:line/core/host_addresses.dart';

void main() {
  test('native Android IPv6 is retained when Dart omits its interface', () {
    final addresses = mergeIpv6Addresses(
      [
        HostInterface('wlan0', [InternetAddress('fd00::1')]),
      ],
      [
        '2001:4860:4860::8888',
        'fd00::1',
        'fe80::1',
        '2001:db8::1',
        '10.0.0.2',
        'invalid',
      ],
    );
    expect(addresses.map((a) => a.address), [
      'fd00::1',
      '2001:4860:4860::8888',
    ]);
    expect(addresses.any(isPublicIpv6), isTrue);
  });
  test(
    'a receiver without IPv6 gets an explicit error before connecting',
    () async {
      final link = LineConnection(receiverHasIpv6: () async => false);
      final invitation = RoomInvitation(
        room: 'LINE-1234ABCD',
        fingerprint: 'a' * 64,
        addresses: [Uri.parse('wss://[2001:4860:4860::8888]:8790/ws')],
        expires: DateTime.now().add(const Duration(minutes: 5)),
      ).encode();
      try {
        await link.join(LineSettings(), invitation, '12345678');
        expect(link.phase, LinkPhase.error);
        expect(link.error, contains('no usable IPv6'));
        expect(link.connectionAttempts, isEmpty);
      } finally {
        await link.close();
        link.dispose();
      }
    },
  );

  test(
    'an occupied listening port retains IPv6 on the available port',
    () async {
      final first = await LocalRoomServer.start(port: 0);
      final second = await LocalRoomServer.start(port: first.port);
      try {
        expect(second.port, isNot(first.port));
        expect(second.supportsIpv6, first.supportsIpv6);
      } finally {
        await first.close();
        await second.close();
      }
    },
  );

  test(
    'public IPv6 excludes local, documentation and transition-only addresses',
    () {
      for (final text in [
        '::1',
        'fe80::1',
        'fd00::1',
        '::ffff:192.168.1.1',
        '2001:db8::1',
        '3fff::1',
        '2001::1',
        '2002:c000:0201::1',
        '2001:2::1',
        '2001:10::1',
        '2001:20::1',
        '2001:30::1',
      ]) {
        expect(isPublicIpv6(InternetAddress(text)), isFalse, reason: text);
      }
      expect(isPublicIpv6(InternetAddress('2001:4860:4860::8888')), isTrue);
      expect(isPublicIpv6(InternetAddress('8.8.8.8')), isFalse);
    },
  );

  test('CGNAT selects an existing public IPv6 route without a relay', () async {
    final route = await discoverInternetRoute(
      ipv4Discovery: () async => throw RouterAccessException('CGNAT'),
      ipv6Discovery: () async => [InternetAddress('2001:4860:4860::8888')],
    );
    try {
      expect(route, isA<DirectIpv6Route>());
      final endpoints = (route as DirectIpv6Route).endpoints(8790);
      expect(
        endpoints.single.toString(),
        'wss://[2001:4860:4860::8888]:8790/ws',
      );
      expect(isIpv6OnlyInvitation(endpoints), isTrue);
      expect(await route.openRoom(8790), endpoints.single);
      expect(
        await route.mapCandidate(
          'candidate:a 1 udp 1 192.168.1.1 5000 typ host',
        ),
        isNull,
      );
    } finally {
      await route.close();
    }
    await expectLater(
      route.openRoom(8790),
      throwsA(isA<RouterAccessException>()),
    );
  });

  test('an IPv4-only CGNAT network remains an explicit failure', () async {
    await expectLater(
      discoverInternetRoute(
        ipv4Discovery: () async => throw RouterAccessException('CGNAT'),
        ipv6Discovery: () async => [],
      ),
      throwsA(
        isA<RouterAccessException>().having(
          (e) => e.message,
          'message',
          contains('IPv6'),
        ),
      ),
    );
  });

  test(
    'IPv6-only signaling filters IPv4 ICE without changing the SDP identity',
    () {
      const v4 = 'candidate:a 1 udp 1 192.168.1.2 5000 typ host';
      const v6 = 'candidate:b 1 udp 1 2001:4860:4860::8888 5001 typ host';
      expect(isIpv6Candidate(v4), isFalse);
      expect(isIpv6Candidate(v6), isTrue);
      final sdp = 'v=0\r\na=fingerprint:sha-256 ABCD\r\na=$v4\r\na=$v6\r\n';
      final filtered = ipv6OnlySdp(sdp);
      expect(filtered, isNot(contains('192.168.1.2')));
      expect(filtered, contains('a=fingerprint:sha-256 ABCD'));
      expect(filtered, contains('a=$v6'));
      expect(
        isIpv6OnlyInvitation([Uri.parse('wss://127.0.0.1:8790/ws')]),
        isFalse,
      );
    },
  );
}
