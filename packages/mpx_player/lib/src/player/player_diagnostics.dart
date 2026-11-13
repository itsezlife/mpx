import 'package:flutter/foundation.dart';

/// The players' lifecycle log: engines made, platform players released and
/// why, failures, the pool's budget at work, the watchdog.
///
/// Off by default. A host that chases a playback problem on a device turns
/// it on ([enabled]); each line goes to [sink], `debugPrint` unless a host
/// routes it elsewhere, and reaches the device log in every build mode. The
/// platform players log their own side under the tag `mpx_player`.
abstract final class PlayerDiagnostics {
  /// Whether lines are logged.
  static bool enabled = false;

  /// Where a line goes.
  static void Function(String line) sink = _print;

  static void _print(String line) => debugPrint(line);

  /// Logs [message] when [enabled].
  static void log(String message) {
    if (enabled) sink('mpx_player: $message');
  }
}
