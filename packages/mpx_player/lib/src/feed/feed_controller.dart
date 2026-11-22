import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/feed/feed_item.dart';
import 'package:mpx_player/src/feed/feed_list_plan.dart';
import 'package:mpx_player/src/feed/feed_pager.dart';
import 'package:mpx_player/src/feed/feed_policy.dart';
import 'package:mpx_player/src/pool/player_pool.dart';

/// How much of one item its viewport shows, as the item measured it.
@immutable
final class FeedVisibility {
  /// Creates a measurement.
  const FeedVisibility({
    required this.fraction,
    this.centreDistance = 0,
    this.viewportsAway = 0,
  }) : assert(fraction >= 0 && fraction <= 1, 'A fraction is within 0..1.'),
       assert(viewportsAway >= 0, 'A distance is not negative.');

  /// Nothing of the item shows, and it is nowhere near view.
  static const FeedVisibility hidden = FeedVisibility(
    fraction: 0,
    viewportsAway: double.infinity,
  );

  /// The share of the item's area that shows, 0 to 1.
  final double fraction;

  /// How far the item's centre is from its viewport's centre, in logical
  /// pixels; what breaks ties for the item in view.
  final double centreDistance;

  /// How far the item is from view, in viewports of the closest one: 0 while
  /// any of it shows, infinite when it is not painted at all. The policy's
  /// heavy-unload distance reads it.
  final double viewportsAway;

  @override
  bool operator ==(Object other) =>
      other is FeedVisibility &&
      other.fraction == fraction &&
      other.centreDistance == centreDistance &&
      other.viewportsAway == viewportsAway;

  @override
  int get hashCode => Object.hash(fraction, centreDistance, viewportsAway);

  @override
  String toString() =>
      'FeedVisibility($fraction, centreDistance: $centreDistance, '
      'viewportsAway: $viewportsAway)';
}

/// Reads an item's visibility now; a [FeedController] calls it once per
/// measure, after layout.
typedef FeedMeasure = FeedVisibility Function();

/// What a [FeedController] decided for one item: everything a host needs to
/// draw the item's cell.
@immutable
final class FeedItemState {
  /// Creates a state.
  const FeedItemState({
    this.fraction = 0,
    this.inView = false,
    this.autoplay,
    this.playing = false,
    this.muted = true,
    this.preload,
    this.lease,
    this.clip,
    this.released = false,
  });

  /// How much of the item shows, 0 to 1. A clip below the policy's advance
  /// floor keeps its frame.
  final double fraction;

  /// Whether the item is the one in view: the list's item in view, or the
  /// pager's page that plays.
  final bool inView;

  /// What the autoplay gate allows for the item, or null while it is neither
  /// visible nor the pager's page.
  final FeedAutoplay? autoplay;

  /// Whether the item plays by itself: in list mode a visible clip the gate
  /// lets play (on the software path, muted); in pager mode the page that
  /// plays (through [lease]).
  final bool playing;

  /// Whether the item plays without sound.
  final bool muted;

  /// The stage the item is preloaded to, or null when it is not preloaded.
  final AssetPreloadStage? preload;

  /// The player the item plays or is kept warm on (pager mode), or null.
  final PlayerLease? lease;

  /// The profile the item's clip attaches to the asset cache with, or null
  /// where the cell shows a player or its still (pager mode). In list mode
  /// the policy's clip profile, held on its frame while it does not play.
  final AssetProfile? clip;

  /// Whether the item is further from view than the policy's heavy-unload
  /// distance: its cell drops its decoder and frames and shows its poster.
  final bool released;

  /// Whether any of the item shows.
  bool get visible => fraction > 0;

  @override
  bool operator ==(Object other) =>
      other is FeedItemState &&
      other.fraction == fraction &&
      other.inView == inView &&
      other.autoplay == autoplay &&
      other.playing == playing &&
      other.muted == muted &&
      other.preload == preload &&
      identical(other.lease, lease) &&
      other.clip == clip &&
      other.released == released;

  @override
  int get hashCode => Object.hash(
    fraction,
    inView,
    autoplay,
    playing,
    muted,
    preload,
    lease,
    clip,
    released,
  );

  @override
  String toString() =>
      'FeedItemState(fraction: $fraction, inView: $inView, '
      'autoplay: ${autoplay?.name}, playing: $playing, muted: $muted, '
      'preload: $preload, lease: ${lease?.key}, clip: $clip, '
      'released: $released)';
}

/// One item a host shows, registered with a [FeedController]: its index, its
/// facts and how to measure it. A `FeedSlot` holds one for its child.
final class FeedSlotRegistration {
  FeedSlotRegistration._(this.controller, this._index, this._item, this._read);

  /// The controller it is registered with.
  final FeedController controller;

  int _index;
  FeedItem? _item;
  final FeedMeasure _read;
  bool _registered = true;

  /// The item's index.
  int get index => _index;

  /// The item's facts, or null for the controller's `itemOf`.
  FeedItem? get item => _item;

  /// Whether it still counts.
  bool get isRegistered => _registered;

  /// The controller's decision for [index].
  ValueListenable<FeedItemState> get state => controller.stateOf(_index);

  /// Moves the registration to [index] with [item]: a recycled cell that
  /// shows another item now.
  void update({required int index, FeedItem? item}) {
    if (!_registered || (index == _index && item == _item)) return;
    controller._moved(this, from: _index, to: index);
    _index = index;
    _item = item;
    controller.markNeedsMeasure();
  }

  /// Asks the controller to measure every item after this frame: the item
  /// moved, resized or its viewport scrolled.
  void markNeedsMeasure() {
    if (_registered) controller.markNeedsMeasure();
  }

  /// Stops counting the item. Idempotent.
  void unregister() {
    if (!_registered) return;
    _registered = false;
    controller._unregistered(this);
  }
}

/// Plays a feed inside any host scrollable: the host registers the items it
/// shows (a `FeedSlot` does it for a widget), the controller measures them
/// once per frame that needs it, plans under its [policy] and applies the
/// plan, and each item's decision is a [ValueListenable] the host draws its
/// cell from ([stateOf]).
///
/// The policy's mode picks how it plans. In list mode ([FeedMode.list]) a
/// [FeedListPlanner] decides which visible clips play muted and which item
/// is in view ([listPlan]). In pager mode ([FeedMode.pager]) the most
/// visible item above the policy's threshold is the page that plays (the
/// rule's [FeedActiveItemRule.pick]), whatever pager shows it; a [FeedPager]
/// over [pool] leases it and its warm neighbours and holds the session's
/// mute ([pager]).
///
/// Items ahead are preloaded through [scope] with the spec of [presetOf],
/// as far as the plan's stage, and cancelled as the plan says. Facts of an
/// item come from its registration, or [itemOf] for items not built yet; an
/// item without facts is neither played nor preloaded. While a layer of the
/// policy's [FeedPolicy.pausingLayers] is set on the scope's clock nothing
/// plays, and while one of its [FeedPolicy.preloadBackOffLayers] is set no
/// preload starts. A registered item further from view than the policy's
/// heavy-unload distance is [FeedItemState.released].
///
/// [dispose] cancels every preload and releases every lease the controller
/// took; it disposes none of its inputs.
final class FeedController extends ChangeNotifier {
  /// Creates a controller.
  ///
  /// Pager mode needs [pool]; [initialIndex], [muted] and [onAdvance] are
  /// the pager's start page, starting mute (the policy's initial mute when
  /// null) and auto-advance callback, and only a pager takes them.
  FeedController({
    this.policy = const FeedPolicy.list(),
    int? itemCount,
    this.itemOf,
    this.presetOf,
    AssetCacheScope? scope,
    this.pool,
    ValueListenable<FeedConditions>? conditions,
    int initialIndex = 0,
    bool? muted,
    ValueChanged<int>? onAdvance,
  }) : assert(
         policy.mode == FeedMode.list || pool != null,
         'A pager-mode feed plays through a player pool.',
       ),
       assert(
         policy.mode == FeedMode.pager ||
             (initialIndex == 0 && muted == null && onAdvance == null),
         'Only a pager takes a start page, a mute or an advance callback; '
         'list clips play as the policy says.',
       ),
       _itemCount = itemCount,
       _conditions = conditions {
    _mode = switch (policy.mode) {
      FeedMode.list => _ListMode(this),
      FeedMode.pager => _PagerMode(
        this,
        FeedPager(
          pool: pool!,
          itemCount: _boundedCount,
          itemOf: itemAt,
          policy: policy,
          conditions: conditions,
          initialIndex: initialIndex,
          muted: muted,
          onAdvance: onAdvance,
        ),
      ),
    };
    _conditions?.addListener(_replan);
    _follow(scope);
    _apply();
  }

  /// A count that never bounds a feed whose length the host did not give.
  static const int _unbounded = 1 << 30;

  /// The rules.
  final FeedPolicy policy;

  /// The facts of items not registered yet (the ones ahead), or null when
  /// only registered items count.
  final FeedItem? Function(int index)? itemOf;

  /// The size and decode of an item under a profile: the spec preloads use,
  /// and what a clip of the item attaches with. No preloads when null.
  final AssetPreset Function(int index, AssetProfile profile)? presetOf;

  /// The players of pager mode.
  final PlayerPool? pool;

  final ValueListenable<FeedConditions>? _conditions;
  late final _FeedMode _mode;
  int? _itemCount;
  AssetCacheScope? _scope;

  final Set<FeedSlotRegistration> _registrations = {};
  // The registrations of each index, for the facts lookups the planners make
  // once per index they consider.
  final Map<int, List<FeedSlotRegistration>> _byIndex = {};
  final Map<int, _StateNotifier> _notifiers = {};
  Map<int, FeedItemState> _states = const {};
  final Map<int, AssetPreload> _preloads = {};
  final ValueNotifier<int?> _inView = ValueNotifier(null);
  Map<int, FeedVisibility> _visible = const {};
  Set<int> _released = const {};
  double? _centroid;
  FeedScrollDirection _direction = FeedScrollDirection.forward;
  bool _measureScheduled = false;
  bool _disposed = false;

  /// How many items the feed has, or null for a feed bounded only by what
  /// [itemOf] knows. Setting it plans again.
  int? get itemCount => _itemCount;
  set itemCount(int? value) {
    if (value == _itemCount) return;
    _itemCount = value;
    _mode.countChanged();
    _apply();
  }

  int get _boundedCount => _itemCount ?? _unbounded;

  /// The cache preloads go through, or null for none. Setting another
  /// cancels the preloads of the old one.
  AssetCacheScope? get scope => _scope;
  set scope(AssetCacheScope? value) {
    if (identical(value, _scope)) return;
    _cancelPreloads();
    _follow(value);
    _apply();
  }

  /// The item in view: the list's, or the pager's page that plays; null
  /// while a list has none.
  ValueListenable<int?> get inView => _inView;

  /// The pager that holds the leases and the session's mute, in pager mode;
  /// null in list mode, where clips play muted as the policy says.
  FeedPager? get pager => switch (_mode) {
    _PagerMode(:final pager) => pager,
    _ListMode() => null,
  };

  /// The list plan applied last, in list mode; null in pager mode.
  FeedListPlan? get listPlan => switch (_mode) {
    _ListMode(:final last) => last,
    _PagerMode() => null,
  };

  /// The facts of the item at [index]: its registration's, else [itemOf]'s.
  FeedItem? itemAt(int index) {
    for (final registration
        in _byIndex[index] ?? const <FeedSlotRegistration>[]) {
      final item = registration._item;
      if (item != null) return item;
    }
    return itemOf?.call(index);
  }

  /// The decision for the item at [index], live.
  ///
  /// Listen to it at once: a decision nobody listens to and no registration
  /// holds is dropped (and disposed) the next time the controller plans.
  ValueListenable<FeedItemState> stateOf(int index) =>
      _notifiers.putIfAbsent(index, () => _StateNotifier(_stateAt(index)));

  /// Registers an item shown at [index], measured by [measure] after every
  /// frame that needs it. [item] gives its facts; without it [itemOf] does.
  FeedSlotRegistration register(
    int index, {
    required FeedMeasure measure,
    FeedItem? item,
  }) {
    assert(!_disposed, 'FeedController.register called after dispose.');
    final registration = FeedSlotRegistration._(this, index, item, measure);
    _registrations.add(registration);
    (_byIndex[index] ??= []).add(registration);
    markNeedsMeasure();
    return registration;
  }

  void _moved(
    FeedSlotRegistration registration, {
    required int from,
    required int to,
  }) {
    _forgetIndex(registration, from);
    (_byIndex[to] ??= []).add(registration);
  }

  void _forgetIndex(FeedSlotRegistration registration, int index) {
    final at = _byIndex[index];
    if (at == null) return;
    at.remove(registration);
    if (at.isEmpty) _byIndex.remove(index);
  }

  void _unregistered(FeedSlotRegistration registration) {
    if (_disposed) return;
    _registrations.remove(registration);
    _forgetIndex(registration, registration._index);
    markNeedsMeasure();
  }

  /// Measures every registered item after this frame's layout, once however
  /// many ask.
  void markNeedsMeasure() {
    if (_measureScheduled || _disposed) return;
    _measureScheduled = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _measureScheduled = false;
        measure();
      }, debugLabel: 'FeedController.measure')
      ..ensureVisualUpdate();
  }

  /// Measures every registered item now and applies the plan. For a host
  /// whose items know their visibility without a layout, and for tests.
  void measure() {
    if (_disposed) return;
    final seen = <int, FeedVisibility>{};
    for (final registration in _registrations) {
      final read = registration._read();
      final index = registration._index;
      final other = seen[index];
      // Two registrations of one index (a cell kept alive beside its
      // rebuilt copy): the more visible, or nearer, one counts.
      if (other == null ||
          read.fraction > other.fraction ||
          (read.fraction == other.fraction &&
              read.viewportsAway < other.viewportsAway)) {
        seen[index] = read;
      }
    }
    _released = {
      for (final MapEntry(:key, :value) in seen.entries)
        if (value.viewportsAway > policy.heavyUnloadViewports) key,
    };
    final visible = seen..removeWhere((_, read) => read.fraction <= 0);
    _direction = _directionTo(visible);
    _visible = visible;
    _apply();
  }

  // The visible items' centroid, weighted by fraction, moves the way the
  // feed scrolls: higher indexes forward. It needs no axis, offset or extent,
  // so it works for grids and nested lists alike.
  FeedScrollDirection _directionTo(Map<int, FeedVisibility> visible) {
    if (visible.isEmpty) return _direction;
    var weight = 0.0;
    var sum = 0.0;
    for (final MapEntry(:key, :value) in visible.entries) {
      weight += value.fraction;
      sum += key * value.fraction;
    }
    final centroid = sum / weight;
    final previous = _centroid;
    _centroid = centroid;
    if (previous == null || centroid == previous) return _direction;
    return centroid > previous
        ? FeedScrollDirection.forward
        : FeedScrollDirection.backward;
  }

  // --- Clock layers ---------------------------------------------------------

  // The scope's clock carries the pause layers the policy reads; the feed
  // plans again whenever they change.
  void _follow(AssetCacheScope? scope) {
    _scope?.clock.removeLayerListener(_replan);
    _scope = scope;
    scope?.clock.addLayerListener(_replan);
  }

  bool _layerSet(Set<PlaybackPauseLayer> layers) =>
      _scope?.clock.pausedLayers.any(layers.contains) ?? false;

  // Whether a pausing layer of the policy stops everything that plays.
  bool get _paused => _layerSet(policy.pausingLayers);

  // Whether a back-off layer of the policy holds new preloads.
  bool get _backingOff => _layerSet(policy.preloadBackOffLayers);

  bool get _fastScroll =>
      _scope?.clock.pausedLayers.contains(PlaybackPauseLayer.fastScroll) ??
      false;

  // --- Plan and apply -------------------------------------------------------

  void _replan() => _apply();

  bool _applying = false;

  void _apply() {
    if (_disposed) return;
    _applying = true;
    try {
      final fractions = {
        for (final MapEntry(:key, :value) in _visible.entries)
          key: value.fraction,
      };
      final centres = {
        for (final MapEntry(:key, :value) in _visible.entries)
          key: value.centreDistance,
      };
      _inView.value = _mode.planFor(fractions, centres);
      _applyPreloads();
    } finally {
      _applying = false;
    }
    _publish();
  }

  // The pager changed by itself (an advance, its mute): its preloads and
  // decisions follow.
  void _onPager() {
    if (_applying) return;
    _applyPreloads();
    _publish();
  }

  FeedConditions get _conditionsNow =>
      _conditions?.value ?? const FeedConditions();

  void _applyPreloads() {
    final scope = _scope;
    final presetOf = this.presetOf;
    if (scope == null || presetOf == null) return;
    final planned = _mode.preloads;
    // A visible item, or the page that plays, is held by its cell.
    bool held(int index) => _visible.containsKey(index) || _mode.holds(index);
    for (final index in _preloads.keys.toList()) {
      final wanted = planned[index];
      final current = _preloads[index]!;
      final drop =
          held(index) ||
          (wanted == null && policy.cancelOnLeave) ||
          (wanted != null && wanted != current.stage);
      if (drop) _preloads.remove(index)!.cancel();
    }
    if (_backingOff) return;
    final profile = _mode.preloadProfile;
    final distances = _mode.distances;
    for (final MapEntry(key: index, value: stage) in planned.entries) {
      if (_preloads.containsKey(index) || held(index)) continue;
      final item = itemAt(index);
      if (item == null) continue;
      _preloads[index] = scope.preload(
        item.key,
        presetOf(index, profile).spec,
        stage: stage,
        distance: distances[index] ?? 0,
      );
    }
  }

  void _cancelPreloads() {
    for (final preload in _preloads.values) {
      preload.cancel();
    }
    _preloads.clear();
  }

  FeedItemState _stateAt(int index) => _states[index] ?? _mode.idle;

  // Builds every non-default state, pushes it to the listened notifiers and
  // drops (and disposes) the notifiers nobody listens to or registers any
  // more.
  void _publish() {
    final planned = _mode.preloads;
    final indexes = <int>{
      ..._visible.keys,
      ..._released,
      ..._preloads.keys,
      ...planned.keys,
      ..._mode.decided,
    };
    final paused = _paused;
    final states = <int, FeedItemState>{
      for (final index in indexes)
        index: _mode.stateOf(
          index,
          fraction: _visible[index]?.fraction ?? 0,
          paused: paused,
          preload: _preloads[index]?.stage ?? planned[index],
          released: _released.contains(index),
        ),
    };
    final changed = !mapEquals(states, _states);
    _states = states;
    _notifiers.removeWhere((index, notifier) {
      if (notifier.listened || _byIndex.containsKey(index)) return false;
      notifier.dispose();
      return true;
    });
    for (final MapEntry(key: index, value: notifier) in _notifiers.entries) {
      notifier.value = _stateAt(index);
    }
    if (changed) notifyListeners();
  }

  /// Cancels every preload and releases every lease the controller holds.
  /// Idempotent.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _conditions?.removeListener(_replan);
    _follow(null);
    _cancelPreloads();
    _mode.dispose();
    for (final registration in _registrations) {
      registration._registered = false;
    }
    _registrations.clear();
    _byIndex.clear();
    for (final notifier in _notifiers.values) {
      notifier.dispose();
    }
    _notifiers.clear();
    _inView.dispose();
    super.dispose();
  }
}

final class _StateNotifier extends ValueNotifier<FeedItemState> {
  _StateNotifier(super.value);

  bool get listened => hasListeners;
}

// --- Modes ------------------------------------------------------------------

// How a feed plans and what it decides per item: one strategy per
// `FeedMode`, so the controller holds the shared work (measure, preloads,
// notifiers) and never branches on the mode.
sealed class _FeedMode {
  _FeedMode(this.feed);

  final FeedController feed;

  FeedPolicy get policy => feed.policy;

  // Plans for the visible items; returns the item in view.
  int? planFor(Map<int, double> fractions, Map<int, double> centres);

  Map<int, AssetPreloadStage> get preloads;

  Map<int, int> get distances;

  // The profile a preload's spec is computed under.
  AssetProfile get preloadProfile;

  // Whether a cell holds [index]'s media whatever its visibility (the
  // pager's page), so a preload of it would be a second hold.
  bool holds(int index);

  // Indexes with a decision besides the visible and preloaded ones.
  Iterable<int> get decided;

  // The decision for an index with nothing decided.
  FeedItemState get idle;

  FeedItemState stateOf(
    int index, {
    required double fraction,
    required bool paused,
    required AssetPreloadStage? preload,
    required bool released,
  });

  void countChanged() {}

  void dispose() {}
}

// Every visible clip the gate lets play plays muted on the software path.
final class _ListMode extends _FeedMode {
  _ListMode(super.feed);

  FeedListPlan? last;

  late final AssetProfile _playing = policy.clipProfile();
  late final AssetProfile _still = _playing.copyWith(animate: false);

  @override
  int? planFor(Map<int, double> fractions, Map<int, double> centres) {
    final next = FeedListPlanner(policy, conditions: feed._conditionsNow).plan(
      FeedListViewport(
        itemCount: feed._boundedCount,
        visible: fractions,
        centreDistances: centres,
        direction: feed._direction,
        fastScroll: feed._fastScroll,
      ),
      feed.itemAt,
    );
    last = next;
    return next.inView;
  }

  @override
  Map<int, AssetPreloadStage> get preloads => last?.preloads ?? const {};

  @override
  Map<int, int> get distances => last?.distances ?? const {};

  @override
  AssetProfile get preloadProfile => _playing;

  @override
  bool holds(int index) => false;

  @override
  Iterable<int> get decided => const [];

  @override
  FeedItemState get idle =>
      FeedItemState(muted: policy.mutedAutoplay, clip: _still);

  @override
  FeedItemState stateOf(
    int index, {
    required double fraction,
    required bool paused,
    required AssetPreloadStage? preload,
    required bool released,
  }) {
    final autoplay = last?.autoplay[index];
    final playing = autoplay == FeedAutoplay.full && !paused;
    return FeedItemState(
      fraction: fraction,
      inView: last?.inView == index,
      autoplay: autoplay,
      playing: playing,
      muted: policy.mutedAutoplay,
      preload: preload,
      clip: released ? null : (playing ? _playing : _still),
      released: released,
    );
  }
}

// One page plays with sound through the pager's leases; its neighbours stay
// warm.
final class _PagerMode extends _FeedMode {
  _PagerMode(super.feed, this.pager) {
    pager.addListener(feed._onPager);
  }

  final FeedPager pager;

  @override
  int? planFor(Map<int, double> fractions, Map<int, double> centres) {
    pager.pausedByPolicy = feed._paused;
    final picked = policy.activeItem.pick(fractions, centreDistances: centres);
    if (picked != null && picked != pager.index) {
      pager.show(picked);
    } else {
      // Facts may have arrived for the page or its neighbours.
      pager.replan();
    }
    return pager.index;
  }

  @override
  Map<int, AssetPreloadStage> get preloads => pager.plan.preloads;

  @override
  Map<int, int> get distances => pager.plan.distances;

  @override
  AssetProfile get preloadProfile => const AssetProfile();

  @override
  bool holds(int index) => index == pager.index;

  @override
  Iterable<int> get decided => [pager.index, ...pager.plan.warm];

  @override
  FeedItemState get idle => FeedItemState(muted: pager.muted);

  @override
  FeedItemState stateOf(
    int index, {
    required double fraction,
    required bool paused,
    required AssetPreloadStage? preload,
    required bool released,
  }) {
    final inView = pager.index == index;
    final autoplay = inView ? pager.plan.autoplay : null;
    return FeedItemState(
      fraction: fraction,
      inView: inView,
      autoplay: autoplay,
      playing: inView && autoplay == FeedAutoplay.full && !paused,
      muted: pager.muted,
      preload: preload,
      lease: pager.leaseOf(index),
      released: released && pager.leaseOf(index) == null,
    );
  }

  @override
  void countChanged() => pager.itemCount = feed._boundedCount;

  @override
  void dispose() {
    pager
      ..removeListener(feed._onPager)
      ..dispose();
  }
}
