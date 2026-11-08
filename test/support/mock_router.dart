import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

class MockRouter {
  MockRouter._(this.server) {
    server.listen(_handle);
  }
  final HttpServer server;
  final entries = <String, Map<String, String>>{};
  final actions = <String>[];
  String wan =
      '8.8.8.8'; // Fixture data only; no request is sent to this address.
  String controlUrl = '/control';
  bool permanentLeases = false;
  bool refuseDelete = false;
  bool occupyNextLookup = false;
  bool redirectDescription = false;
  bool inactiveFirst = false;
  Completer<void>? pauseAdd;
  final addStarted = Completer<void>();
  int adds = 0;
  int deletes = 0;

  static Future<MockRouter> start({InternetAddress? address}) async =>
      MockRouter._(
        await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, 0),
      );
  Uri get description => Uri(
    scheme: 'http',
    host: server.address.address,
    port: server.port,
    path: '/device.xml',
  );

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'GET') {
      if (redirectDescription) {
        request.response.statusCode = 302;
        request.response.headers.set('location', 'http://8.8.8.8/device.xml');
      } else {
        final inactive = inactiveFirst
            ? '<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/inactive</controlURL></service>'
            : '';
        request.response.write(
          '<root><device><serviceList>$inactive<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType><controlURL>$controlUrl</controlURL></service></serviceList></device></root>',
        );
      }
      await request.response.close();
      return;
    }
    final action = request.headers
        .value('SOAPAction')!
        .replaceAll('"', '')
        .split('#')
        .last;
    actions.add(action);
    final document = XmlDocument.parse(await utf8.decoder.bind(request).join());
    String value(String key) => document.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == key)
        .first
        .innerText;
    final key = action == 'GetExternalIPAddress'
        ? ''
        : '${value('NewProtocol')}:${value('NewExternalPort')}';
    var fields = <String, String>{};
    var missing = false;
    switch (action) {
      case 'GetExternalIPAddress':
        fields = {
          'NewExternalIPAddress': request.uri.path == '/inactive'
              ? '0.0.0.0'
              : wan,
        };
      case 'GetSpecificPortMappingEntry':
        if (occupyNextLookup) {
          occupyNextLookup = false;
          entries[key] = {
            'NewInternalClient': '192.168.1.99',
            'NewInternalPort': '12345',
            'NewPortMappingDescription': 'Other application',
            'NewLeaseDuration': '100',
            'NewEnabled': '1',
          };
        }
        missing = !entries.containsKey(key);
        fields = entries[key] ?? {};
      case 'AddPortMapping':
        if (!addStarted.isCompleted) addStarted.complete();
        await pauseAdd?.future;
        adds++;
        entries[key] = {
          for (final name in [
            'NewInternalClient',
            'NewInternalPort',
            'NewPortMappingDescription',
            'NewLeaseDuration',
            'NewEnabled',
          ])
            name: value(name),
        };
        if (permanentLeases) entries[key]!['NewLeaseDuration'] = '0';
      case 'DeletePortMapping':
        if (refuseDelete) {
          request.response.statusCode = 500;
          request.response.write(
            '<Envelope><Fault><errorCode>501</errorCode></Fault></Envelope>',
          );
          await request.response.close();
          return;
        }
        deletes++;
        entries.remove(key);
      default:
        throw StateError('Unexpected router action: $action');
    }
    if (missing) {
      request.response.statusCode = 500;
      request.response.write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError><errorCode>714</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>',
      );
    } else {
      final data = fields.entries
          .map((e) => '<${e.key}>${XmlText(e.value).toXmlString()}</${e.key}>')
          .join();
      request.response.write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:${action}Response xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:2">$data</u:${action}Response></s:Body></s:Envelope>',
      );
    }
    await request.response.close();
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}
