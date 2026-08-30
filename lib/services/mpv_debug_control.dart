import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef MpvDebugHandler = Future<String> Function(String command);

/// Debug-only bridge for controlled ADB A/B tests of the active libmpv player.
/// Release builds still have no command receiver or player control surface.
abstract final class MpvDebugControl {
  static const _channel = MethodChannel('com.bili.tv/mpv_debug');
  static MpvDebugHandler? _handler;
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized || !kDebugMode) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'command') return 'unsupported';
      final command = call.arguments as String?;
      if (command == null || command.isEmpty) return 'invalid';
      final handler = _handler;
      if (handler == null) return 'no-active-player';
      return handler(command);
    });
  }

  static void attach(MpvDebugHandler handler) {
    if (kDebugMode) _handler = handler;
  }

  static void detach(MpvDebugHandler handler) {
    if (identical(_handler, handler)) _handler = null;
  }
}
