import 'dart:ui' show VoidCallback;

/// The reader asking for sound, to every surface that plays video: a rise of
/// the system volume says it, and each surface that is there (the feed's clips,
/// the reels) gives its video its sound.
///
/// One system for all of them, so a surface added later joins by listening
/// here, and the rule for what the reader's gesture means stays in one place.
final class SoundRequests {
  final Set<VoidCallback> _listeners = {};

  /// Calls [listener] on every request until the returned function is called.
  VoidCallback listen(VoidCallback listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Asks every surface for its sound.
  void request() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}
