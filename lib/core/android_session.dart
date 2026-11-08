import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps a user-initiated Android sharing session alive while copying an
/// invitation, switching apps or turning the screen off. No automatic restart.
class AndroidSession {
  static const _channel = MethodChannel('app.line/session');
  static final _owners = <Object, ({bool hosting, void Function() stop})>{};
  static Future<void> _tail = Future.value();
  static bool _registered = false;

  static Future<void> acquire(
    Object owner, {
    required bool hosting,
    required void Function() onStop,
  }) async {
    if (!Platform.isAndroid) return;
    if (!_registered) {
      _registered = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'stopRequested') {
          for (final item in List.of(_owners.values)) {
            item.stop();
          }
        }
      });
    }
    _owners[owner] = (hosting: hosting, stop: onStop);
    try {
      await _sync();
    } catch (_) {
      _owners.remove(owner);
      rethrow;
    }
  }

  static Future<void> transferring(Object owner) async {
    if (!Platform.isAndroid || !_owners.containsKey(owner)) return;
    _owners[owner] = (hosting: false, stop: _owners[owner]!.stop);
    await _sync();
  }

  static Future<void> release(Object owner) async {
    if (!Platform.isAndroid || _owners.remove(owner) == null) return;
    await _sync();
  }

  static Future<void> _sync() {
    final operation = _tail.then(
      (_) => _channel.invokeMethod<void>('setActive', {
        'active': _owners.isNotEmpty,
        'hosting': _owners.values.any((v) => v.hosting),
      }),
    );
    // Serialize start/stop even if the user cancels during native startup.
    _tail = operation.catchError((Object _) {});
    return operation;
  }
}
