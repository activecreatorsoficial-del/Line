import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:line/core/local_room_server.dart';
import 'package:line/core/room_invitation.dart';

class TestPeer {
  TestPeer(this.socket, this.client) : events = StreamIterator(socket);
  final WebSocket socket;
  final HttpClient client;
  final StreamIterator<dynamic> events;
  void send(Map<String, Object?> message) => socket.add(jsonEncode(message));
  Future<Map<String, dynamic>> next() async {
    if (!await events.moveNext().timeout(const Duration(seconds: 8))) {
      throw StateError('The room socket closed unexpectedly.');
    }
    return jsonDecode(events.current as String) as Map<String, dynamic>;
  }

  Future<void> close() async {
    await events.cancel();
    unawaited(socket.close());
    client.close(force: true);
  }
}

Future<TestPeer> connect(LocalRoomServer host) async {
  final client = pinnedRoomClient(host.fingerprint);
  final socket = await WebSocket.connect(
    host.loopback.toString(),
    customClient: client,
    compression: CompressionOptions.compressionOff,
    maxPayloadLength: 64 * 1024,
  );
  return TestPeer(socket, client);
}

void main() {
  test('invitation carries host addresses and identity, rejects insecure or expired input', () {
    final source = RoomInvitation(
      room: 'LINE-A1B2C3D4',
      fingerprint: 'a' * 64,
      addresses: [Uri.parse('wss://192.168.1.8:8790/ws')],
      expires: DateTime.now().add(const Duration(minutes: 10)),
    );
    final parsed = RoomInvitation.parse(source.encode());
    expect(parsed.room, source.room);
    expect(parsed.fingerprint, source.fingerprint);
    expect(parsed.addresses, source.addresses);
    expect(source.encode(), isNot(contains('password')));
    expect(() => RoomInvitation.parse('LINE-A1B2C3D4'), throwsFormatException);
    expect(
      () => RoomInvitation.parse(
        RoomInvitation(
          room: source.room,
          fingerprint: source.fingerprint,
          addresses: [Uri.parse('ws://example.org/ws')],
          expires: source.expires,
        ).encode(),
      ),
      throwsFormatException,
    );
    expect(
      () => RoomInvitation.parse(
        RoomInvitation(
          room: source.room,
          fingerprint: source.fingerprint,
          addresses: source.addresses,
          expires: DateTime.now().subtract(const Duration(seconds: 1)),
        ).encode(),
      ),
      throwsFormatException,
    );
  });

  test('self-hosted TLS room authenticates two peers, routes signaling and shuts down after ready', () async {
    final host = await LocalRoomServer.start(port: 0);
    final owner = await connect(host);
    final guest = await connect(host);
    try {
      owner.send({'type': 'create', 'owner': host.ownerToken});
      final created = await owner.next();
      expect(created['room'], matches(r'^LINE-[A-F0-9]{8}$'));
      expect(created['code'], matches(r'^\d{8}$'));
      final invite = await host.invitation();
      expect(RoomInvitation.parse(invite.encode()).addresses, isNotEmpty);
      guest.send({
        'type': 'join',
        'room': created['room'],
        'code': created['code'],
      });
      expect((await guest.next())['type'], 'joined');
      expect((await owner.next())['type'], 'peer-joined');
      guest.send({
        'type': 'signal',
        'data': {'type': 'offer', 'sdp': 'wrong role'},
      });
      expect((await guest.next())['type'], 'error');
      final third = await connect(host);
      try {
        third.send({
          'type': 'join',
          'room': created['room'],
          'code': created['code'],
        });
        expect((await third.next())['type'], 'error');
      } finally {
        await third.close();
      }
      owner.send({
        'type': 'signal',
        'data': {'type': 'offer', 'sdp': 'test offer'},
      });
      expect((await guest.next())['data']['sdp'], 'test offer');
      guest.send({
        'type': 'signal',
        'data': {'type': 'answer', 'sdp': 'test answer'},
      });
      expect((await owner.next())['data']['sdp'], 'test answer');
      owner.send({'type': 'ready'});
      guest.send({'type': 'ready'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.isClosed, isTrue);
    } finally {
      await host.close();
      await owner.close();
      await guest.close();
    }
  });

  test(
    'wrong TLS pin is rejected without taking the hosting device offline',
    () async {
      final host = await LocalRoomServer.start(port: 0);
      final wrong = pinnedRoomClient('0' * 64);
      try {
        await expectLater(
          WebSocket.connect(host.loopback.toString(), customClient: wrong),
          throwsA(isA<HandshakeException>()),
        );
        expect(host.isClosed, isFalse);
        final owner = await connect(host);
        try {
          owner.send({'type': 'create', 'owner': host.ownerToken});
          expect((await owner.next())['type'], 'created');
        } finally {
          await owner.close();
        }
      } finally {
        wrong.close(force: true);
        await host.close();
      }
    },
  );

  test(
    'room refuses wrong codes, unauthorized creation and binary uploads',
    () async {
      final host = await LocalRoomServer.start(port: 0);
      final owner = await connect(host);
      final other = await connect(host);
      try {
        other.send({'type': 'create', 'owner': 'invalid'});
        expect((await other.next())['type'], 'error');
        owner.send({'type': 'create', 'owner': host.ownerToken});
        final room = await owner.next();
        other.send({
          'type': 'join',
          'room': room['room'],
          'code': room['code'] == '00000000' ? '99999999' : '00000000',
        });
        expect((await other.next())['type'], 'error');
        expect(host.isClosed, isFalse);
        other.socket.add([1, 2, 3]);
        expect(
          await other.events.moveNext().timeout(const Duration(seconds: 3)),
          isFalse,
        );
        expect(other.socket.closeCode, 1008);
        expect(host.isClosed, isFalse);
      } finally {
        await host.close();
        await owner.close();
        await other.close();
      }
    },
  );

  test('local listener closes when its room expires', () async {
    final host = await LocalRoomServer.start(
      port: 0,
      ttl: const Duration(milliseconds: 150),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(host.isClosed, isTrue);
    await host.close();
  });
}
