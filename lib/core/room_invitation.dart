import 'dart:convert';
import 'dart:io';

/// Carries the host address and TLS identity without a public room directory.
class RoomInvitation {
  RoomInvitation({
    required this.room,
    required this.fingerprint,
    required this.addresses,
    required this.expires,
  });
  final String room;
  final String fingerprint;
  final List<Uri> addresses;
  final DateTime expires;

  String encode() =>
      'line://join/${base64Url.encode(utf8.encode(jsonEncode({'v': 1, 'r': room, 'p': fingerprint, 'a': addresses.map((a) => a.toString()).toList(), 'e': expires.millisecondsSinceEpoch}))).replaceAll('=', '')}';

  static RoomInvitation parse(String value) {
    if (value.length > 8192) {
      throw const FormatException('Invitation too long.');
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'line' ||
        uri.host != 'join' ||
        uri.pathSegments.length != 1 ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      throw const FormatException('Paste the invitation copied by the sender.');
    }
    final data = jsonDecode(
      utf8.decode(
        base64Url.decode(base64Url.normalize(uri.pathSegments.single)),
      ),
    );
    if (data is! Map ||
        data['v'] != 1 ||
        data['r'] is! String ||
        !RegExp(r'^LINE-[A-F0-9]{8}$').hasMatch(data['r']) ||
        data['p'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['p']) ||
        data['e'] is! int ||
        data['a'] is! List ||
        (data['a'] as List).isEmpty ||
        (data['a'] as List).length > 12) {
      throw const FormatException('Invalid Line invitation.');
    }
    final addresses = <Uri>[];
    for (final value in data['a']) {
      if (value is! String || value.length > 512) {
        throw const FormatException('Invalid host address.');
      }
      final address = Uri.tryParse(value);
      if (address == null ||
          address.scheme != 'wss' ||
          address.host.isEmpty ||
          address.path != '/ws' ||
          address.hasQuery ||
          address.hasFragment ||
          address.userInfo.isNotEmpty ||
          address.port < 1 ||
          address.port > 65535) {
        throw const FormatException(
          'The invitation must use encrypted host addresses.',
        );
      }
      addresses.add(address);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (data['e'] <= now) {
      throw const FormatException(
        'This room has expired. Ask for a new invitation.',
      );
    }
    if (data['e'] > now + const Duration(minutes: 11).inMilliseconds) {
      throw const FormatException('Invalid invitation expiry.');
    }
    final expires = DateTime.fromMillisecondsSinceEpoch(data['e']);
    return RoomInvitation(
      room: data['r'],
      fingerprint: data['p'],
      addresses: addresses,
      expires: expires,
    );
  }

  static Uri? publicEndpoint(String value, int port) {
    if (value.trim().isEmpty) return null;
    final text = value.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'wss://$text');
    if (uri == null ||
        uri.scheme != 'wss' ||
        uri.host.isEmpty ||
        (uri.path.isNotEmpty && uri.path != '/ws') ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException(
        'Enter your reachable host address, for example example.org:8790.',
      );
    }
    return uri.replace(port: uri.hasPort ? uri.port : port, path: '/ws');
  }

  static bool isLoopback(Uri uri) =>
      uri.host == 'localhost' ||
      (InternetAddress.tryParse(uri.host)?.isLoopback ?? false);
}
