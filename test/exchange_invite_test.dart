import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:line/core/exchange_invite.dart';

final sdp =
    'v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=fingerprint:sha-256 ${List.filled(32, 'AB').join(':')}\r\na=sctp-port:5000\r\n';

void main() {
  test(
    'encrypted offer and bound response round trip with the separate PIN',
    () async {
      final offer = ExchangeInvite.offer(sdp);
      final encoded = await offer.encode('123456789012');
      expect(encoded, startsWith('line://connect/'));
      expect(encoded, isNot(contains('fingerprint')));
      final received = await ExchangeInvite.decode(encoded, '123456789012');
      expect(received.sdp, sdp);
      expect(received.session, offer.session);
      final answer = received.answer(sdp);
      final decoded = await ExchangeInvite.decode(
        await answer.encode('123456789012'),
        '123456789012',
      );
      decoded.checkAnswerFor(offer);
      expect(decoded.isAnswer, isTrue);
      expect(
        () => decoded.checkAnswerFor(ExchangeInvite.offer(sdp)),
        throwsFormatException,
      );
    },
  );
  test('wrong PIN and altered authenticated headers are rejected', () async {
    await expectLater(
      ExchangeInvite.offer(sdp).encode('12345678'),
      throwsFormatException,
    );
    final encoded = await ExchangeInvite.offer(sdp).encode('123456789012');
    await expectLater(
      ExchangeInvite.decode(encoded, '210987654321'),
      throwsFormatException,
    );
    final outer = jsonDecode(
      utf8.decode(
        base64Url.decode(base64Url.normalize(encoded.split('/').last)),
      ),
    ) as Map<String, dynamic>;
    outer['session'] = 'a' * 32;
    final changed =
        'line://connect/${base64Url.encode(utf8.encode(jsonEncode(outer))).replaceAll('=', '')}';
    await expectLater(
      ExchangeInvite.decode(changed, '123456789012'),
      throwsFormatException,
    );
  });
  test(
    'data-only SDP, no relays, bounded input and expiry are enforced',
    () async {
      await expectLater(
        ExchangeInvite.offer('$sdp${'\\' * 32000}').encode('123456789012'),
        throwsFormatException,
      );
      expect(
        () =>
            ExchangeInvite.offer('v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'),
        throwsFormatException,
      );
      expect(
        () => ExchangeInvite.offer(
          '${sdp}a=candidate:a 1 udp 1 8.8.8.8 5000 typ relay\r\n',
        ),
        throwsFormatException,
      );
      await expectLater(
        ExchangeInvite.decode('line://connect/${'a' * 100000}', '123456789012'),
        throwsFormatException,
      );
      final encoded = await ExchangeInvite.offer(sdp).encode('123456789012');
      final outer = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(encoded.split('/').last)),
        ),
      ) as Map<String, dynamic>;
      outer['expires'] = DateTime.now()
          .subtract(const Duration(seconds: 1))
          .millisecondsSinceEpoch;
      await expectLater(
        ExchangeInvite.decode(
          'line://connect/${base64Url.encode(utf8.encode(jsonEncode(outer)))}',
          '123456789012',
        ),
        throwsFormatException,
      );
    },
  );
}
