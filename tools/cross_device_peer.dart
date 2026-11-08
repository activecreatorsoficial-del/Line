// Native Windows/Android regression harness. Never used by the release entrypoint.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:line/core/connection.dart';
import 'package:line/core/room_invitation.dart';
import 'package:line/core/transfer.dart';

Future<void> until(bool Function() condition, LineConnection link) async {
  final deadline = DateTime.now().add(const Duration(seconds: 150));
  while (!condition()) {
    if (link.phase == LinkPhase.error ||
        link.transfer?.phase == TransferPhase.error) {
      throw StateError(
        '${link.error ?? link.transfer?.error}\n${link.connectionAttempts.map((a) => a.description).join('\n')}',
      );
    }
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Cross-device operation timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Line cross-device test'))),
    ),
  );
  final root = Platform.isAndroid
      ? Directory(
          p.join((await getApplicationSupportDirectory()).path, 'line-lab'),
        )
      : Directory(const String.fromEnvironment('LINE_LAB_DIR'));
  await root.create(recursive: true);
  final config = jsonDecode(
    await File(p.join(root.path, 'config.json')).readAsString(),
  ) as Map<String, dynamic>;
  final id = config['id'] as String;
  if (!RegExp(r'^[a-zA-Z0-9-]{1,64}$').hasMatch(id)) {
    throw StateError('Invalid test ID');
  }
  final link = LineConnection();
  final data = Directory(p.join(root.path, id));
  await data.create(recursive: true);
  var status = <String, Object?>{
    'id': id,
    'platform': Platform.operatingSystem,
    'role': config['role'],
  };
  try {
    if (config['role'] == 'host') {
      final file = File(p.join(data.path, 'fixture.bin'));
      final output = file.openWrite();
      final bytes = Uint8List.fromList(List.generate(65536, (i) => i % 251));
      for (var i = 0; i < 128; i++) {
        output.add(bytes);
      }
      await output.close();
      final hash = (await sha256.bind(file.openRead()).first).toString();
      await link.host(
        LineSettings(
          listenPort: config['port'] as int,
          internetHosting: config['internet'] == true,
        ),
        [
          TransferFile(
            id: '0',
            name: 'fixture.bin',
            size: await file.length(),
            path: file.path,
          ),
        ],
      );
      await until(() => link.phase == LinkPhase.waiting, link);
      await File(p.join(root.path, 'offer.json')).writeAsString(
        jsonEncode({
          'id': id,
          'invitation': link.invitation,
          'code': link.code,
          'hash': hash,
        }),
      );
      if (config['internet'] == true) {
        Map<String, dynamic>? response;
        await until(() {
          try {
            final value = jsonDecode(
              File(p.join(root.path, 'response.json')).readAsStringSync(),
            ) as Map<String, dynamic>;
            if (value['id'] == id) {
              response = value;
              return true;
            }
          } catch (_) {}
          return false;
        }, link);
        await link.applyAnswer(response!['response'] as String);
      }
      await until(() => link.transfer?.phase == TransferPhase.complete, link);
      await until(() => !link.isRoomServerRunning, link);
      status.addAll({
        'passed': true,
        'bytes': link.transfer!.transferredBytes,
        'hash': hash,
        'safety': link.safetyCode,
        'listenerClosed': !link.isRoomServerRunning,
      });
    } else {
      Map<String, dynamic>? offer;
      await until(() {
        final file = File(p.join(root.path, 'offer.json'));
        if (!file.existsSync()) return false;
        try {
          final value =
              jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          if (value['id'] == id) {
            offer = value;
            return true;
          }
        } catch (_) {}
        return false;
      }, link);
      var invitation = offer!['invitation'] as String;
      if (config['internet'] != true && config['addressOverride'] is String) {
        final parsed = RoomInvitation.parse(invitation);
        // Explicit lab route through the emulator boundary; TLS pin is preserved.
        invitation = RoomInvitation(
          room: parsed.room,
          fingerprint: parsed.fingerprint,
          addresses: [Uri.parse(config['addressOverride'])],
          expires: parsed.expires,
        ).encode();
      }
      await link.join(LineSettings(), invitation, offer!['code'] as String);
      if (config['internet'] == true) {
        if (link.phase != LinkPhase.waiting || !link.isExchange) {
          throw StateError(link.error ?? 'No connection response');
        }
        await File(p.join(root.path, 'response.json'))
            .writeAsString(jsonEncode({'id': id, 'response': link.invitation}));
      }

      await until(
        () => link.transfer?.phase == TransferPhase.waitingApproval,
        link,
      );
      await link.transfer!.accept(p.join(data.path, 'received'));
      await until(() => link.transfer?.phase == TransferPhase.complete, link);
      final file = File(link.transfer!.files.single.path!);
      final hash = (await sha256.bind(file.openRead()).first).toString();
      if (hash != offer!['hash'] || await file.length() != 8 * 1024 * 1024) {
        throw StateError('Cross-device file integrity mismatch');
      }
      status.addAll({
        'passed': true,
        'bytes': await file.length(),
        'hash': hash,
        'safety': link.safetyCode,
      });
    }
  } catch (e) {
    status.addAll({'passed': false, 'error': e.toString()});
  } finally {
    status['relays'] = link.relayCandidates;
    status['reflexive'] = link.reflexiveCandidates;
    status['exchange'] = link.isExchange;
    await link.close();
    link.dispose();
    await File(p.join(root.path, 'result.json'))
        .writeAsString(jsonEncode(status));
  }
  exit(status['passed'] == true ? 0 : 1);
}
