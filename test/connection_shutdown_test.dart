import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:line/core/connection.dart';
import 'package:line/core/local_room_server.dart';
import 'package:line/core/room_invitation.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // These tests use a real local TLS listener.
  const methods = MethodChannel('FlutterWebRTC.Method');
  const events = MethodChannel(
    'FlutterWebRTC/peerConnectionEventshutdown-test',
  );
  final calls = <String>[];
  final iceConfigurations = <List<dynamic>>[];
  var refuseClose = false;
  var stallDispose = false;
  setUp(() {
    calls.clear();
    iceConfigurations.clear();
    refuseClose = false;
    stallDispose = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, (
      call,
    ) async {
      calls.add(call.method);
      switch (call.method) {
        case 'createPeerConnection':
          iceConfigurations.add(
            List<dynamic>.from(
              (call.arguments as Map)['configuration']['iceServers'],
            ),
          );
          return {'peerConnectionId': 'shutdown-test'};
        case 'peerConnectionClose':
          if (refuseClose) throw PlatformException(code: 'already-closed');
          return null;
        case 'peerConnectionDispose':
          if (stallDispose) await Completer<void>().future;
          return null;
        default:
          return null;
      }
    });
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });

  test(
    'failed handshake tears down once, disposing before native close',
    () async {
      final host = await LocalRoomServer.start(port: 0);
      final link = LineConnection();
      try {
        final invitation = RoomInvitation(
          room: host.room,
          fingerprint: '0' * 64,
          addresses: [host.loopback],
          expires: host.expires,
        );
        await link.join(LineSettings(), invitation.encode(), '12345678');
        expect(link.phase, LinkPhase.error);
        await Future.wait([link.close(), link.close()])
            .timeout(const Duration(seconds: 4));
        final teardown = calls.where(
          (c) => c == 'peerConnectionDispose' || c == 'peerConnectionClose',
        );
        expect(teardown, ['peerConnectionDispose', 'peerConnectionClose']);
        if (Platform.isWindows) {
          expect(iceConfigurations.single, hasLength(8));
          expect(
            iceConfigurations.single.every(
              (entry) =>
                  entry['urls'] == '' &&
                  entry['username'] == '' &&
                  entry['credential'] == '',
            ),
            isTrue,
          );
        }
      } finally {
        await host.close();
        link.dispose();
      }
    },
  );

  test('a native close error cannot prevent session shutdown', () async {
    final host = await LocalRoomServer.start(port: 0);
    final link = LineConnection();
    try {
      refuseClose = true;
      await link.join(
        LineSettings(),
        RoomInvitation(
          room: host.room,
          fingerprint: '0' * 64,
          addresses: [host.loopback],
          expires: host.expires,
        ).encode(),
        '12345678',
      );
      await link.close().timeout(const Duration(seconds: 4));
      expect(calls.where((c) => c == 'peerConnectionDispose'), hasLength(1));
    } finally {
      await host.close();
      link.dispose();
    }
  });

  test(
    'a stalled native dispose still attempts close within a bounded time',
    () async {
      final host = await LocalRoomServer.start(port: 0);
      final link = LineConnection();
      try {
        stallDispose = true;
        await link.join(
          LineSettings(),
          RoomInvitation(
            room: host.room,
            fingerprint: '0' * 64,
            addresses: [host.loopback],
            expires: host.expires,
          ).encode(),
          '12345678',
        );
        await link.close().timeout(const Duration(seconds: 3));
        expect(calls.where((c) => c == 'peerConnectionClose'), hasLength(1));
      } finally {
        await host.close();
        link.dispose();
      }
    },
  );
}
