import 'package:line/core/router_access.dart';

// Native lab only: do not probe a public fixture address. Preserve real SOAP,
// leases and ICE construction, then keep every network packet on the test LAN.
class LocalRouterRoute implements RouterRoute {
  LocalRouterRoute(this.router, this.lanAddress);
  final RouterAccess router;
  final String lanAddress;
  @override
  set onFailure(void Function(String)? handler) => router.onFailure = handler;
  @override
  Future<Uri> openRoom(int port) async =>
      (await router.openRoom(port)).replace(host: lanAddress);
  @override
  Future<String?> mapCandidate(String text) async =>
      (await router.mapCandidate(text))
          ?.replaceFirst(router.publicAddress.address, lanAddress);
  @override
  Future<void> closeRoomPort() => router.closeRoomPort();
  @override
  Future<void> close() => router.close();
}
