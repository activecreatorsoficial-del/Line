// Read-only gateway diagnostic: discovers WAN support without opening ports.
import 'dart:io';

import 'package:line/core/router_access.dart';

Future<void> main() async {
  try {
    final router = await RouterAccess.discover();
    try {
      stdout.writeln(
        'A compatible gateway with public IPv4 is available. No ports were opened.',
      );
    } finally {
      await router.close();
    }
  } on RouterAccessException catch (e) {
    stdout.writeln(e.message);
    exitCode = 2;
  }
}
