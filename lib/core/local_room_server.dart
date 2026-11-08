import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart'
    show
        ECPrivateKey,
        ECPublicKey,
        PBKDF2KeyDerivator,
        HMac,
        SHA256Digest,
        Pbkdf2Parameters;

import 'room_invitation.dart';
import 'host_addresses.dart';

String _randomHex(int length) {
  final random = Random.secure();
  return List.generate(
    length,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _passwordHash(String password, List<int> salt) {
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(salt), 65536, 32));
  return base64.encode(kdf.process(Uint8List.fromList(utf8.encode(password))));
}

bool _equal(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}

Future<String> _derivePasswordHash(String code, List<int> salt) =>
    Isolate.run(() => _passwordHash(code, salt));

Map<String, String> _createIdentity() {
  final keys = CryptoUtils.generateEcKeyPair();
  final privateKey = keys.privateKey as ECPrivateKey;
  final publicKey = keys.publicKey as ECPublicKey;
  final csr = X509Utils.generateEccCsrPem(
    {'CN': 'Line temporary room'},
    privateKey,
    publicKey,
  );
  final certificate = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csr,
    1,
    cA: false,
    extKeyUsage: [ExtendedKeyUsage.SERVER_AUTH],
    serialNumber: BigInt.parse(_randomHex(12), radix: 16).toString(),
    notBefore: DateTime.now().subtract(const Duration(minutes: 5)),
  );
  final der = base64.decode(
    certificate
        .split('\n')
        .where((line) => !line.startsWith('-----'))
        .join()
        .replaceAll(RegExp(r'\s'), ''),
  );
  final code = Random.secure().nextInt(100000000).toString().padLeft(8, '0');
  final salt = _randomHex(16);
  return {
    'key': CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
    'cert': certificate,
    'pin': sha256.convert(der).toString(),
    'room': 'LINE-${_randomHex(4).toUpperCase()}',
    'code': code,
    'owner': _randomHex(32),
    'salt': salt,
    'hash': _passwordHash(code, utf8.encode(salt)),
  };
}

class _RoomPeer {
  _RoomPeer(this.socket);
  final WebSocket socket;
  Timer? authenticationDeadline;
  bool authenticated = false;
  int messages = 0;
  DateTime window = DateTime.now();
}

/// One temporary room, entirely inside its hosting Windows/Android process.
/// Only JSON signaling is accepted; file bytes stay on the WebRTC channel.
class LocalRoomServer {
  LocalRoomServer._(this._server, this._identity, this.expires) {
    _expiry = Timer(expires.difference(DateTime.now()), () {
      unawaited(close('The room has expired. Create a new room.'));
    });
    // Failed unauthenticated TLS handshakes must not destroy a valid room.
    _server.listen(_request, onError: (Object _) {});
  }
  final HttpServer _server;
  final Map<String, String> _identity;
  final DateTime expires;
  final Set<_RoomPeer> _peers = {};
  final Set<_RoomPeer> _ready = {};
  _RoomPeer? _owner, _guest;
  late final Timer _expiry;
  bool _closed = false;
  bool get isClosed => _closed;
  int get port => _server.port;
  bool get supportsIpv6 => _server.address.type == InternetAddressType.IPv6;
  String get room => _identity['room']!;
  String get fingerprint => _identity['pin']!;
  String get ownerToken => _identity['owner']!;
  Uri get loopback =>
      Uri(scheme: 'wss', host: '127.0.0.1', port: port, path: '/ws');
  int _attempts = 0;
  int _upgrading = 0;
  int _pendingBytes = 0;
  Future<void> _queue = Future.value();

  static Future<LocalRoomServer> start({
    int port = 8790,
    Duration ttl = const Duration(minutes: 10),
  }) async {
    final identity = await Isolate.run(_createIdentity);
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity['cert']!))
      ..usePrivateKeyBytes(utf8.encode(identity['key']!));
    HttpServer server;
    try {
      server = await HttpServer.bindSecure(
        InternetAddress.anyIPv6,
        port,
        context,
        v6Only: false,
      );
    } on SocketException {
      try {
        server = await HttpServer.bindSecure(
          InternetAddress.anyIPv4,
          port,
          context,
        );
      } on SocketException {
        try {
          server = await HttpServer.bindSecure(
            InternetAddress.anyIPv6,
            0,
            context,
            v6Only: false,
          );
        } on SocketException {
          server = await HttpServer.bindSecure(
            InternetAddress.anyIPv4,
            0,
            context,
          );
        }
      }
    }
    server.idleTimeout = const Duration(seconds: 15);
    return LocalRoomServer._(server, identity, DateTime.now().add(ttl));
  }

  Future<RoomInvitation> invitation({String publicAddress = ''}) async {
    final public = RoomInvitation.publicEndpoint(publicAddress, port);
    final addresses = await discoverHostAddresses(port, publicEndpoint: public);
    // A host can still create a room offline, and two local instances can test it.
    if (addresses.isEmpty) addresses.add(loopback);
    return RoomInvitation(
      room: room,
      fingerprint: fingerprint,
      addresses: addresses,
      expires: expires,
    );
  }

  Future<void> _request(HttpRequest request) async {
    var reserved = false;
    try {
      if (_closed ||
          request.uri.path != '/ws' ||
          !WebSocketTransformer.isUpgradeRequest(request) ||
          _peers.length + _upgrading >= 6) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      _upgrading++;
      reserved = true;
      final socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions.compressionOff,
        maxPayloadLength: 64 * 1024,
      );
      _upgrading--;
      reserved = false;
      if (_closed) {
        await socket.close();
        return;
      }
      final peer = _RoomPeer(socket);
      _peers.add(peer);
      peer.authenticationDeadline = Timer(const Duration(seconds: 12), () {
        if (!peer.authenticated) {
          unawaited(socket.close(1008, 'Authentication required'));
        }
      });
      socket.pingInterval = const Duration(seconds: 20);
      socket.listen(
        (raw) {
          final now = DateTime.now();
          if (now.difference(peer.window) > const Duration(seconds: 1)) {
            peer.window = now;
            peer.messages = 0;
          }
          final length = raw is String ? utf8.encode(raw).length : 0;
          if (raw is! String ||
              length > 64 * 1024 ||
              ++peer.messages > 80 ||
              _pendingBytes + length > 512 * 1024) {
            unawaited(socket.close(1008, 'Signaling limits exceeded'));
            return;
          }
          _pendingBytes += length;
          _queue = _queue
              .then((_) => _message(peer, raw))
              .catchError((Object _) {
                _send(peer, {
                  'type': 'error',
                  'message': 'Invalid room request.',
                });
              })
              .whenComplete(() {
                _pendingBytes -= length;
              });
        },
        onError: (Object _) {},
        onDone: () {
          peer.authenticationDeadline?.cancel();
          _peers.remove(peer);
          if (!_closed && peer.authenticated) {
            unawaited(close('The other device left the room.'));
          }
        },
      );
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    } finally {
      if (reserved) _upgrading--;
    }
  }

  void _send(_RoomPeer peer, Map<String, Object?> value) {
    if (peer.socket.readyState == WebSocket.open) {
      peer.socket.add(jsonEncode(value));
    }
  }

  Future<void> _message(_RoomPeer peer, String raw) async {
    if (_closed || peer.socket.readyState != WebSocket.open) return;
    final message = jsonDecode(raw);
    if (message is! Map<String, dynamic>) throw const FormatException();
    final type = message['type'];
    if (!peer.authenticated) {
      if (type == 'create' &&
          _owner == null &&
          message['owner'] is String &&
          _equal(message['owner'], ownerToken)) {
        _owner = peer;
        peer.authenticated = true;
        peer.authenticationDeadline?.cancel();
        _send(peer, {
          'type': 'created',
          'room': room,
          'code': _identity['code'],
          'expires': expires.millisecondsSinceEpoch,
        });
        return;
      }
      if (type != 'join' || _owner == null || _guest != null) {
        _send(peer, {'type': 'error', 'message': 'This room is unavailable.'});
        return;
      }
      if (++_attempts > 5) {
        await close('Too many incorrect codes. Create a new room.');
        return;
      }
      final code = message['code'];
      final valid = code is String && RegExp(r'^\d{8}$').hasMatch(code);
      final salt = utf8.encode(_identity['salt']!);
      final hash = valid ? await _derivePasswordHash(code, salt) : '';
      if (_closed || peer.socket.readyState != WebSocket.open) return;
      if (!valid ||
          message['room'] != room ||
          !_equal(hash, _identity['hash']!)) {
        _send(peer, {
          'type': 'error',
          'message': 'The room or code is invalid, in use or expired.',
        });
        return;
      }
      _guest = peer;
      peer.authenticated = true;
      peer.authenticationDeadline?.cancel();
      _send(peer, {'type': 'joined', 'room': room});
      _send(_owner!, {'type': 'peer-joined'});
      return;
    }
    if (type == 'ready') {
      _ready.add(peer);
      if (_ready.length == 2) await close();
      return;
    }
    final other = peer == _owner ? _guest : _owner;
    final data = message['data'];
    if (type != 'signal' || other == null || data is! Map<String, dynamic>) {
      throw const FormatException();
    }
    if (data['type'] == 'offer' || data['type'] == 'answer') {
      if ((data['type'] == 'offer') != (peer == _owner) ||
          data['sdp'] is! String ||
          (data['sdp'] as String).length > 48000) {
        throw const FormatException();
      }
      _send(other, {
        'type': 'signal',
        'data': {'type': data['type'], 'sdp': data['sdp']},
      });
    } else if (data['type'] == 'candidate') {
      if (data['candidate'] is! String ||
          (data['candidate'] as String).length > 4096 ||
          (data['sdpMid'] != null && data['sdpMid'] is! String) ||
          (data['sdpMLineIndex'] != null && data['sdpMLineIndex'] is! int)) {
        throw const FormatException();
      }
      _send(other, {
        'type': 'signal',
        'data': {
          'type': 'candidate',
          'candidate': data['candidate'],
          'sdpMid': data['sdpMid'],
          'sdpMLineIndex': data['sdpMLineIndex'],
        },
      });
    } else {
      throw const FormatException();
    }
  }

  Future<void> close([String? reason]) async {
    if (_closed) return;
    _closed = true;
    _expiry.cancel();
    final peers = List<_RoomPeer>.of(_peers);
    for (final peer in peers) {
      peer.authenticationDeadline?.cancel();
      if (reason != null) _send(peer, {'type': 'error', 'message': reason});
      unawaited(peer.socket.close(1000));
    }
    _peers.clear();
    _ready.clear();
    _identity.clear();
    await _server.close(force: true);
  }
}

/// An invitation pins a fresh host certificate, never accepts arbitrary TLS.
HttpClient pinnedRoomClient(String fingerprint, {void Function()? onMismatch}) {
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
  client.findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 3);
  client.badCertificateCallback = (cert, _, _) {
    final matches = _equal(sha256.convert(cert.der).toString(), fingerprint);
    if (!matches) onMismatch?.call();
    return matches;
  };
  return client;
}
