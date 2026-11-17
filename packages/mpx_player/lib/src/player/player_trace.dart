import 'dart:developer' show Timeline;

import 'package:mpx_core/mpx_core.dart' show MediaKey;

/// Marks of a player's way from a lease to its first frame on screen, in the
/// timeline (a system trace of a profile build shows them as slices).
///
/// Each mark is a zero-length slice named `mpx.player <stage> <id>`, with
/// an optional detail after the id. Three ids follow one player:
///
/// - `k…`, the media key, on the pool's and the view's marks ([keyId]);
/// - `e…`, one engine, on the backend's marks; its `engine` mark names the
///   key it plays as its detail;
/// - `p…`, the platform player, on the platform's own marks; the engine's
///   `created` mark names it as its detail.
///
/// Always on in debug and profile builds, where a mark costs a string and
/// two timeline events, a handful per player; compiled out of release
/// builds.
abstract final class PlayerTrace {
  static const bool _enabled = !bool.fromEnvironment('dart.vm.product');

  /// Marks [stage] of the player [id], with [detail] after the id.
  static void mark(String stage, String id, [String? detail]) {
    if (!_enabled) return;
    Timeline.timeSync(
      detail == null
          ? 'mpx.player $stage $id'
          : 'mpx.player $stage $id $detail',
      _nothing,
    );
  }

  /// The id of [key] in the marks: stable for the process's lifetime.
  static String keyId(MediaKey key) =>
      'k${(key.hashCode & 0xffffffff).toRadixString(36)}';

  static void _nothing() {}
}
