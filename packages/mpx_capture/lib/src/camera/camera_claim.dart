/// The one owner of the camera in this process, on the Dart side: a camera
/// session or a round video recording. Taking it releases the previous
/// owner first (a session turns closed, a recording fails as taken over);
/// the native side applies the same rule to the cameras themselves.
///
/// Internal to the package: `PlatformCameraSessions` and
/// `PlatformRoundVideoRecorder` take it; fakes share a `FakeCamera`.
abstract final class CameraClaim {
  static Object? _owner;
  static void Function()? _release;

  /// Makes [owner] the camera's owner; the previous owner's release runs
  /// first.
  static void take(Object owner, void Function() release) {
    final previous = _release;
    final previousOwner = _owner;
    _owner = owner;
    _release = release;
    if (previous != null && !identical(previousOwner, owner)) previous();
  }

  /// Gives the camera up when [owner] still holds it.
  static void drop(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _release = null;
  }
}
