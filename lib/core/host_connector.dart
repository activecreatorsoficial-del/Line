import 'dart:async';
import 'dart:io';

import 'local_room_server.dart';
import 'internet_route.dart';

enum HostAttemptFailure { timeout, refused, network, identity, tls, cancelled }

class HostAttempt {
  HostAttempt(this.address, this.failure, this.detail);
  final Uri address;
  final HostAttemptFailure failure;
  final String detail;
  String get description =>
      '${address.host}:${address.port} — ${failure.name}: $detail';
}

class HostDialException implements Exception {
  HostDialException(this.attempts);
  final List<HostAttempt> attempts;
  String get message {
    if (attempts.any((a) => a.failure == HostAttemptFailure.identity)) {
      return 'The host identity does not match this invitation. Copy a new invitation from the host.';
    }
    if (attempts.isNotEmpty &&
        attempts.every((a) => a.failure == HostAttemptFailure.refused)) {
      return 'The host is not accepting connections. Keep Line open on the host and copy a fresh invitation.';
    }
    if (isIpv6OnlyInvitation(attempts.map((a) => a.address).toList())) {
      return 'The IPv6 host did not answer. Both devices need IPv6 connectivity, and the host router or provider must allow incoming connections. Copy a fresh invitation and keep Line running.';
    }
    return 'The host did not answer. Keep its Wi-Fi connected, copy a fresh invitation and try again.';
  }

  @override
  String toString() => message;
}

class HostSocket {
  HostSocket(this.socket, this.client, this.address);
  final WebSocket socket;
  final HttpClient client;
  final Uri address;
}

/// Bounded, staggered attempts prevent an unusable IPv6/mobile route from
/// delaying the working Wi-Fi route. Only the winner receives a room code.
class HostConnector {
  HostConnector({this.timeout = const Duration(seconds: 4)});
  final Duration timeout;
  final attempts = <HostAttempt>[];
  final Set<HttpClient> _clients = {};
  final Set<WebSocket> _sockets = {};
  bool _cancelled = false;
  bool _finished = false;

  Future<HostSocket> connect(List<Uri> addresses, String fingerprint) async {
    final pending = List<Uri>.of(addresses.toSet());
    final originalOrder = {
      for (var i = 0; i < pending.length; i++) pending[i]: i,
    };
    // A loopback address from another device is never a useful first route.
    pending.sort((a, b) {
      int priority(Uri u) =>
          (u.host == 'localhost' ||
              (InternetAddress.tryParse(u.host)?.isLoopback ?? false))
          ? 2
          : InternetAddress.tryParse(u.host)?.type == InternetAddressType.IPv4
          ? 0
          : 1;
      final ranked = priority(a).compareTo(priority(b));
      return ranked != 0
          ? ranked
          : originalOrder[a]!.compareTo(originalOrder[b]!);
    });
    final completed = Completer<HostSocket>();
    var next = 0;
    Future<void> worker(int delay) async {
      if (delay > 0) await Future<void>.delayed(Duration(milliseconds: delay));
      while (!_finished && !_cancelled && next < pending.length) {
        final address = pending[next++];
        var identityMismatch = false;
        final client = pinnedRoomClient(
          fingerprint,
          onMismatch: () => identityMismatch = true,
        );
        _clients.add(client);
        var active = true;
        final opening = WebSocket.connect(
          address.toString(),
          customClient: client,
          compression: CompressionOptions.compressionOff,
          maxPayloadLength: 64 * 1024,
        );
        // A timed-out upgrade may finish later; do not leave its socket behind.
        unawaited(
          opening.then((socket) {
            if (!active) unawaited(socket.close());
          }, onError: (Object _) {}),
        );
        try {
          final socket = await opening.timeout(timeout);
          _sockets.add(socket);
          if (_finished || _cancelled) {
            unawaited(socket.close());
            break;
          }
          _finished = true;
          for (final other in _clients.where((c) => c != client).toList()) {
            other.close(force: true);
            _clients.remove(other);
          }
          completed.complete(HostSocket(socket, client, address));
          return;
        } catch (e) {
          HostAttemptFailure kind;
          if (identityMismatch) {
            kind = HostAttemptFailure.identity;
          } else if (e is TimeoutException) {
            kind = HostAttemptFailure.timeout;
          } else if (e is HandshakeException) {
            kind = HostAttemptFailure.tls;
          } else if (e is SocketException &&
              [61, 111, 10061].contains(e.osError?.errorCode)) {
            kind = HostAttemptFailure.refused;
          } else {
            kind = HostAttemptFailure.network;
          }
          if (!_finished && !_cancelled) {
            attempts.add(
              HostAttempt(
                address,
                kind,
                identityMismatch
                    ? 'Certificate fingerprint mismatch'
                    : e.toString(),
              ),
            );
          }
          client.close(force: true);
          _clients.remove(client);
        } finally {
          active = false;
        }
      }
    }

    unawaited(
      Future.wait([worker(0), worker(150), worker(300)]).then(
        (_) {
          if (!completed.isCompleted) {
            completed.completeError(HostDialException(List.of(attempts)));
          }
        },
        onError: (Object e, StackTrace stack) {
          if (!completed.isCompleted) completed.completeError(e, stack);
        },
      ),
    );
    return completed.future;
  }

  void cancel() {
    _cancelled = true;
    for (final socket in _sockets) {
      unawaited(socket.close());
    }
    for (final client in _clients) {
      client.close(force: true);
    }
    _sockets.clear();
    _clients.clear();
  }
}
