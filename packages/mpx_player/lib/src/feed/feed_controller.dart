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
  const FeedVisibility({required this.fraction, this.centreDistance = 0})
    : assert(fraction >= 0 && fraction <= 1, 'A fraction is within 0..1.');

  /// Nothing of the item shows.
  static const FeedVisibility hidden = FeedVisibility(fraction: 0);

  /// The share of the item's area that shows, 0 to 1.
  final double fraction;

  /// How far the item's centre is from its viewport's centre, in logical
  /// pixels; what breaks ties for the item in view.
  final double centreDistance;

  @override
  bool operator ==(Object other) =>
      other is FeedVisibility &&
      other.fraction == fraction &&
      other.centreDistance == centreDistance;

  @override
  int get hashCode => Object.hash(fraction, centreDistance);

  @override
  String toString() =>
      'FeedVisibility($fraction, centreDistance: $centreDistance)';
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
      identical(other.lease, lease);

  @override
  int get hashCode =>
      Object.hash(fraction, inView, autoplay, playing, muted, preload, lease);

  @override
  String toString() =>
      'FeedItemState(fraction: $fraction, inView: $inView, '
      'autoplay: ${autoplay?.name}, playing: $playing, muted: $muted, '
      'preload: $preload, lease: ${lease?.key})';
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
/// In list mode ([FeedMode.list]) a [FeedListPlanner] decides which visible
/// clips play muted and which item is in view. In pager mode
/// ([FeedMode.pager]) the most visible item above the policy's threshold is
/// the page that plays (the rule's [FeedActiveItemRule.pick]), whatever
/// pager shows it; a [FeedPager] over [pool] leases it and its warm
/// neighbours.
///
/// Items ahead are preloaded through [scope] with the spec of [presetOf],
/// as far as the plan's stage, and cancelled as the plan says. Facts of an
/// item come from its registration, or [itemOf] for items not built yet; an
/// item without facts is neither played nor preloaded.
///
/// [dispose] cancels every preload and releases every lease the controller
/// took; it disposes none of its inputs.
final class FeedController extends ChangeNotifier {
  /// Creates a controller.
  ///
  /// Pager mode needs [pool]; [initialIndex], [muted] and [onAdvance] are
  /// the pager's start page, mute and auto-advance callback.
  FeedController({
    this.policy = const FeedPolicy.list(),
    int? itemCount,
    this.itemOf,
    this.presetOf,
    AssetCacheScope? scope,
    this.pool,
    ValueListenable<FeedConditions>? conditions,
    int initialIndex = 0,
    bool muted = false,
    ValueChanged<int>? onAdvance,
  }) : assert(
         policy.mode == FeedMode.list || pool != null,
         'A pager-mode feed plays through a player pool.',
       ),
       _itemCount = itemCount,
       _scope = scope,
       _conditions = conditions {
    _conditions?.addListener(_replan);
    if (policy.mode == FeedMode.pager) {
      _inView.value = initialIndex;
      _pager = FeedPager(
        pool: pool!,
        itemCount: _boundedCount,
        itemOf: itemAt,
        policy: policy,
        conditions: conditions,
        initialIndex: initialIndex,
        muted: muted,
        onAdvance: onAdvance,
      )..addListener(_onPager);
    }
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
  FeedPager? _pager;
  int? _itemCount;
  AssetCacheScope? _scope;

  final Set<FeedSlotRegistration> _registrations = {};
  final Map<int, _StateNotifier> _notifiers = {};
  Map<int, FeedItemState> _states = const {};
  final Map<int, AssetPreload> _preloads = {};
  final ValueNotifier<int?> _inView = ValueNotifier(null);
  FeedListPlan? _listPlan;
  Map<int, FeedVisibility> _visible = const {};
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
    _pager?.itemCount = _boundedCount;
    _apply();
  }

  int get _boundedCount => _itemCount ?? _unbounded;

  /// The cache preloads go through, or null for none. Setting another
  /// cancels the preloads of the old one.
  AssetCacheScope? get scope => _scope;
  set scope(AssetCacheScope? value) {
    if (identical(value, _scope)) return;
    _cancelPreloads();
    _scope = value;
    _apply();
  }

  /// The item in view: the list's, or the pager's page that plays; null
  /// while a list has none.
  ValueListenable<int?> get inView => _inView;

  /// The pager that holds the leases, in pager mode.
  FeedPager? get pager => _pager;

  /// The list plan applied last, in list mode.
  FeedListPlan? get listPlan => _listPlan;

  /// Whether the feed plays without sound. In list mode clips play muted as
  /// the policy says ([FeedPolicy.mutedAutoplay]) and this cannot change it;
  /// in pager mode it applies to every lease.
  bool get muted => _pager?.muted ?? policy.mutedAutoplay;
  set muted(bool value) => _pager?.muted = value;

  /// The facts of the item at [index]: its registration's, else [itemOf]'s.
  FeedItem? itemAt(int index) {
    for (final registration in _registrations) {
      if (registration._index == index && registration._item != null) {
        return registration._item;
      }
    }
    return itemOf?.call(index);
  }

  /// The decision for the item at [index], live.
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
    markNeedsMeasure();
    return registration;
  }

  void _unregistered(FeedSlotRegistration registration) {
    if (_disposed) return;
    _registrations.remove(registration);
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
    final visible = <int, FeedVisibility>{};
    for (final registration in _registrations) {
      final seen = registration._read();
      final index = registration._index;
      final other = visible[index];
      // Two registrations of one index (a cell kept alive beside its
      // rebuilt copy): the more visible one counts.
      if (other == null || seen.fraction > other.fraction) {
        visible[index] = seen;
      }
    }
    visible.removeWhere((_, seen) => seen.fraction <= 0);
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

  void _replan() => _apply();

  void _onPager() {
    if (_applying) return;
    _applyPreloads();
    _publish();
  }

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
      final pager = _pager;
      if (pager == null) {
        _listPlan = FeedListPlanner(policy, conditions: _conditionsNow).plan(
          FeedListViewport(
            itemCount: _boundedCount,
            visible: fractions,
            centreDistances: centres,
            direction: _direction,
            fastScroll:
                _scope?.clock.pausedLayers.contains(
                  PlaybackPauseLayer.fastScroll,
                ) ??
                false,
          ),
          itemAt,
        );
        _inView.value = _listPlan!.inView;
      } else {
        final picked = policy.activeItem.pick(
          fractions,
          centreDistances: centres,
        );
        if (picked != null && picked != pager.index) {
          pager.show(picked);
        } else {
          // Facts may have arrived for the page or its neighbours.
          pager.replan();
        }
        _inView.value = pager.index;
      }
      _applyPreloads();
    } finally {
      _applying = false;
    }
    _publish();
  }

  FeedConditions get _conditionsNow =>
      _conditions?.value ?? const FeedConditions();

  Map<int, AssetPreloadStage> get _plannedPreloads =>
      _pager?.plan.preloads ?? _listPlan?.preloads ?? const {};

  Map<int, int> get _plannedDistances =>
      _pager?.plan.distances ?? _listPlan?.distances ?? const {};

  void _applyPreloads() {
    final scope = _scope;
    final presetOf = this.presetOf;
    if (scope == null || presetOf == null) return;
    final planned = _plannedPreloads;
    final pager = _pager;
    // A visible item, or the page that plays, is held by its cell.
    bool held(int index) =>
        _visible.containsKey(index) || (pager != null && index == pager.index);
    for (final index in _preloads.keys.toList()) {
      final wanted = planned[index];
      final current = _preloads[index]!;
      final drop =
          held(index) ||
          (wanted == null && policy.cancelOnLeave) ||
          (wanted != null && wanted != current.stage);
      if (drop) _preloads.remove(index)!.cancel();
    }
    final profile = pager == null ? policy.clipProfile() : const AssetProfile();
    for (final MapEntry(key: index, value: stage) in planned.entries) {
      if (_preloads.containsKey(index) || held(index)) continue;
      final item = itemAt(index);
      if (item == null) continue;
      _preloads[index] = scope.preload(
        item.key,
        presetOf(index, profile).spec,
        stage: stage,
        distance: _plannedDistances[index] ?? 0,
      );
    }
  }

  void _cancelPreloads() {
    for (final preload in _preloads.values) {
      preload.cancel();
    }
    _preloads.clear();
  }

  FeedItemState _stateAt(int index) =>
      _states[index] ?? FeedItemState(muted: muted);

  // Builds every non-default state, pushes it to the listened notifiers and
  // forgets the notifiers nobody listens to or registers any more.
  void _publish() {
    final pager = _pager;
    final indexes = <int>{
      ..._visible.keys,
      ..._preloads.keys,
      ..._plannedPreloads.keys,
      if (pager != null) pager.index,
      if (pager != null) ...pager.plan.warm,
    };
    final muted = this.muted;
    final states = <int, FeedItemState>{};
    for (final index in indexes) {
      final fraction = _visible[index]?.fraction ?? 0;
      final FeedAutoplay? autoplay;
      final bool playing;
      final bool inView;
      if (pager == null) {
        autoplay = _listPlan?.autoplay[index];
        playing = autoplay == FeedAutoplay.full;
        inView = _listPlan?.inView == index;
      } else {
        inView = pager.index == index;
        autoplay = inView ? pager.plan.autoplay : null;
        playing = inView && autoplay == FeedAutoplay.full;
      }
      states[index] = FeedItemState(
        fraction: fraction,
        inView: inView,
        autoplay: autoplay,
        playing: playing,
        muted: muted,
        preload: _preloads[index]?.stage ?? _plannedPreloads[index],
        lease: pager?.leaseOf(index),
      );
    }
    final changed = !mapEquals(states, _states);
    _states = states;
    final registered = {for (final r in _registrations) r._index};
    _notifiers.removeWhere(
      (index, notifier) => !notifier.listened && !registered.contains(index),
    );
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
    _cancelPreloads();
    _pager
      ?..removeListener(_onPager)
      ..dispose();
    for (final registration in _registrations) {
      registration._registered = false;
    }
    _registrations.clear();
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
