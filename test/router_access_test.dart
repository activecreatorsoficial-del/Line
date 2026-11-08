import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:line/core/router_access.dart';
import 'package:line/core/connection.dart';

import 'support/mock_router.dart';

void main() {
  test(
    'an inactive WAN service does not hide another usable service',
    () async {
      final mock = await MockRouter.start()
        ..inactiveFirst = true;
      RouterAccess? access;
      try {
        access = await RouterAccess.fromDescription(
          mock.description,
          InternetAddress.loopbackIPv4,
        );
        expect(access.publicAddress.address, mock.wan);
        expect(
          mock.actions.where((a) => a == 'GetExternalIPAddress').length,
          2,
        );
      } finally {
        await access?.close();
        await mock.close();
      }
    },
  );

  test(
    'hosting reports a gateway failure without a room or external connection',
    () async {
      final link = LineConnection(
        discoverRouter: () async =>
            throw RouterAccessException('No public route'),
      );
      try {
        await link.hostDirect(
          LineSettings(listenPort: 18799, internetHosting: true),
          [],
        );
        expect(link.phase, LinkPhase.error);
        expect(link.error, 'No public route');
        expect(link.invitation, isNull);
        await link.close();
        expect(link.isRoomServerRunning, isFalse);
      } finally {
        await link.close();
        link.dispose();
      }
    },
  );

  test('cancelling discovery cannot open a late router mapping', () async {
    final mock = await MockRouter.start();
    final found = Completer<RouterRoute>();
    final discovering = Completer<void>();
    final link = LineConnection(
      discoverRouter: () {
        discovering.complete();
        return found.future;
      },
    );
    try {
      final hosting = link.hostDirect(
        LineSettings(listenPort: 18799, internetHosting: true),
        [],
      );
      await discovering.future;
      await link.close();
      found.complete(
        await RouterAccess.fromDescription(
          mock.description,
          InternetAddress.loopbackIPv4,
        ),
      );
      await hosting;
      expect(mock.adds, 0);
      expect(link.invitation, isNull);
    } finally {
      await link.close();
      link.dispose();
      await mock.close();
    }
  });

  Future<RouterAccess> connect(MockRouter mock) => RouterAccess.fromDescription(
    mock.description,
    InternetAddress.loopbackIPv4,
  );

  test(
    'temporary TCP and UDP mappings renew and have separate lifetimes',
    () async {
      final mock = await MockRouter.start();
      final access = await connect(mock);
      try {
        final endpoint = await access.openRoom(8790);
        expect(endpoint.host, mock.wan);
        expect(endpoint.scheme, 'wss');
        final candidate = await access.mapCandidate(
          'candidate:a 1 udp 1 127.0.0.1 50123 typ host',
        );
        expect(candidate, contains(mock.wan));
        expect(mock.entries.length, 2);
        expect(
          mock.entries.values.every((e) => e['NewLeaseDuration'] == '600'),
          isTrue,
        );
        await access.mapCandidate(
          'candidate:a 1 udp 1 127.0.0.1 50123 typ host',
        );
        expect(
          mock.adds,
          2,
          reason: 'Same UDP socket must not create duplicate rules',
        );
        await access.renew();
        expect(mock.adds, 4);
        await access.closeRoomPort();
        expect(mock.entries.keys.single, startsWith('UDP:'));
        await access.close();
        expect(mock.entries, isEmpty);
      } finally {
        await access.close();
        await mock.close();
      }
    },
  );

  test(
    'CGNAT and private WANs are refused before any port is opened',
    () async {
      final mock = await MockRouter.start();
      try {
        for (final ip in ['100.64.1.2', '192.168.0.20', '10.0.0.2']) {
          mock.wan = ip;
          await expectLater(
            connect(mock),
            throwsA(isA<RouterAccessException>()),
          );
        }
        expect(mock.adds, 0);
      } finally {
        await mock.close();
      }
    },
  );

  test('a permanent lease is rejected and immediately removed', () async {
    final mock = await MockRouter.start()
      ..permanentLeases = true;
    final access = await connect(mock);
    try {
      await expectLater(
        access.openRoom(8790),
        throwsA(isA<RouterAccessException>()),
      );
      expect(mock.deletes, 1);
      expect(mock.entries, isEmpty);
    } finally {
      await access.close();
      await mock.close();
    }
  });

  test(
    'existing mappings are skipped and foreign mappings are never removed',
    () async {
      final mock = await MockRouter.start()
        ..occupyNextLookup = true;
      final access = await connect(mock);
      try {
        await access.openRoom(8790);
        expect(mock.entries.length, 2);
        expect(mock.adds, 1);
        await access.close();
        expect(
          mock.entries.values.single['NewPortMappingDescription'],
          'Other application',
        );
      } finally {
        await access.close();
        await mock.close();
      }
    },
  );

  test('renewal refuses to overwrite a mapping another app now owns', () async {
    final mock = await MockRouter.start();
    final access = await connect(mock);
    try {
      await access.openRoom(8790);
      mock.entries.values.single['NewPortMappingDescription'] =
          'Other application';
      await expectLater(access.renew(), throwsA(isA<RouterAccessException>()));
      expect(mock.adds, 1);
      await access.close();
      expect(mock.deletes, 0);
    } finally {
      await access.close();
      await mock.close();
    }
  });

  test(
    'cancellation during router startup cleans the created mapping',
    () async {
      final mock = await MockRouter.start()
        ..pauseAdd = Completer<void>();
      final access = await connect(mock);
      try {
        final opening = access.openRoom(8790);
        final checked = expectLater(
          opening,
          throwsA(isA<RouterAccessException>()),
        );
        await mock.addStarted.future;
        final closing = access.close();
        mock.pauseAdd!.complete();
        await checked;
        await closing;
        expect(mock.entries, isEmpty);
      } finally {
        await access.close();
        await mock.close();
      }
    },
  );

  test('external control URLs and redirects are not followed', () async {
    final mock = await MockRouter.start();
    try {
      mock.controlUrl = 'http://8.8.8.8/control';
      await expectLater(connect(mock), throwsA(isA<RouterAccessException>()));
      expect(mock.actions, isEmpty);
      mock.redirectDescription = true;
      await expectLater(connect(mock), throwsA(isA<FormatException>()));
      expect(mock.actions, isEmpty);
    } finally {
      await mock.close();
    }
  });

  test('SSDP discovery accepts only the responding local gateway', () async {
    final mock = await MockRouter.start();
    final ssdp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    ssdp.listen((event) {
      if (event != RawSocketEvent.read) return;
      final request = ssdp.receive();
      if (request != null) {
        ssdp.send(
          ascii.encode(
            'HTTP/1.1 200 OK\r\nLOCATION: ${mock.description}\r\n\r\n',
          ),
          request.address,
          request.port,
        );
      }
    });
    RouterAccess? access;
    try {
      access = await RouterAccess.discover(
        localAddresses: [InternetAddress.loopbackIPv4],
        searchAddress: InternetAddress.loopbackIPv4,
        searchPort: ssdp.port,
        searchTime: const Duration(milliseconds: 100),
      );
      expect(access.publicAddress.address, mock.wan);
    } finally {
      await access?.close();
      ssdp.close();
      await mock.close();
    }
  });

  test(
    'unconfirmed cleanup of a permanent rule produces an actionable error',
    () async {
      final mock = await MockRouter.start()
        ..permanentLeases = true
        ..refuseDelete = true;
      final access = await connect(mock);
      try {
        await expectLater(
          access.openRoom(8790),
          throwsA(
            isA<RouterAccessException>().having(
              (e) => e.message,
              'message',
              contains('cleanup'),
            ),
          ),
        );
        expect(mock.entries.length, 1);
      } finally {
        await access.close();
        await mock.close();
      }
    },
  );

  test('only globally routable IPv4 is advertised for internet hosting', () {
    for (final ip in [
      '10.0.0.1',
      '172.16.0.1',
      '192.168.1.1',
      '100.64.0.1',
      '100.127.255.254',
      '127.0.0.1',
      '169.254.1.1',
      '0.0.0.0',
      '192.0.2.1',
      '198.51.100.1',
      '203.0.113.1',
      '224.0.0.1',
    ]) {
      expect(isPublicV4(InternetAddress(ip)), isFalse, reason: ip);
    }
    expect(isPublicV4(InternetAddress('8.8.8.8')), isTrue);
    expect(isPublicV4(InternetAddress('::1')), isFalse);
  });

  test('mapped ICE candidates preserve component and related address', () {
    final candidate = HostUdpCandidate.parse(
      'candidate:12345 1 udp 2122260223 192.168.1.20 50123 typ host generation 0',
    );
    expect(candidate, isNotNull);
    expect(
      candidate!.mapped('8.8.8.8', 55000),
      'candidate:line12345 1 udp 1694498815 8.8.8.8 55000 typ srflx raddr 192.168.1.20 rport 50123',
    );
    expect(
      HostUdpCandidate.parse('candidate:a 1 tcp 1 192.168.1.20 9 typ host'),
      isNull,
    );
    expect(
      HostUdpCandidate.parse('candidate:a 1 udp 1 ::1 5000 typ host'),
      isNull,
    );
    expect(
      HostUdpCandidate.parse('candidate:a 1 udp 1 8.8.8.8 5000 typ srflx'),
      isNull,
    );
  });
}
