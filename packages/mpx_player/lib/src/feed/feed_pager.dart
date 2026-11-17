import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/feed/feed_item.dart';
import 'package:mpx_player/src/feed/feed_policy.dart';
import 'package:mpx_player/src/player/player_state.dart';
import 'package:mpx_player/src/pool/player_pool.dart';

/// What a pager does on one page: which item plays, which neighbours hold a
/// prepared player and what preloads. Computing it is pure
/// ([FeedPagerPlanner]); applying it is [FeedPager]'s job.
@immutable
final class FeedPagerPlan {
  /// Creates a plan.
  const FeedPagerPlan({
    required this.active,
    required this.autoplay,
    required this.warm,
    required this.preloads,
    required this.distances,
  });

  /// The page shown: the one item that plays, with sound.
  final int active;

  /// What the autoplay gate allows for [active].
  final FeedAutoplay autoplay;

  /// The neighbours that hold a prepared player, nearest first and, at equal
  /// distance, ahead before behind.
  final List<int> warm;

  /// The preload stage of each neighbour in the window.
  final Map<int, AssetPreloadStage> preloads;

  /// How far each preloaded neighbour is from [active].
  final Map<int, int> distances;
}

/// Computes a [FeedPagerPlan] under a pager-mode [FeedPolicy] and the
/// device's [FeedConditions].
@immutable
final class FeedPagerPlanner {
  /// Creates a planner.
  const FeedPagerPlanner(
    this.policy, {
    this.conditions = const FeedConditions(),
  });

  /// The rules.
  final FeedPolicy policy;

  /// The device's conditions.
  final FeedConditions conditions;

  /// The plan for the page at [index] of [itemCount], with the facts of each
  /// index from [item].
  ///
  /// At most [preparedCap] neighbours (the pool's prepared budget, which the
  /// device class bounds) and at most the policy's prepared players are
  /// warmed; only neighbours inside the preload window that the gate lets
  /// play in full get one. An index [item] knows nothing about (null) is
  /// neither warmed nor preloaded, and an unknown [index] does not play.
  FeedPagerPlan plan({
    required int index,
    required int itemCount,
    required FeedItem? Function(int index) item,
    int? preparedCap,
  }) {
    final window = policy.preloadWindow;
    final cap = math.min(policy.preparedPlayers, preparedCap ?? 1 << 30);
    final warm = <int>[];
    final preloads = <int, AssetPreloadStage>{};
    final distances = <int, int>{};
    final reach = math.max(window.ahead, window.behind);
    for (var d = 1; d <= reach; d++) {
      for (final signed in [
        if (d <= window.ahead) d,
        if (d <= window.behind) -d,
      ]) {
        final neighbour = index + signed;
        if (neighbour < 0 || neighbour >= itemCount) continue;
        final facts = item(neighbour);
        if (facts == null) continue;
        if (warm.length < cap &&
            policy.autoplayOf(facts, conditions) == FeedAutoplay.full) {
          warm.add(neighbour);
        }
        final stage = policy.preloadStaging(signed);
        if (stage == null) continue;
        preloads[neighbour] = policy.boundPreload(stage, facts, conditions);
        distances[neighbour] = d;
      }
    }
    final active = item(index);
    return FeedPagerPlan(
      active: index,
      autoplay: active == null
          ? FeedAutoplay.none
          : policy.autoplayOf(active, conditions),
      warm: warm,
      preloads: preloads,
      distances: distances,
    );
  }
}

/// Plays a pager over a [PlayerPool]: the page shown plays with sound and
/// its neighbours keep prepared players, so a swipe takes over a player that
/// is already warm instead of starting one.
///
/// It holds a lease for the active item and for each warm neighbour, and
/// releases the others; a released player stays warm in the pool until the
/// budget needs its engine, so swiping back is cheap too. The prepared count
/// is the smaller of the policy's prepared players and the pool's prepared
/// budget, which the host sets from the device's class. An active item the
/// autoplay gate holds back ([FeedAutoplay.none]) gets no player: it waits
/// for a tap, and a prepared player would fetch its bytes. One that already
/// held a player when the gate closed keeps it, paused on its frame.
///
/// Mute is session-wide: it applies to the active player and the prepared
/// ones. Without a mute of the host's it starts as the policy's initial mute
/// says, following the ringer ([FeedConditions.silenced]) until [muted] is
/// set. An item that ends asks for the next one ([onAdvance]) when the
/// policy's auto-advance allows; an item the pager comes back to restarts or
/// resumes as the policy says. While [held] nothing plays.
///
/// Listeners hear when the leases or the active page change.
final class FeedPager extends ChangeNotifier {
  /// Creates a pager over [itemCount] items, showing [initialIndex].
  FeedPager({
    required PlayerPool pool,
    required int itemCount,
    required this.itemOf,
    this.policy = const FeedPolicy.pager(),
    ValueListenable<FeedConditions>? conditions,
    int initialIndex = 0,
    bool? muted,
    this.onAdvance,
  }) : assert(policy.mode == FeedMode.pager, 'A pager takes a pager policy.'),
       _pool = pool,
       _itemCount = itemCount,
       _conditions = conditions,
       _index = initialIndex,
       _followsRinger =
           muted == null && policy.initialMute == FeedInitialMute.followRinger,
       _muted =
           muted ??
           switch (policy.initialMute) {
             FeedInitialMute.muted => true,
             FeedInitialMute.unmuted => false,
             FeedInitialMute.followRinger =>
               conditions?.value.silenced ?? false,
           } {
    _conditions?.addListener(_onConditions);
    _apply();
  }

  final PlayerPool _pool;
  final ValueListenable<FeedConditions>? _conditions;

  /// How many items the pager has; setting it plans again.
  int get itemCount => _itemCount;
  int _itemCount;
  set itemCount(int value) {
    if (value == _itemCount) return;
    _itemCount = value;
    _apply();
  }

  /// The feed facts of an item, or null while the host has none for it (the
  /// item is neither played nor warmed then).
  final FeedItem? Function(int index) itemOf;

  /// The rules; pager mode.
  final FeedPolicy policy;

  /// Told the index to show next when the active item ended and the policy
  /// advances.
  final ValueChanged<int>? onAdvance;

  final Map<int, PlayerLease> _leases = {};
  int _index;
  int? _activated;
  bool _muted;
  // Mute follows the ringer until the host or the user sets it.
  bool _followsRinger;
  bool _held = false;
  bool _disposed = false;
  FeedPagerPlan? _plan;
  PlayerLease? _watched;

  /// The page shown.
  int get index => _index;

  /// The plan applied last.
  FeedPagerPlan get plan => _plan!;

  /// Whether the pager plays without sound. Setting it is the user's choice:
  /// the ringer no longer moves it.
  bool get muted => _muted;
  set muted(bool value) {
    _followsRinger = false;
    _setMuted(value);
  }

  /// Whether nothing plays: the page shown pauses and stays leased, and plays
  /// again when released. The feed holds it while a pausing layer of the
  /// policy is set.
  bool get held => _held;
  set held(bool value) {
    if (value == _held || _disposed) return;
    _held = value;
    _apply();
  }

  void _onConditions() {
    if (_followsRinger) _setMuted(_conditions!.value.silenced);
    _apply();
  }

  void _setMuted(bool value) {
    if (value == _muted || _disposed) return;
    _muted = value;
    for (final lease in _leases.values) {
      lease.setVolume(value ? 0 : 1);
    }
    notifyListeners();
  }

  /// The lease of the item at [index] while the pager holds one: the active
  /// item and the warm neighbours.
  PlayerLease? leaseOf(int index) => _leases[index];

  /// Shows the page at [index]: it plays, taking over its prepared player.
  void show(int index) {
    if (_disposed || index == _index) return;
    _index = index;
    _apply();
  }

  /// Plans again for the page shown: for a host whose facts ([itemOf])
  /// changed, such as a neighbour that became known.
  void replan() => _apply();

  void _apply() {
    if (_disposed) return;
    final plan =
        FeedPagerPlanner(
          policy,
          conditions: _conditions?.value ?? const FeedConditions(),
        ).plan(
          index: _index,
          itemCount: _itemCount,
          item: itemOf,
          preparedCap: _pool.budget.prepared,
        );
    _plan = plan;
    // An item the gate holds back waits for a tap: a player prepared for it
    // would fetch the bytes nobody asked for. One that held a player keeps
    // it, paused on its frame (power saving came on while it played).
    final known =
        itemOf(plan.active) != null &&
        (plan.autoplay != FeedAutoplay.none ||
            _leases.containsKey(plan.active));
    final keep = {if (known) plan.active, ...plan.warm};
    for (final index in _leases.keys.toList()) {
      if (!keep.contains(index)) _leases.remove(index)!.release();
    }
    if (known) {
      // The active item first, so the budget never evicts it for a
      // neighbour.
      final active = _leaseFor(plan.active)!;
      final arrived = _activated != plan.active;
      _activated = plan.active;
      if (arrived && policy.resume == FeedResume.restart) {
        active.seekTo(Duration.zero);
      }
      if (plan.autoplay == FeedAutoplay.full && !_held) {
        active.play();
      } else {
        active.pause();
      }
      _watch(active);
    }
    for (final index in plan.warm) {
      _leaseFor(index)
        ?..pause()
        ..prepare();
    }
    notifyListeners();
  }

  PlayerLease? _leaseFor(int index) {
    final held = _leases[index];
    if (held != null) return held;
    final item = itemOf(index);
    if (item == null) return null;
    return _leases[index] = _pool.lease(item.key)
      ..setLooping(looping: policy.loop)
      ..setVolume(_muted ? 0 : 1);
  }

  void _watch(PlayerLease lease) {
    if (identical(_watched, lease)) return;
    _watched?.state.removeListener(_onActiveState);
    _watched = lease;
    lease.state.addListener(_onActiveState);
  }

  void _onActiveState() {
    final lease = _watched;
    if (_disposed || lease == null) return;
    if (lease.state.value.phase != PlayerPhase.ended) return;
    final next = _index + 1;
    if (next >= itemCount) return;
    final advance = policy.autoAdvance;
    final ended = itemOf(_index);
    final following = itemOf(next);
    if (advance != null &&
        ended != null &&
        following != null &&
        advance(ended, following)) {
      onAdvance?.call(next);
    }
  }

  /// Releases every lease the pager holds. Idempotent.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _conditions?.removeListener(_onConditions);
    _watched?.state.removeListener(_onActiveState);
    _watched = null;
    for (final lease in _leases.values) {
      lease.release();
    }
    _leases.clear();
    super.dispose();
  }
}
