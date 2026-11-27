/// A local file holding the whole of a content's bytes, lent by its keeper
/// (`TrackedTransfers.leaseFile`) until [release].
///
/// While the lease is held the keeper does not delete or move the file, so a
/// saver can copy from [path] at its own pace. [release] gives it back; it is
/// idempotent, and a lease that is never released keeps the file from
/// eviction for the life of the keeper.
final class ContentFileLease {
  /// Lends [path]; [onRelease] runs once, on the first [release].
  ContentFileLease({
    required this.path,
    required Future<void> Function() onRelease,
  }) : _onRelease = onRelease;

  /// Absolute path of the file.
  final String path;

  final Future<void> Function() _onRelease;
  bool _released = false;

  /// Whether [release] already ran.
  bool get isReleased => _released;

  /// Gives the file back to its keeper. Idempotent.
  Future<void> release() {
    if (_released) return Future<void>.value();
    _released = true;
    return _onRelease();
  }

  // The path is user content (it can name the file): it never goes into a
  // string a log may keep.
  @override
  String toString() => 'ContentFileLease(released: $_released)';
}
