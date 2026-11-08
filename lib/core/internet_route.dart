import 'dart:io';

import 'router_access.dart';
import 'host_addresses.dart';

/// Native global-unicast addresses only, excluding documentation, transition
/// tunnels and protocol-specific identifiers that are not host addresses.
bool isPublicIpv6(InternetAddress address) {
  if (address.type != InternetAddressType.IPv6 ||
      address.address.contains('%')) {
    return false;
  }
  final b = address.rawAddress;
  if ((b[0] & 0xe0) != 0x20) return false;
  if (b[0] == 0x20 && b[1] == 0x02) return false; // 6to4
  if (b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0) return false;
  if (b[0] == 0x20 && b[1] == 0x01) {
    final block = (b[2] << 8) | b[3];
    if (block == 0 ||
        block == 0xdb8 ||
        (block >= 0x10 && block <= 0x3f) ||
        (block == 2 && b[4] == 0 && b[5] == 0)) {
      return false;
    }
  }
  return true;
}

bool isUsableIpv6(InternetAddress address) =>
    address.type == InternetAddressType.IPv6 &&
    !address.isLoopback &&
    !address.isLinkLocal &&
    !address.isMulticast &&
    !address.address.contains('%') &&
    (isPublicIpv6(address) || (address.rawAddress[0] & 0xfe) == 0xfc);

List<InternetAddress> mergeIpv6Addresses(
  List<HostInterface> interfaces,
  List<String> androidAddresses,
) {
  final result = <String, InternetAddress>{};
  for (final address in [
    for (final network in interfaces)
      if (!RegExp(
        r'(teredo|6to4|isatap)',
        caseSensitive: false,
      ).hasMatch(network.name))
        ...network.addresses,
    for (final text in androidAddresses) ?InternetAddress.tryParse(text),
  ]) {
    if (isUsableIpv6(address)) result[address.address] = address;
  }
  return result.values.toList();
}

Future<List<InternetAddress>> _discoverIpv6() async {
  final native = Platform.isAndroid
      ? await readAndroidNetworkAddresses(internet: true)
      : <String>[];
  var interfaces = <NetworkInterface>[];
  try {
    interfaces = await NetworkInterface.list(type: InternetAddressType.IPv6);
  } on SocketException {
    // Android's LinkProperties can still supply addresses if enumeration fails.
  }
  return mergeIpv6Addresses(
    interfaces.map((n) => HostInterface(n.name, n.addresses)).toList(),
    native,
  );
}

Future<List<InternetAddress>> discoverPublicIpv6() async =>
    (await _discoverIpv6()).where(isPublicIpv6).toList();

Future<bool> hasUsableIpv6() async => (await _discoverIpv6()).isNotEmpty;

bool isIpv6OnlyInvitation(List<Uri> addresses) =>
    addresses.isNotEmpty &&
    addresses.every((u) {
      final ip = InternetAddress.tryParse(u.host);
      return ip != null && isPublicIpv6(ip);
    });

bool isIpv6Candidate(String text) {
  final candidate = text.trim();
  final parts =
      (candidate.startsWith('a=') ? candidate.substring(2) : candidate).split(
        RegExp(r'\s+'),
      );
  if (parts.length < 8 || !parts[0].startsWith('candidate:')) return false;
  final ip = InternetAddress.tryParse(parts[4]);
  return ip != null && isUsableIpv6(ip);
}

String ipv6OnlySdp(String sdp) => sdp
    .split('\n')
    .where(
      (line) =>
          !line.trim().startsWith('a=candidate:') || isIpv6Candidate(line),
    )
    .join('\n');

/// CGNAT only prevents the IPv4 route. A configured native public IPv6 route
/// is tried independently; its incoming firewall reachability is not assumed.
Future<RouterRoute> discoverInternetRoute({
  Future<RouterRoute> Function()? ipv4Discovery,
  Future<List<InternetAddress>> Function()? ipv6Discovery,
}) async {
  try {
    return await (ipv4Discovery ?? RouterAccess.discover)();
  } on RouterAccessException catch (e) {
    final addresses = await (ipv6Discovery ?? discoverPublicIpv6)();
    if (addresses.any(isPublicIpv6)) return DirectIpv6Route(addresses);
    throw RouterAccessException(
      '${e.message} No native public IPv6 address is available on this host either. Direct internet hosting needs a reachable public IPv4 or IPv6 connection.',
    );
  }
}

class DirectIpv6Route implements RouterRoute {
  DirectIpv6Route(List<InternetAddress> addresses)
    : addresses = List.unmodifiable(
        {for (final ip in addresses.where(isPublicIpv6)) ip.address: ip}.values
            .take(4),
      ) {
    if (this.addresses.isEmpty) {
      throw RouterAccessException(
        'This device has no native public IPv6 address.',
      );
    }
  }
  final List<InternetAddress> addresses;
  bool _closed = false;
  @override
  set onFailure(void Function(String)? handler) {}

  List<Uri> endpoints(int port) {
    if (_closed || port < 1024 || port > 65535) {
      throw RouterAccessException(
        'The direct IPv6 room is no longer available.',
      );
    }
    return [
      for (final ip in addresses)
        Uri(scheme: 'wss', host: ip.address, port: port, path: '/ws'),
    ];
  }

  @override
  Future<Uri> openRoom(int port) async => endpoints(port).first;
  @override
  Future<String?> mapCandidate(String text) async => null; // No IPv6 address translation.
  @override
  Future<void> closeRoomPort() async {}
  @override
  Future<void> close() async {
    _closed = true;
  }
}
