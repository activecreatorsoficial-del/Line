import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:line/core/host_addresses.dart';
import 'package:line/core/host_connector.dart';
import 'package:line/core/local_room_server.dart';

void main() {
  test('Wi-Fi is retained ahead of many mobile and VPN interfaces', () {
    final interfaces = [
      for (var i = 0; i < 20; i++)
        HostInterface('rmnet_data$i', [InternetAddress('10.2.0.${i + 1}')]),
      HostInterface('tun0', [InternetAddress('10.8.0.1')]),
      HostInterface('wlan0', [InternetAddress('192.168.1.50')]),
      HostInterface('lo', [InternetAddress.loopbackIPv4]),
    ];
    final addresses = rankHostAddresses(interfaces, 8790, limit: 3);
    expect(addresses.first.host, '192.168.1.50');
    expect(addresses.length, 3);
    expect(addresses.any((a) => a.host == '127.0.0.1'), isFalse);
  });

  test('Android Wi-Fi addresses are used even when interface enumeration omits them', () {
    final addresses = rankHostAddresses(
      [],
      8790,
      wifiAddresses: ['192.168.1.55', 'fe80::1'],
    );
    expect(addresses.single.toString(), 'wss://192.168.1.55:8790/ws');
  });

  test(
    'a stalled route does not delay a working pinned Wi-Fi connection',
    () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <Socket>[];
      final subscription = silent.listen((socket) {
        accepted.add(socket);
        socket.listen((_) {}, onError: (Object _) {});
      });
      final host = await LocalRoomServer.start(port: 0);
      final connector = HostConnector(timeout: const Duration(seconds: 3));
      try {
        final clock = Stopwatch()..start();
        final connected = await connector.connect([
          Uri.parse('wss://127.0.0.1:${silent.port}/ws'),
          host.loopback,
        ], host.fingerprint);
        expect(connected.address, host.loopback);
        expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
        expect(connected.socket.readyState, WebSocket.open);
      } finally {
        connector.cancel();
        await host.close();
        for (final socket in accepted) {
          socket.destroy();
        }
        await subscription.cancel();
        await silent.close();
      }
    },
  );

  test(
    'certificate mismatch is reported explicitly and never accepted',
    () async {
      final host = await LocalRoomServer.start(port: 0);
      final connector = HostConnector();
      try {
        await expectLater(
          connector.connect([host.loopback], '0' * 64),
          throwsA(
            isA<HostDialException>().having(
              (e) => e.message,
              'message',
              contains('identity'),
            ),
          ),
        );
        expect(connector.attempts.single.failure, HostAttemptFailure.identity);
        expect(host.isClosed, isFalse);
      } finally {
        connector.cancel();
        await host.close();
      }
    },
  );

  test(
    'cancelling a pending handshake closes it and completes the operation',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <Socket>[];
      final subscription = server.listen((socket) {
        accepted.add(socket);
        socket.listen((_) {}, onError: (Object _) {});
      });
      final connector = HostConnector(timeout: const Duration(seconds: 2));
      final pending = connector.connect([
        Uri.parse('wss://127.0.0.1:${server.port}/ws'),
      ], '0' * 64);
      final checked = expectLater(pending, throwsA(isA<HostDialException>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      connector.cancel();
      await checked.timeout(const Duration(seconds: 3));
      for (final socket in accepted) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    },
  );
}
