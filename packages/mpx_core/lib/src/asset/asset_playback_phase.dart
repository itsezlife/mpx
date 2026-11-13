/// Where a content's animation is in its pass, shared by the entries of that
/// content, so the same content drawn at two sizes at once shows the same
/// frame.
///
/// The same content at two specs is two entries, each with its own
/// paintable and its own playback: a list item and the fullscreen copy of it
/// would otherwise play from two starts. The cache scope keeps one phase per
/// content key and hands it to every paint that animates
/// (`AssetPaintContext.phase`); a paintable that plays meets it in two ways:
///
/// - Each paint that steps it [report]s its position: how far into its pass
///   it is.
/// - The first paint that starts it, and a paint after its surfaces stopped
///   painting it while the clock ran on (drawn over, faded to nothing), take
///   the position another playback of the content is at ([positionFor])
///   instead of starting from the first frame or going on from the frame it
///   froze on.
///
/// A playback stopped on purpose goes on from its own frame, as before: one
/// its binding resumed (`AssetPaintable.playbackResumed`: held, hidden, off
/// screen) and one that plays its own pass (`AssetPaintable.rewind`). With
/// no other playback of the content, nothing changes either.
///
/// The last reporter's position is carried forward by the clock while its
/// entry plays: an entry still on the clock but not painted plays on, as far
/// as anyone joining it can tell. Once its entry stops playing ([stop]) the
/// position stays where it stopped.
///
/// Single-threaded, like the scope.
final class AssetPlaybackPhase {
  /// [position] wrapped into a pass of [passLength], which is positive: how
  /// far into its pass a playback that has played [position] is, or how far
  /// ahead a position is when [position] is a difference. Never negative.
  static Duration within(Duration position, Duration passLength) {
    assert(passLength > Duration.zero, 'a pass has a length');
    return Duration(
      microseconds: position.inMicroseconds % passLength.inMicroseconds,
    );
  }

  Object? _reporter;
  Duration _position = Duration.zero;
  Duration _at = Duration.zero;
  bool _running = false;

  /// Records that [reporter] is [position] into its pass at clock time [now].
  void report(Object reporter, Duration position, Duration now) {
    _reporter = reporter;
    _position = position;
    _at = now;
    _running = true;
  }

  /// Says that [reporter] stopped playing at clock time [now]: its position
  /// is held where it got to. Nothing for another reporter.
  void stop(Object reporter, Duration now) {
    if (!identical(reporter, _reporter) || !_running) return;
    _position = _carried(now);
    _at = now;
    _running = false;
  }

  /// The position the last other playback of the content reached by clock
  /// time [now], or null when only [joiner] reported, or nobody.
  ///
  /// It may lie past the end of a pass: the joiner wraps it by its own pass
  /// length.
  Duration? positionFor(Object joiner, Duration now) {
    if (_reporter == null || identical(_reporter, joiner)) return null;
    return _running ? _carried(now) : _position;
  }

  Duration _carried(Duration now) {
    final step = now - _at;
    return step.isNegative ? _position : _position + step;
  }
}
