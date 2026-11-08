import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xml/xml.dart';

bool _privateV4(InternetAddress ip) {
  if (ip.type != InternetAddressType.IPv4) return false;
  final b = ip.rawAddress;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168);
}

bool isPublicV4(InternetAddress ip) {
  if (ip.type != InternetAddressType.IPv4 || _privateV4(ip)) return false;
  final b = ip.rawAddress;
  return !(b[0] == 0 ||
      b[0] == 127 ||
      b[0] >= 224 ||
      (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
      (b[0] == 169 && b[1] == 254) ||
      (b[0] == 192 && b[1] == 0 && [0, 2].contains(b[2])) ||
      (b[0] == 192 && b[1] == 88 && b[2] == 99) ||
      (b[0] == 198 && [18, 19].contains(b[1])) ||
      (b[0] == 198 && b[1] == 51 && b[2] == 100) ||
      (b[0] == 203 && b[1] == 0 && b[2] == 113));
}

class RouterAccessException implements Exception {
  RouterAccessException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _SoapFault implements Exception {
  _SoapFault(this.code);
  final int? code;
}

class HostUdpCandidate {
  HostUdpCandidate._(this.foundation, this.address, this.port);
  final String foundation;
  final String address;
  final int port;

  static HostUdpCandidate? parse(String text) {
    final parts = text.trim().split(RegExp(r'\s+'));
    if (parts.length < 8 ||
        !parts[0].startsWith('candidate:') ||
        parts[1] != '1' ||
        parts[2].toLowerCase() != 'udp' ||
        parts[6] != 'typ' ||
        parts[7] != 'host') {
      return null;
    }
    final ip = InternetAddress.tryParse(parts[4]);
    final port = int.tryParse(parts[5]);
    final foundation = parts[0].substring(10);
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        port == null ||
        port < 1024 ||
        port > 65535 ||
        !RegExp(r'^[a-zA-Z0-9+/]{1,28}$').hasMatch(foundation)) {
      return null;
    }
    return HostUdpCandidate._(foundation, ip.address, port);
  }

  String mapped(String publicIp, int publicPort) =>
      'candidate:line$foundation 1 udp 1694498815 $publicIp $publicPort typ srflx raddr $address rport $port';
}

class _Mapping {
  _Mapping(this.protocol, this.internalPort, this.externalPort);
  final String protocol;
  final int internalPort;
  final int externalPort;
}

/// UPnP is used only on the local network. File and signaling traffic still
/// terminate on the hosting device; there is no external discovery service.
abstract interface class RouterRoute {
  set onFailure(void Function(String)? handler);
  Future<Uri> openRoom(int port);
  Future<String?> mapCandidate(String text);
  Future<void> closeRoomPort();
  Future<void> close();
}

class RouterAccess implements RouterRoute {
  RouterAccess._(this._client, this.control, this.service, this.localAddress);
  final HttpClient _client;
  final Uri control;
  final String service;
  final InternetAddress localAddress;
  late final InternetAddress publicAddress;
  final String _description =
      'Line temporary ${Random.secure().nextInt(1 << 32).toRadixString(16)}';
  final _mappings = <_Mapping>[];
  final _opening = <String, Future<_Mapping>>{};
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  bool _closed = false;
  Timer? _renewal;
  void Function(String)? onFailure;
  static const leaseSeconds = 600;

  static bool _localUri(
    Uri uri,
    InternetAddress local, {
    InternetAddress? source,
  }) {
    final host = InternetAddress.tryParse(uri.host);
    return uri.scheme == 'http' &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        !uri.hasQuery &&
        uri.toString().length <= 512 &&
        host != null &&
        (_privateV4(host) || (local.isLoopback && host.isLoopback)) &&
        (source == null || source.address == host.address) &&
        uri.port > 0 &&
        uri.port <= 65535;
  }

  static XmlDocument _xml(String text) {
    if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
      throw const FormatException('Unsupported router XML.');
    }
    return XmlDocument.parse(text);
  }

  static String? _value(XmlNode node, String name) => node.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == name)
      .firstOrNull
      ?.innerText
      .trim();

  static Future<String> _request(
    HttpClient client,
    Uri uri, {
    String? body,
    String? action,
  }) async {
    HttpClientRequest? request;
    final operation = () async {
      request = await client.openUrl(body == null ? 'GET' : 'POST', uri);
      request!.followRedirects = false;
      if (body != null) {
        request!.headers.contentType = ContentType(
          'text',
          'xml',
          charset: 'utf-8',
        );
        request!.headers.set('SOAPAction', '"$action"');
        request!.write(body);
      }
      final response = await request!.close();
      if (response.isRedirect || response.contentLength > 64 * 1024) {
        throw const FormatException('Invalid router response.');
      }
      final bytes = <int>[];
      await for (final part in response) {
        if (bytes.length + part.length > 64 * 1024) {
          throw const FormatException('Router response too large.');
        }
        bytes.addAll(part);
      }
      final text = utf8.decode(bytes);
      if (response.statusCode != 200 && response.statusCode != 500) {
        throw const FormatException('Router request refused.');
      }
      return text;
    }();
    try {
      return await operation.timeout(const Duration(seconds: 2));
    } catch (_) {
      request?.abort();
      rethrow;
    }
  }

  /// Description must refer to the responding local device. Never follow an
  /// SSDP URL to the internet or a redirect to another device.
  static Future<RouterAccess> fromDescription(
    Uri location,
    InternetAddress local,
  ) async {
    if (!_localUri(location, local)) {
      throw RouterAccessException('The router advertised an unsafe address.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 1)
      ..maxConnectionsPerHost = 2
      ..findProxy = (_) => 'DIRECT';
    try {
      final description = _xml(await _request(client, location));
      RouterAccessException? wanFailure;
      var inspected = 0;
      for (final element
          in description.descendants.whereType<XmlElement>().where(
            (e) => e.name.local == 'service',
          )) {
        final type = _value(element, 'serviceType') ?? '';
        if (!RegExp(
          r'^urn:schemas-upnp-org:service:WAN(IP|PPP)Connection:[12]$',
        ).hasMatch(type)) {
          continue;
        }
        final url = location.resolve(_value(element, 'controlURL') ?? '');
        if (!_localUri(url, local) || url.origin != location.origin) continue;
        if (++inspected > 4) break;
        final access = RouterAccess._(client, url, type, local);
        XmlDocument response;
        try {
          response = await access._soap('GetExternalIPAddress');
        } catch (_) {
          continue;
        }
        final address = InternetAddress.tryParse(
          _value(response, 'NewExternalIPAddress') ?? '',
        );
        if (address == null || !isPublicV4(address)) {
          final shared =
              address?.type == InternetAddressType.IPv4 &&
              address!.rawAddress[0] == 100 &&
              address.rawAddress[1] >= 64 &&
              address.rawAddress[1] <= 127;
          wanFailure = RouterAccessException(
            shared
                ? 'The router reports a shared carrier IPv4 (CGNAT). Direct incoming connections require a public address from your provider.'
                : 'No discovered router service reports a public IPv4. A private upstream network, an inactive WAN or another router can prevent direct internet hosting. Nearby sharing still works.',
          );
          continue;
        }
        access.publicAddress = address;
        return access;
      }
      throw wanFailure ??
          RouterAccessException(
            'The router does not expose a compatible internet gateway.',
          );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  static Future<RouterAccess> discover({
    List<InternetAddress>? localAddresses,
    InternetAddress? searchAddress,
    int searchPort = 1900,
    Duration searchTime = const Duration(seconds: 3),
  }) async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final addresses =
        localAddresses ??
        [
          for (final network in interfaces)
            if (!RegExp(
              r'(rmnet|ccmni|pdp|wwan|tun|tap|vpn|veth|vmnet|docker)',
              caseSensitive: false,
            ).hasMatch(network.name))
              for (final address in network.addresses)
                if (_privateV4(address)) address,
        ];
    final sockets = <RawDatagramSocket>[];
    final devices = <({Uri location, InternetAddress local})>[];
    try {
      for (final address in addresses.take(4)) {
        try {
          final socket = await RawDatagramSocket.bind(address, 0);
          sockets.add(socket);
          socket.multicastHops = 1;
          if (searchAddress == null) {
            socket.setRawOption(
              RawSocketOption(
                RawSocketOption.levelIPv4,
                RawSocketOption.IPv4MulticastInterface,
                address.rawAddress,
              ),
            );
          }
          socket.listen((event) {
            if (event != RawSocketEvent.read) return;
            Datagram? data;
            while ((data = socket.receive()) != null) {
              if (data!.data.length > 8192 || devices.length >= 4) continue;
              final text = latin1.decode(data.data);
              if (!text.startsWith('HTTP/1.1 200')) continue;
              final locationText = RegExp(
                r'^location:\s*(.+)\r?$',
                caseSensitive: false,
                multiLine: true,
              ).firstMatch(text)?.group(1)?.trim();
              final location = Uri.tryParse(locationText ?? '');
              if (location != null &&
                  _localUri(location, address, source: data.address) &&
                  !devices.any((d) => d.location == location)) {
                devices.add((location: location, local: address));
              }
            }
          }, onError: (Object _) {});
          final target = searchAddress ?? InternetAddress('239.255.255.250');
          socket.send(
            ascii.encode(
              'M-SEARCH * HTTP/1.1\r\nHOST: ${target.address}:$searchPort\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n',
            ),
            target,
            searchPort,
          );
        } on SocketException {
          /* Try the next local interface. */
        }
      }
      if (sockets.isNotEmpty) await Future<void>.delayed(searchTime);
    } finally {
      for (final socket in sockets) {
        socket.close();
      }
    }
    RouterAccessException? failure;
    for (final device in devices.take(2)) {
      try {
        return await fromDescription(device.location, device.local);
      } on RouterAccessException catch (e) {
        failure = e;
      } catch (_) {
        /* A non-responsive device is not the gateway. */
      }
    }
    throw failure ??
        RouterAccessException(
          'No compatible router answered. Direct internet hosting needs a router with temporary UPnP mappings and a public IPv4. Mobile data and restricted routers cannot provide this route. Nearby sharing still works.',
        );
  }

  Future<XmlDocument> _soap(
    String action, [
    Map<String, Object> values = const {},
  ]) async {
    final args = values.entries
        .map(
          (e) => '<${e.key}>${XmlText('${e.value}').toXmlString()}</${e.key}>',
        )
        .join();
    final body =
        '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:$action xmlns:u="$service">$args</u:$action></s:Body></s:Envelope>';
    final doc = _xml(
      await _request(_client, control, body: body, action: '$service#$action'),
    );
    if (_value(doc, 'errorCode') case final String code) {
      throw _SoapFault(int.tryParse(code));
    }
    if (!doc.descendants.whereType<XmlElement>().any(
      (e) => e.name.local == '${action}Response',
    )) {
      throw const FormatException('Invalid router action response.');
    }
    return doc;
  }

  Map<String, Object> _key(_Mapping m) => {
    'NewRemoteHost': '',
    'NewExternalPort': m.externalPort,
    'NewProtocol': m.protocol,
  };
  Future<XmlDocument?> _entry(_Mapping m) async {
    try {
      return await _soap('GetSpecificPortMappingEntry', _key(m));
    } on _SoapFault catch (e) {
      if (e.code == 714) return null;
      rethrow;
    }
  }

  bool _owned(XmlDocument entry, _Mapping m) =>
      _value(entry, 'NewInternalClient') == localAddress.address &&
      int.tryParse(_value(entry, 'NewInternalPort') ?? '') == m.internalPort &&
      _value(entry, 'NewPortMappingDescription') == _description;

  Future<T> _run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _add(_Mapping m) async {
    await _soap('AddPortMapping', {
      ..._key(m),
      'NewInternalPort': m.internalPort,
      'NewInternalClient': localAddress.address,
      'NewEnabled': 1,
      'NewPortMappingDescription': _description,
      'NewLeaseDuration': leaseSeconds,
    });
    final entry = await _entry(m);
    final lease =
        int.tryParse(
          entry == null ? '' : _value(entry, 'NewLeaseDuration') ?? '',
        ) ??
        0;
    if (entry == null ||
        !_owned(entry, m) ||
        ![
          '1',
          'true',
          'yes',
        ].contains(_value(entry, 'NewEnabled')?.toLowerCase()) ||
        lease <= 0 ||
        lease > leaseSeconds) {
      throw RouterAccessException(
        'The router did not confirm a temporary mapping. Line will not keep a permanent port open.',
      );
    }
  }

  Future<void> _remove(_Mapping m) async {
    _mappings.remove(m);
    final entry = await _entry(m);
    if (entry != null && _owned(entry, m)) {
      await _soap('DeletePortMapping', _key(m));
    }
  }

  Future<_Mapping> _map(String protocol, int port) => _opening.putIfAbsent(
    '$protocol:$port',
    () => _run(() async {
      if (_closed || port < 1024 || port > 65535 || _mappings.length >= 4) {
        throw RouterAccessException(
          'The temporary router session is unavailable.',
        );
      }
      for (var attempt = 0; attempt < 5; attempt++) {
        final mapping = _Mapping(
          protocol,
          port,
          49152 + Random.secure().nextInt(16384),
        );
        if (await _entry(mapping) != null) {
          continue; // Never replace an existing rule.
        }
        try {
          await _add(mapping);
          _mappings.add(mapping);
          if (_closed) throw RouterAccessException('Sharing was cancelled.');
          _renewal ??= Timer.periodic(const Duration(minutes: 3), (_) {
            unawaited(
              renew().catchError((Object _) {
                if (!_closed) {
                  onFailure?.call(
                    'The temporary router route was lost. Create a new room.',
                  );
                }
              }),
            );
          });
          return mapping;
        } catch (e) {
          if (e is _SoapFault && e.code == 718) continue;
          try {
            await _remove(mapping);
          } catch (_) {
            throw RouterAccessException(
              'The router did not confirm cleanup. Check its Line temporary rule before retrying.',
            );
          }
          if (e is _SoapFault) {
            throw RouterAccessException(
              'The router refused temporary internet access. Nearby sharing is still available.',
            );
          }
          rethrow;
        }
      }
      throw RouterAccessException(
        'The router has no available temporary port.',
      );
    }),
  );

  @override
  Future<Uri> openRoom(int port) async {
    final m = await _map('TCP', port);
    return Uri(
      scheme: 'wss',
      host: publicAddress.address,
      port: m.externalPort,
      path: '/ws',
    );
  }

  @override
  Future<String?> mapCandidate(String text) async {
    final candidate = HostUdpCandidate.parse(text);
    if (candidate == null || candidate.address != localAddress.address) {
      return null;
    }
    final m = await _map('UDP', candidate.port);
    if (_closed) return null;
    return candidate.mapped(publicAddress.address, m.externalPort);
  }

  Future<void> renew() => _run(() async {
    if (_closed) return;
    for (final m in List.of(_mappings)) {
      final entry = await _entry(m);
      if (entry == null || !_owned(entry, m)) {
        throw RouterAccessException(
          'The router mapping is no longer owned by this session.',
        );
      }
      await _add(m);
    }
  });

  @override
  Future<void> closeRoomPort() => _run(() async {
    if (_closed) return;
    for (final m in _mappings.where((m) => m.protocol == 'TCP').toList()) {
      await _remove(m);
    }
  });

  @override
  Future<void> close() => _closing ??= () async {
    _closed = true;
    _renewal?.cancel();
    await _tail;
    try {
      await Future.wait(
        List.of(_mappings).map((m) async {
          try {
            await _remove(m);
          } catch (_) {
            /* Finite leases handle a disconnected router. */
          }
        }),
      );
    } finally {
      _client.close(force: true);
    }
  }();
}
