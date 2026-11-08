import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:line/core/connection.dart';
import 'package:line/core/transfer.dart';
import 'package:path/path.dart' as p;

class MemoryWire implements TransferWire {
  final controller = StreamController<WireMessage>();
  late MemoryWire peer;
  bool corrupt = false;
  Completer<void>? sendGate;
  int maxMessage = 0;
  @override
  Stream<WireMessage> get messages => controller.stream;
  @override
  Future<void> send(WireMessage message) async {
    await sendGate?.future;
    if (message.bytes != null) {
      maxMessage = message.bytes!.length > maxMessage
          ? message.bytes!.length
          : maxMessage;
      if (corrupt) {
        corrupt = false;
        final changed = Uint8List.fromList(message.bytes!);
        changed[0] ^= 1;
        peer.controller.add(WireMessage.binary(changed));
        return;
      }
    }
    peer.controller.add(message);
  }
}

Future<void> until(bool Function() check) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!check()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Condition did not become true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory temp;
  late MemoryWire left;
  late MemoryWire right;
  late TransferEngine sender;
  late TransferEngine receiver;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('line-test-');
    left = MemoryWire();
    right = MemoryWire();
    left.peer = right;
    right.peer = left;
    sender = TransferEngine(left, isSender: true);
    receiver = TransferEngine(right, isSender: false);
  });
  tearDown(() async {
    await sender.shutdown();
    await receiver.shutdown();
    sender.dispose();
    receiver.dispose();
    await left.controller.close();
    await right.controller.close();
    await temp.delete(recursive: true);
  });

  Future<TransferFile> source(String name, int size, String id) async {
    final file = File(p.join(temp.path, 'source-$id'));
    final data = Uint8List.fromList(
      List.generate(size, (i) => (i * 31 + 7) % 256),
    );
    await file.writeAsBytes(data);
    return TransferFile(id: id, name: name, size: size, path: file.path);
  }

  test(
    'binary windows stream to disk; empty files and duplicate names verify',
    () async {
      final files = [
        await source('recording.mp4', windowSize * 5 + 171, '0'),
        await source('empty.txt', 0, '1'),
        await source('recording.mp4', 97, '2'),
      ];
      await sender.offer(files);
      await until(() => receiver.phase == TransferPhase.waitingApproval);
      expect(receiver.destination, isNull); // No disk writes before acceptance.
      await receiver.accept(p.join(temp.path, 'received'));
      await until(() => sender.phase == TransferPhase.complete);
      expect(receiver.phase, TransferPhase.complete);
      expect(receiver.files.every((f) => f.verified), isTrue);
      expect(receiver.files[0].path, isNot(receiver.files[2].path));
      for (var i = 0; i < files.length; i++) {
        expect(
          await File(receiver.files[i].path!).readAsBytes(),
          await File(files[i].path!).readAsBytes(),
        );
      }
      expect(left.maxMessage, lessThanOrEqualTo(chunkSize));
      expect(sender.progress, 1);
      expect(
        await Directory(receiver.destination!)
            .list()
            .where((f) => f.path.endsWith('.part'))
            .length,
        0,
      );
    },
  );

  test('corruption fails SHA-256; partial data is removed', () async {
    left.corrupt = true;
    await sender.offer([await source('../../unsafe.bin', chunkSize + 37, '0')]);
    await until(() => receiver.phase == TransferPhase.waitingApproval);
    await receiver.accept(p.join(temp.path, 'received'));
    await until(() => receiver.phase == TransferPhase.error);
    await until(() => sender.phase == TransferPhase.error);
    await receiver.shutdown();
    expect(receiver.error, contains('SHA-256'));
    expect(await Directory(receiver.destination!).list().length, 0);
  });

  test(
    'receiver cancels without sending data or creating a destination',
    () async {
      await sender.offer([await source('private.bin', 100, '0')]);
      await until(() => receiver.phase == TransferPhase.waitingApproval);
      await receiver.cancel();
      await until(() => sender.phase == TransferPhase.cancelled);
      expect(sender.transferredBytes, 0);
      expect(receiver.destination, isNull);
    },
  );

  test('filenames cannot traverse paths or use Windows device names', () {
    expect(safeFileName('../../etc/passwd'), 'passwd');
    expect(safeFileName(r'C:\Windows\system.ini'), 'system.ini');
    expect(safeFileName('CON.txt'), '_CON.txt');
    expect(safeFileName('..'), 'file');
    expect(safeFileName('a<>:*?.txt'), 'a_____.txt');
  });

  test('cancellation stops locally before the remote send completes', () async {
    await sender.offer([await source('private.bin', 100, '0')]);
    await until(() => receiver.phase == TransferPhase.waitingApproval);
    final gate = left.sendGate = Completer<void>();
    final cancelled = sender.cancel();
    expect(sender.phase, TransferPhase.cancelled);
    expect(sender.transferredBytes, 0);
    gate.complete();
    await cancelled;
  });

  test(
    'host settings validate the listening port and optional public address',
    () {
      expect(LineSettings().validate(), isNull);
      expect(LineSettings(listenPort: 80).validate(), isNotNull);
      expect(
        LineSettings(publicAddress: 'ws://example.com/ws').validate(),
        isNotNull,
      );
      expect(
        LineSettings(publicAddress: 'example.org:8790').validate(),
        isNull,
      );
      expect(
        LineSettings(publicAddress: 'wss://example.org/ws').validate(),
        isNull,
      );
      expect(LineSettings(turn: 'turn:example.org').validate(), isNotNull);
    },
  );
}
