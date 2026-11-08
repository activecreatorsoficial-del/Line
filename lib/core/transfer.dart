import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

const chunkSize = 16 * 1024;
const windowSize = 256 * 1024;
const maxFiles = 50;

enum TransferPhase {
  idle,
  waitingApproval,
  transferring,
  complete,
  cancelled,
  error,
}

class TransferFile {
  TransferFile({
    required this.id,
    required this.name,
    required this.size,
    this.path,
  });
  final String id;
  final String name;
  final int size;
  String? path;
  int transferred = 0;
  bool verified = false;
  double get progress => size == 0 ? (verified ? 1 : 0) : transferred / size;
  Map<String, Object> toJson() => {'id': id, 'name': name, 'size': size};
}

class WireMessage {
  WireMessage.text(this.text) : bytes = null;
  WireMessage.binary(this.bytes) : text = null;
  final String? text;
  final Uint8List? bytes;
}

abstract class TransferWire {
  Stream<WireMessage> get messages;
  Future<void> send(WireMessage message);
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

String safeFileName(String name) {
  var result = name
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty || result == '.' || result == '..') result = 'file';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)',
    caseSensitive: false,
  ).hasMatch(result)) {
    result = '_$result';
  }
  // Keep room for suffixes and avoid breaking UTF-16 surrogate pairs.
  return String.fromCharCodes(result.runes.take(120));
}

String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// Ordered, reliable protocol. At most one 256 KiB window is in flight.
/// Every window is acknowledged after disk writes; completion follows SHA-256.
class TransferEngine extends ChangeNotifier {
  TransferEngine(
    this.wire, {
    required this.isSender,
    this.timeout = const Duration(seconds: 60),
  }) {
    _subscription = wire.messages.listen(
      _enqueue,
      onError: (Object e) => _fail('The connection was interrupted.'),
      onDone: () {
        if (!_terminal) _fail('The connection was interrupted.');
      },
    );
  }
  final TransferWire wire;
  final bool isSender;
  final Duration timeout;
  late final StreamSubscription<WireMessage> _subscription;
  List<TransferFile> files = [];
  TransferPhase phase = TransferPhase.idle;
  String? error;
  String? destination;
  double bytesPerSecond = 0;
  final Stopwatch _clock = Stopwatch();
  int _lastNotify = 0;
  int _pendingBytes = 0;
  Future<void> _queue = Future.value();
  Future<void>? _cleanup;
  final Map<String, Completer<Map<String, dynamic>>> _waiters = {};
  RandomAccessFile? _output;
  File? _partial;
  TransferFile? _current;
  ByteConversionSink? _hash;
  _DigestSink? _digest;
  int _nextFile = 0;
  bool _disposed = false;
  bool _stopped = false;
  bool get _terminal => _stopped || phase == TransferPhase.complete;
  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
  int get transferredBytes => files.fold(0, (sum, f) => sum + f.transferred);
  double get progress => totalBytes == 0
      ? (phase == TransferPhase.complete ? 1 : 0)
      : transferredBytes / totalBytes;

  void _notify({bool force = false}) {
    if (_disposed) return;
    final now = _clock.elapsedMilliseconds;
    if (now > 0) bytesPerSecond = transferredBytes * 1000 / now;
    if (force || now - _lastNotify >= 100) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  void _enqueue(WireMessage message) {
    if (_terminal) return;
    final length =
        message.bytes?.length ?? utf8.encode(message.text ?? '').length;
    _pendingBytes += length;
    if (_pendingBytes > 1024 * 1024 ||
        length > (message.bytes != null ? chunkSize : chunkSize - 1)) {
      _fail('The other device exceeded the transfer limits.');
      return;
    }
    _queue = _queue.then((_) async {
      try {
        if (!_terminal) await _handle(message);
      } catch (e) {
        _fail('Unable to receive the file: $e');
      } finally {
        _pendingBytes -= length;
      }
    });
  }

  Future<void> _control(Map<String, Object?> message) =>
      wire.send(WireMessage.text(jsonEncode(message)));

  Future<Map<String, dynamic>> _request(
    String key,
    Map<String, Object?> message,
  ) async {
    _checkActive();
    final completer = Completer<Map<String, dynamic>>();
    _waiters[key] = completer;
    try {
      await _control(message);
      final result = await completer.future.timeout(timeout);
      _checkActive();
      return result;
    } finally {
      _waiters.remove(key);
    }
  }

  void _checkActive() {
    if (_terminal) throw StateError('Transfer ended.');
  }

  Future<void> offer(List<TransferFile> selected) async {
    if (!isSender || phase != TransferPhase.idle) {
      throw StateError('Invalid state.');
    }
    files = selected;
    final manifest = {
      'type': 'manifest',
      'version': 1,
      'files': files.map((f) => f.toJson()).toList(),
    };
    if (files.isEmpty ||
        files.length > maxFiles ||
        utf8.encode(jsonEncode(manifest)).length >= chunkSize) {
      _fail('Select between 1 and $maxFiles files with shorter names.');
      return;
    }
    phase = TransferPhase.waitingApproval;
    _notify(force: true);
    try {
      await _control(manifest);
    } catch (_) {
      _fail('Unable to send the file list.');
    }
  }

  Future<void> accept(String baseDirectory) async {
    if (isSender || phase != TransferPhase.waitingApproval) return;
    try {
      final session =
          'Line-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
      final directory = await Directory(p.join(baseDirectory, session))
          .create(recursive: true);
      if (_terminal) return;
      destination = directory.path;
      final names = <String>{};
      for (final file in files) {
        final clean = safeFileName(file.name);
        var unique = clean;
        var suffix = 1;
        while (!names.add(unique.toLowerCase())) {
          unique =
              '${p.basenameWithoutExtension(clean)} (${suffix++})${p.extension(clean)}';
        }
        file.path = p.join(destination!, unique);
      }
      phase = TransferPhase.transferring;
      _clock.start();
      _notify(force: true);
      await _control({'type': 'accept'});
    } catch (_) {
      _fail(
        'Unable to write to the selected folder. Check available space and permissions.',
      );
    }
  }

  Future<void> _handle(WireMessage message) async {
    if (message.bytes != null) {
      await _receiveBytes(message.bytes!);
      return;
    }
    final decoded = jsonDecode(message.text!);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid message.');
    }
    final msg = decoded;
    final type = msg['type'];
    if (type == 'cancel') {
      _stop(TransferPhase.cancelled);
      return;
    }
    if (type == 'error') {
      _fail(
        'The other device could not complete the transfer.',
        tellPeer: false,
      );
      return;
    }
    if (isSender) {
      if (type == 'accept' && phase == TransferPhase.waitingApproval) {
        phase = TransferPhase.transferring;
        _clock.start();
        _notify(force: true);
        unawaited(_sendAll());
        return;
      }
      if (type == 'ack') {
        final key = msg['key'];
        if (key is String && _waiters.containsKey(key)) {
          _waiters[key]!.complete(msg);
        }
        return;
      }
      throw const FormatException('Unexpected response.');
    }
    switch (type) {
      case 'manifest':
        if (phase != TransferPhase.idle || msg['version'] != 1) {
          throw const FormatException('Invalid version.');
        }
        final list = msg['files'];
        if (list is! List || list.isEmpty || list.length > maxFiles) {
          throw const FormatException('Invalid file list.');
        }
        final ids = <String>{};
        files = list.map((item) {
          if (item is! Map ||
              item['id'] is! String ||
              !RegExp(r'^\d{1,3}$').hasMatch(item['id']) ||
              !ids.add(item['id']) ||
              item['name'] is! String ||
              (item['name'] as String).length > 255 ||
              item['size'] is! int ||
              item['size'] < 0 ||
              item['size'] > 8 * 1024 * 1024 * 1024 * 1024) {
            throw const FormatException('Invalid metadata.');
          }
          return TransferFile(
            id: item['id'],
            name: item['name'],
            size: item['size'],
          );
        }).toList();
        phase = TransferPhase.waitingApproval;
        _notify(force: true);
      case 'begin':
        if (phase != TransferPhase.transferring ||
            _current != null ||
            _nextFile >= files.length ||
            msg['id'] != files[_nextFile].id) {
          throw const FormatException('Invalid file order.');
        }
        _current = files[_nextFile];
        _partial = File(p.join(destination!, '.line-${_current!.id}.part'));
        _output = await _partial!.open(mode: FileMode.writeOnly);
        _digest = _DigestSink();
        _hash = sha256.startChunkedConversion(_digest!);
        await _control({'type': 'ack', 'key': 'begin:${_current!.id}'});
      case 'end':
        final file = _current;
        if (file == null ||
            msg['id'] != file.id ||
            file.transferred != file.size) {
          throw const FormatException('Incorrect file size.');
        }
        _hash!.close();
        if (msg['sha256'] != _digest!.value.toString()) {
          throw const FormatException('SHA-256 verification failed.');
        }
        await _output!.flush();
        await _output!.close();
        _output = null;
        await _partial!.rename(file.path!);
        _partial = null;
        file.verified = true;
        _current = null;
        _nextFile++;
        await _control({'type': 'ack', 'key': 'end:${file.id}'});
        _notify(force: true);
      case 'done':
        if (_nextFile != files.length || !files.every((f) => f.verified)) {
          throw const FormatException('Incomplete transfer.');
        }
        await _control({'type': 'ack', 'key': 'done'});
        phase = TransferPhase.complete;
        _clock.stop();
        _notify(force: true);
      default:
        throw const FormatException('Unexpected command.');
    }
  }

  Future<void> _receiveBytes(Uint8List bytes) async {
    final file = _current;
    if (isSender ||
        phase != TransferPhase.transferring ||
        file == null ||
        bytes.isEmpty ||
        file.transferred + bytes.length > file.size) {
      throw const FormatException('Invalid chunk.');
    }
    await _output!.writeFrom(bytes);
    _hash!.add(bytes);
    file.transferred += bytes.length;
    if (file.transferred % windowSize == 0 || file.transferred == file.size) {
      await _control({
        'type': 'ack',
        'key': 'bytes:${file.id}:${file.transferred}',
      });
    }
    _notify();
  }

  Future<void> _sendAll() async {
    try {
      for (final file in files) {
        _checkActive();
        final input = await File(file.path!).open();
        try {
          if (await input.length() != file.size) {
            throw StateError('The file has changed since it was selected.');
          }
          await _request('begin:${file.id}', {'type': 'begin', 'id': file.id});
          final digest = _DigestSink();
          final hash = sha256.startChunkedConversion(digest);
          var offset = 0;
          while (offset < file.size) {
            _checkActive();
            final target = min(offset + windowSize, file.size);
            final key = 'bytes:${file.id}:$target';
            final ack = Completer<Map<String, dynamic>>();
            _waiters[key] = ack;
            try {
              while (offset < target) {
                _checkActive();
                final bytes = await input.read(min(chunkSize, target - offset));
                if (bytes.isEmpty) {
                  throw StateError(
                    'The file was truncated during the transfer.',
                  );
                }
                hash.add(bytes);
                await wire.send(WireMessage.binary(bytes));
                offset += bytes.length;
              }
              await ack.future.timeout(timeout);
            } finally {
              _waiters.remove(key);
            }
            _checkActive();
            file.transferred = target;
            _notify();
          }
          hash.close();
          await _request('end:${file.id}', {
            'type': 'end',
            'id': file.id,
            'sha256': digest.value.toString(),
          });
          file.verified = true;
          _notify(force: true);
        } finally {
          await input.close();
        }
      }
      await _request('done', {'type': 'done'});
      phase = TransferPhase.complete;
      _clock.stop();
      _notify(force: true);
    } catch (e) {
      if (!_stopped) {
        _fail(
          e is TimeoutException
              ? 'The other device stopped responding.'
              : 'Unable to send: $e',
        );
      }
    }
  }

  Future<void> cancel() async {
    if (_terminal) return;
    _stop(TransferPhase.cancelled);
    try {
      await _control({'type': 'cancel'});
    } catch (_) {}
  }

  void _fail(String message, {bool tellPeer = true}) {
    if (_terminal) return;
    error = message;
    if (tellPeer) {
      unawaited(_control({'type': 'error'}).catchError((Object _) {}));
    }
    _stop(TransferPhase.error);
  }

  void _stop(TransferPhase next) {
    if (_stopped) return;
    _stopped = true;
    phase = next;
    _clock.stop();
    // Complete pending waits normally, then _checkActive aborts the sender.
    // This avoids an unhandled Future error while native send is still pending.
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.complete({});
    }
    _cleanup = _queue.then((_) => _cleanPartial());
    _notify(force: true);
  }

  Future<void> _cleanPartial() async {
    final output = _output;
    _output = null;
    await output?.close();
    final partial = _partial;
    _partial = null;
    if (partial != null && await partial.exists()) await partial.delete();
  }

  Future<void> shutdown() async {
    if (!_terminal) _stop(TransferPhase.cancelled);
    await _subscription.cancel();
    await _queue;
    // Await the same cleanup; concurrent closes must not race the deletion.
    await (_cleanup ??= _cleanPartial());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
