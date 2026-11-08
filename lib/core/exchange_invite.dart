import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

const freeStunServer = 'stun:stun.cloudflare.com:3478';

Uint8List _random(int size) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));
}

void _pin(String code) {
  if (!RegExp(r'^\d{12}$').hasMatch(code)) {
    throw const FormatException('Enter the sender\'s 12-digit Internet code.');
  }
}

void validateExchangeSdp(String sdp) {
  final media = sdp.split('\n').where((line) => line.startsWith('m=')).toList();
  if (utf8.encode(sdp).length > 32768 ||
      !sdp.startsWith('v=0') ||
      sdp.contains('\u0000') ||
      media.length != 1 ||
      !media.single.startsWith('m=application ') ||
      !RegExp(
        r'^a=fingerprint:sha-256 (?:[a-fA-F0-9]{2}:){31}[a-fA-F0-9]{2}\r?$',
        multiLine: true,
      ).hasMatch(sdp) ||
      RegExp(r'\btyp\s+relay\b', caseSensitive: false).hasMatch(sdp)) {
    throw const FormatException(
      'This invitation is not a supported direct file connection.',
    );
  }
}

/// Encrypted one-shot signaling. No addresses, filenames or PIN are logged.
class ExchangeInvite {
  ExchangeInvite._(this.session, this.expires, this.sdp, this.offerHash) {
    validateExchangeSdp(sdp);
  }
  factory ExchangeInvite.offer(String sdp) => ExchangeInvite._(
    _random(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    DateTime.now().add(const Duration(minutes: 10)),
    sdp,
    null,
  );
  final String session;
  final DateTime expires;
  final String sdp;
  final String? offerHash;
  bool get isAnswer => offerHash != null;
  String get room => 'LINE-${session.substring(0, 8).toUpperCase()}';
  String get digest => sha256
      .convert(
        utf8.encode(jsonEncode([session, expires.millisecondsSinceEpoch, sdp])),
      )
      .toString();
  static bool recognizes(String value) =>
      value.trim().startsWith('line://connect/');

  ExchangeInvite answer(String sdp) {
    if (isAnswer) {
      throw const FormatException(
        'Open the original sender invitation to create a response.',
      );
    }
    return ExchangeInvite._(session, expires, sdp, digest);
  }

  void checkAnswerFor(ExchangeInvite offer) {
    if (!isAnswer ||
        offer.isAnswer ||
        session != offer.session ||
        expires.millisecondsSinceEpoch !=
            offer.expires.millisecondsSinceEpoch ||
        offerHash != offer.digest) {
      throw const FormatException(
        'This response belongs to a different invitation. Ask for a fresh response.',
      );
    }
  }

  Future<String> encode(String code) => Isolate.run(() => _encode(code));

  String _encode(String code) {
    _pin(code);
    _expiry(expires.millisecondsSinceEpoch);
    final salt = _random(16), nonce = _random(12);
    final kind = isAnswer ? 'answer' : 'offer';
    final header = [2, kind, session, expires.millisecondsSinceEpoch];
    final cipher = _cipher(true, code, salt, nonce, header);
    final encrypted = cipher.process(
      Uint8List.fromList(
        utf8.encode(jsonEncode({'sdp': sdp, if (isAnswer) 'offer': offerHash})),
      ),
    );
    if (encrypted.length > 49152) {
      throw const FormatException(
        'This connection description is too large. Try a network with fewer active interfaces.',
      );
    }
    final frame = {
      'v': 2,
      'kind': kind,
      'session': session,
      'expires': expires.millisecondsSinceEpoch,
      'salt': base64Url.encode(salt),
      'nonce': base64Url.encode(nonce),
      'body': base64Url.encode(encrypted),
    };
    return 'line://connect/${base64Url.encode(utf8.encode(jsonEncode(frame))).replaceAll('=', '')}';
  }

  static Future<ExchangeInvite> decode(String token, String code) =>
      Isolate.run(() => _decode(token, code));

  static ExchangeInvite _decode(String token, String code) {
    _pin(code);
    if (token.length > 98304) {
      throw const FormatException('This invitation is too long.');
    }
    final text = token.replaceAll(RegExp(r'\s+'), '');
    const prefix = 'line://connect/';
    if (!text.startsWith(prefix) ||
        !RegExp(r'^[A-Za-z0-9_-]+={0,2}$')
            .hasMatch(text.substring(prefix.length))) {
      throw const FormatException(
        'Paste the complete invitation or response copied from Line.',
      );
    }
    try {
      final frame = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(text.substring(prefix.length))),
        ),
      );
      if (frame is! Map ||
          frame.length != 7 ||
          frame['v'] != 2 ||
          !['offer', 'answer'].contains(frame['kind']) ||
          frame['session'] is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(frame['session']) ||
          frame['expires'] is! int ||
          frame['salt'] is! String ||
          frame['nonce'] is! String ||
          frame['body'] is! String) {
        throw const FormatException('Invalid invitation.');
      }
      _expiry(frame['expires']);
      final salt = base64Url.decode(frame['salt']);
      final nonce = base64Url.decode(frame['nonce']);
      final encrypted = base64Url.decode(frame['body']);
      if (salt.length != 16 ||
          nonce.length != 12 ||
          encrypted.length < 16 ||
          encrypted.length > 49152) {
        throw const FormatException('Invalid invitation.');
      }
      final cipher = _cipher(false, code, salt, nonce, [
        2,
        frame['kind'],
        frame['session'],
        frame['expires'],
      ]);
      final data = jsonDecode(utf8.decode(cipher.process(encrypted)));
      final answer = frame['kind'] == 'answer';
      if (data is! Map ||
          data.length != (answer ? 2 : 1) ||
          data['sdp'] is! String ||
          (answer &&
              (data['offer'] is! String ||
                  !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['offer'])))) {
        throw const FormatException('Invalid invitation.');
      }
      return ExchangeInvite._(
        frame['session'],
        DateTime.fromMillisecondsSinceEpoch(frame['expires']),
        data['sdp'],
        answer ? data['offer'] : null,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException(
        'The invitation or temporary code is incorrect.',
      );
    }
  }

  static void _expiry(int value) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (value <= now) {
      throw const FormatException(
        'This invitation has expired. Create a new room.',
      );
    }
    if (value > now + const Duration(minutes: 11).inMilliseconds) {
      throw const FormatException('Invalid invitation expiry.');
    }
  }

  static GCMBlockCipher _cipher(
    bool encrypt,
    String code,
    Uint8List salt,
    Uint8List nonce,
    List<Object> header,
  ) {
    final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, 65536, 32));
    return GCMBlockCipher(AESEngine())..init(
      encrypt,
      AEADParameters(
        KeyParameter(kdf.process(Uint8List.fromList(utf8.encode(code)))),
        128,
        nonce,
        Uint8List.fromList(utf8.encode(jsonEncode(header))),
      ),
    );
  }
}
