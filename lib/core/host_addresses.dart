import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class HostInterface {
  const HostInterface(this.name, this.addresses);
  final String name;
  final List<InternetAddress> addresses;
}

bool _privateV4(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168);
}

/// Prefer real LAN interfaces before applying the invitation size limit.
/// Android can expose many mobile/VPN addresses before its Wi-Fi interface.
List<Uri> rankHostAddresses(
  List<HostInterface> interfaces,
  int port, {
  List<String> wifiAddresses = const [],
  Uri? publicEndpoint,
  int limit = 10,
}) {
  final ranked = <({Uri uri, int score})>[];
  for (final network in interfaces) {
    final name = network.name.toLowerCase();
    final cellular = RegExp(r'^(rmnet|ccmni|pdp|wwan|v4-rmnet|mni)')
        .hasMatch(name);
    final virtual = RegExp(
      r'(tun|tap|vpn|docker|veth|vmnet|virtual|wireguard|^wg)',
    ).hasMatch(name);
    final lan = RegExp(r'(wi.?fi|wlan|^wlp|ethernet|^eth|^en\d|^enp)')
        .hasMatch(name);
    for (final address in network.addresses) {
      if (address.isLoopback ||
          address.isLinkLocal ||
          address.address.contains('%')) {
        continue;
      }
      final wifi = wifiAddresses.contains(address.address);
      final score =
          (wifi
              ? -100
              : cellular
              ? 300
              : virtual
              ? 200
              : lan
              ? 0
              : 100) +
          (_privateV4(address)
              ? 0
              : address.type == InternetAddressType.IPv4
              ? 10
              : 20);
      ranked.add((
        uri: Uri(scheme: 'wss', host: address.address, port: port, path: '/ws'),
        score: score,
      ));
    }
  }
  // Include Wi-Fi addresses supplied by Android even if interface enumeration omits them.
  for (final text in wifiAddresses) {
    final address = InternetAddress.tryParse(text);
    if (address == null ||
        address.isLoopback ||
        address.isLinkLocal ||
        text.contains('%')) {
      continue;
    }
    ranked.add((
      uri: Uri(scheme: 'wss', host: address.address, port: port, path: '/ws'),
      score: address.type == InternetAddressType.IPv4 ? -100 : -80,
    ));
  }
  ranked.sort((a, b) {
    final byScore = a.score.compareTo(b.score);
    return byScore != 0
        ? byScore
        : a.uri.toString().compareTo(b.uri.toString());
  });
  final result = <Uri>[?publicEndpoint];
  for (final item in ranked) {
    if (!result.contains(item.uri) && result.length < limit) {
      result.add(item.uri);
    }
  }
  return result;
}

Future<List<String>> readAndroidNetworkAddresses({
  bool internet = false,
}) async {
  try {
    return (await const MethodChannel('app.line/network')
            .invokeListMethod<String>(
              internet ? 'internetAddresses' : 'wifiAddresses',
            )
            .timeout(const Duration(seconds: 2))) ??
        [];
  } on PlatformException {
    return [];
  } on MissingPluginException {
    return [];
  } on TimeoutException {
    return [];
  }
}

Future<List<Uri>> discoverHostAddresses(int port, {Uri? publicEndpoint}) async {
  final wifi = Platform.isAndroid
      ? await readAndroidNetworkAddresses()
      : <String>[];
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: false,
  );
  return rankHostAddresses(
    interfaces.map((n) => HostInterface(n.name, n.addresses)).toList(),
    port,
    wifiAddresses: wifi,
    publicEndpoint: publicEndpoint,
  );
}
