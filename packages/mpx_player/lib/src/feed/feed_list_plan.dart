import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/feed/feed_item.dart';
import 'package:mpx_player/src/feed/feed_policy.dart';

/// Which way a feed scrolls, in item order.
enum FeedScrollDirection {
  /// Towards higher indexes.
  forward,

  /// Towards lower indexes.
  backward,
}

/// What a list sees of itself on one frame: which items show and how much,
/// and how it moves.
@immutable
final class FeedListViewport {
  /// Creates a snapshot.
  ///
  /// [visible] maps each index that shows to its visible fraction (above 0).
  /// [centreDistances] maps them to how far their centre is from the
  /// viewport's, in any unit, for the nearest-centre tie-break.
  const FeedListViewport({
    required this.itemCount,
    required this.visible,
    this.centreDistances = const {},
    this.direction = FeedScrollDirection.forward,
    this.fastScroll = false,
  });

  /// How many items the list has.
  final int itemCount;

  /// The visible fraction of each index that shows.
  final Map<int, double> visible;

  /// How far each visible item's centre is from the viewport's.
  final Map<int, double> centreDistances;

  /// The direction of the last scroll.
  final FeedScrollDirection direction;

  /// Whether the list scrolls fast: nothing heavy starts.
  final bool fastScroll;
}

/// What a list does on one frame: which clips play, which item is in view and
/// what preloads. Applying it is the list widget's job; computing it is pure.
@immutable
final class FeedListPlan {
  /// Creates a plan.
  const FeedListPlan({
    required this.autoplay,
    required this.inView,
    required this.preloads,
    this.distances = const {},
  });

  /// The autoplay decision of each visible index. A clip that is
  /// [FeedAutoplay.full] plays (muted, in list mode); its frames advance only
  /// above the advance floor, which the core applies per binding.
  final Map<int, FeedAutoplay> autoplay;

  /// The index in view, or null when none shows enough.
  final int? inView;

  /// The stage each index outside the visible ones preloads to. With
  /// `FeedPolicy.cancelOnLeave` everything else is cancelled.
  final Map<int, AssetPreloadStage> preloads;

  /// How many items each preloaded index is from the visible ones, 1 for the
  /// nearest; what orders preloads (`AssetCacheScope.preload`'s distance).
  final Map<int, int> distances;

  /// The visible indexes that play by themselves.
  Iterable<int> get playing => autoplay.entries
      .where((entry) => entry.value == FeedAutoplay.full)
      .map((entry) => entry.key);
}

/// Computes a [FeedListPlan] from a [FeedListViewport] under a list-mode
/// [FeedPolicy] and the device's [FeedConditions].
@immutable
final class FeedListPlanner {
  /// Creates a planner.
  const FeedListPlanner(
    this.policy, {
    this.conditions = const FeedConditions(),
  });

  /// The rules.
  final FeedPolicy policy;

  /// The device's conditions.
  final FeedConditions conditions;

  /// The plan for [viewport], with the facts of each index from [item].
  ///
  /// An index [item] knows nothing about (null) neither plays nor preloads:
  /// a host that registers its items as they are built has no facts for the
  /// ones further ahead. An index in [requested] is one the reader asked to
  /// play (a tap on its play button): it plays whatever the gate says.
  FeedListPlan plan(
    FeedListViewport viewport,
    FeedItem? Function(int index) item, {
    Set<int> requested = const {},
  }) {
    final facts = <int, FeedItem>{};
    final shown = <int, double>{};
    for (final MapEntry(:key, :value) in viewport.visible.entries) {
      if (value <= 0 || key < 0 || key >= viewport.itemCount) continue;
      final known = item(key);
      if (known == null) continue;
      facts[key] = known;
      shown[key] = value;
    }
    final autoplay = {
      for (final MapEntry(:key, :value) in facts.entries)
        key: requested.contains(key)
            ? FeedAutoplay.full
            : policy.autoplayOf(value, conditions),
    };
    final distances = <int, int>{};
    return FeedListPlan(
      autoplay: autoplay,
      inView: policy.activeItem.pick(
        shown,
        centreDistances: viewport.centreDistances,
      ),
      preloads: _preloads(shown.keys, viewport, item, distances),
      distances: distances,
    );
  }

  Map<int, AssetPreloadStage> _preloads(
    Iterable<int> shown,
    FeedListViewport viewport,
    FeedItem? Function(int index) item,
    Map<int, int> distances,
  ) {
    if (shown.isEmpty) return const {};
    final first = shown.reduce((a, b) => a < b ? a : b);
    final last = shown.reduce((a, b) => a > b ? a : b);
    final forward = viewport.direction == FeedScrollDirection.forward;
    final step = forward ? 1 : -1;
    final leading = forward ? last : first;
    final trailing = forward ? first : last;
    final window = policy.preloadWindow;
    final preloads = <int, AssetPreloadStage>{};
    void add(int index, int distance) {
      if (index < 0 || index >= viewport.itemCount) return;
      final stage = policy.preloadStaging(distance);
      if (stage == null) return;
      final facts = item(index);
      if (facts == null) return;
      preloads[index] = policy.boundPreload(
        stage,
        facts,
        conditions,
        fastScroll: viewport.fastScroll,
      );
      distances[index] = distance.abs();
    }

    for (var d = 1; d <= window.ahead; d++) {
      add(leading + d * step, d);
    }
    for (var d = 1; d <= window.behind; d++) {
      add(trailing - d * step, -d);
    }
    return preloads;
  }
}
