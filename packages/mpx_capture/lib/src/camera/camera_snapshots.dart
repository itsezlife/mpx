import 'dart:async';

import 'package:mpx_capture/src/camera/camera_session.dart';

/// Takers of a camera preview's last frame, run by a session before it
/// stops its frames (a pause) or changes its camera (a switch), so each
/// preview holds the frame the user saw before the texture moves on.
///
/// Internal to the package: `CameraPreview` registers, the sessions run.
abstract final class CameraSnapshots {
  static final Map<
    CameraSession,
    Set<Future<void> Function({required bool switching})>
  >
  _takers = {};

  /// How long a session waits for its previews at most.
  static const Duration wait = Duration(milliseconds: 150);

  /// Registers [take] for [session].
  static void add(
    CameraSession session,
    Future<void> Function({required bool switching}) take,
  ) => (_takers[session] ??= {}).add(take);

  /// Unregisters [take].
  static void remove(
    CameraSession session,
    Future<void> Function({required bool switching}) take,
  ) {
    final set = _takers[session];
    if (set == null) return;
    set.remove(take);
    if (set.isEmpty) _takers.remove(session);
  }

  /// Runs every taker of [session] and completes when all did, or after
  /// [wait].
  static Future<void> takeAll(
    CameraSession session, {
    required bool switching,
  }) async {
    final takers = _takers[session];
    if (takers == null || takers.isEmpty) return;
    await Future.wait([
      for (final take in [...takers]) take(switching: switching),
    ]).timeout(wait, onTimeout: () => const []);
  }
}
