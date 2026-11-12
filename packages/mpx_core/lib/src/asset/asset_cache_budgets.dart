import 'package:meta/meta.dart';

/// Which budget an entry counts against.
enum AssetTier {
  /// Stills: one decoded frame, small and cheap to make again.
  still,

  /// Animations: frame buffers and decoder state, large and slow to make
  /// again. Budgeted apart so a screenful of animations cannot push every
  /// still out, and the reverse.
  animated,
}

/// Byte budgets of the unattached entries' cache, one per [AssetTier].
///
/// An entry with a live binding is pinned and counts toward its tier's bytes
/// but is never evicted, so a tier can exceed its budget while surfaces hold
/// more than it. The budget bounds what is kept for later (pager keep-alive,
/// scrolling back), not what is on screen.
///
/// ## Defaults
///
/// [AssetCacheBudgets.defaults] is 24 MiB of stills and 32 MiB of animations.
/// The still figure keeps a few screens of a scrolling grid of mid-size
/// stills: scrolling down and back, 24 MiB keeps all of the last four screens
/// of 192 px cells (24 a screen, 144 KiB each) and of 102 px cells (64 a
/// screen, 40 KiB each), where 16 MiB already misses one cell in twelve and
/// 12 MiB one in three.
///
/// The animated figure covers a grid that stays mounted while hidden and
/// keeps its pinned animations, about 35 cells of 160 px Lottie (about
/// 10 MiB) and 64 playing 99 px images (about 8 MiB), and leaves about two
/// more screens of animations for scrolling back with their positions. For scale, a 10 MiB animation cache charges an
/// animation only its two frame buffers and never recycles one a cell still
/// uses. Pinned bytes come out of the budget first,
/// so a surface that shows more than a tier's budget leaves nothing for
/// keep-alive; a host with another device class or layout sets its own.
@immutable
final class AssetCacheBudgets {
  /// Creates budgets of [stillBytes] and [animatedBytes].
  const AssetCacheBudgets({
    this.stillBytes = _defaultStillBytes,
    this.animatedBytes = _defaultAnimatedBytes,
  }) : assert(
         stillBytes >= 0 && animatedBytes >= 0,
         'budgets are not negative',
       );

  /// The documented defaults; see the class documentation.
  static const AssetCacheBudgets defaults = AssetCacheBudgets();

  static const int _defaultStillBytes = 24 * 1024 * 1024;
  static const int _defaultAnimatedBytes = 32 * 1024 * 1024;

  /// Bytes the still tier may keep unattached.
  final int stillBytes;

  /// Bytes the animated tier may keep unattached.
  final int animatedBytes;

  /// The budget of [tier].
  int of(AssetTier tier) => switch (tier) {
    AssetTier.still => stillBytes,
    AssetTier.animated => animatedBytes,
  };

  @override
  bool operator ==(Object other) =>
      other is AssetCacheBudgets &&
      other.stillBytes == stillBytes &&
      other.animatedBytes == animatedBytes;

  @override
  int get hashCode => Object.hash(stillBytes, animatedBytes);

  @override
  String toString() =>
      'AssetCacheBudgets(still: $stillBytes, animated: $animatedBytes)';
}
