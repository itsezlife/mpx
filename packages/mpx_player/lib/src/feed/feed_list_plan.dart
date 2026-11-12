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
  FeedListPlan plan(
    FeedListViewport viewport,
    FeedItem Function(int index) item,
  ) {
    final shown = {
      for (final MapEntry(:key, :value) in viewport.visible.entries)
        if (value > 0 && key >= 0 && key < viewport.itemCount) key: value,
    };
    final autoplay = {
      for (final index in shown.keys)
        index: policy.autoplayOf(item(index), conditions),
    };
    final distances = <int, int>{};
    return FeedListPlan(
      autoplay: autoplay,
      inView: _inView(shown, viewport.centreDistances),
      preloads: _preloads(shown.keys, viewport, item, distances),
      distances: distances,
    );
  }

  int? _inView(Map<int, double> shown, Map<int, double> centres) {
    final rule = policy.activeItem;
    int? best;
    for (final MapEntry(key: index, value: fraction) in shown.entries) {
      if (fraction < rule.minVisibleFraction) continue;
      if (best == null || _beats(index, best, shown, centres)) best = index;
    }
    return best;
  }

  bool _beats(
    int candidate,
    int current,
    Map<int, double> shown,
    Map<int, double> centres,
  ) {
    final byFraction = shown[candidate]!.compareTo(shown[current]!);
    final byCentre = (centres[current] ?? double.infinity).compareTo(
      centres[candidate] ?? double.infinity,
    );
    final (first, second) = switch (policy.activeItem.tieBreak) {
      FeedTieBreak.mostVisible => (byFraction, byCentre),
      FeedTieBreak.nearestCentre => (byCentre, byFraction),
    };
    if (first != 0) return first > 0;
    if (second != 0) return second > 0;
    // A full tie goes to the earlier item.
    return candidate < current;
  }

  Map<int, AssetPreloadStage> _preloads(
    Iterable<int> shown,
    FeedListViewport viewport,
    FeedItem Function(int index) item,
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
      preloads[index] = _bounded(stage, item(index), viewport.fastScroll);
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

  // What the gate and the scroll speed leave of [stage]: an item that will
  // not play gets its metadata only; one that gets a prefix at most the
  // prefix; nothing heavier than a first frame starts during a fast scroll.
  AssetPreloadStage _bounded(
    AssetPreloadStage stage,
    FeedItem item,
    bool fastScroll,
  ) {
    var bounded = switch (policy.autoplayOf(item, conditions)) {
      FeedAutoplay.none => AssetPreloadStage.metadata,
      FeedAutoplay.prefixOnly => _atMostPrefix(stage),
      FeedAutoplay.full => stage,
    };
    if (fastScroll && bounded is AssetPreloadStage$Seconds) {
      bounded = AssetPreloadStage.metadata;
    }
    return bounded;
  }

  AssetPreloadStage _atMostPrefix(AssetPreloadStage stage) {
    final prefix = policy.oversizePrefix;
    if (prefix == null) return AssetPreloadStage.metadata;
    final cap = AssetPreloadStage.seconds(prefix.duration);
    return stage.compareTo(cap) <= 0 ? stage : cap;
  }
}
