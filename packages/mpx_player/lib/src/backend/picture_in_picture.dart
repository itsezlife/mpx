import 'package:flutter/foundation.dart';
import 'package:mpx_player/src/backend/player_backend.dart';

/// The platform's picture in picture as the player pool uses it: one engine
/// at a time keeps playing in a small system window over other apps.
///
/// Each `PlayerBackend` brings its platform's (Apple: the system window on a
/// hidden layer of the engine's player; Android: the activity's own picture
/// in picture, where the texture keeps playing). `NoPictureInPicture` where
/// there is none; `FakePictureInPicture` in `testing.dart`. Hosts go through
/// `PlayerPool.startPictureInPicture`, which keeps the player counted as
/// shown while the window is up.
abstract interface class PictureInPicture {
  /// Whether [start] can show a window on this device now.
  bool get isSupported;

  /// The engine shown in the window, or null when none is. Becomes null when
  /// the user closes the window (which pauses the engine) or returns to the
  /// app from it.
  ValueListenable<PlayerEngine?> get active;

  /// Moves [engine]'s picture into the window. Does nothing when
  /// [isSupported] is false or [engine] holds no picture yet.
  void start(PlayerEngine engine);

  /// Closes the window, if one is up.
  void stop();
}

/// A [PictureInPicture] for a platform without one.
final class NoPictureInPicture implements PictureInPicture {
  /// Creates a picture in picture that never starts.
  NoPictureInPicture();

  @override
  bool get isSupported => false;

  @override
  final ValueListenable<PlayerEngine?> active = ValueNotifier(null);

  @override
  void start(PlayerEngine engine) {}

  @override
  void stop() {}
}
