/// The camera that fakes share, so a `FakeCameraSessions` and a
/// `FakeRoundVideoRecorder` built over one apply the one-owner rule to each
/// other: taking it releases the previous owner first.
final class FakeCamera {
  Object? _owner;
  void Function()? _release;

  /// The current owner, if any.
  Object? get owner => _owner;

  /// Makes [owner] the owner; the previous owner's release runs first.
  void take(Object owner, void Function() release) {
    final previous = _release;
    final previousOwner = _owner;
    _owner = owner;
    _release = release;
    if (previous != null && !identical(previousOwner, owner)) previous();
  }

  /// Gives the camera up when [owner] still holds it.
  void drop(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _release = null;
  }
}
