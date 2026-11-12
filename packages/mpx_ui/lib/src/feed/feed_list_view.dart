import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';

/// Builds the cell of [index] around its [clip], the view of the item's media.
typedef FeedListCellBuilder =
    Widget Function(BuildContext context, int index, Widget clip);

/// A vertical list where every visible clip plays muted and loops on the
/// software path, as a list-mode [FeedPolicy] says.
///
/// Each frame it measures how much of each item shows, asks a
/// [FeedListPlanner] what plays, what is in view and what preloads, and
/// applies it: a clip that autoplays attaches with the policy's clip profile
/// (looping, advancing only above the advance floor), one that does not
/// shows its first frame; the items ahead in the scroll direction are
/// preloaded to their stage through the asset cache scope
/// (`AssetCacheScope.preload`), and preloads that leave the window are
/// cancelled when the policy says so.
///
/// Items have one extent, [itemExtent]: the visible fraction of each is read
/// from the scroll offset, with no layout pass of its own.
///
/// [scope] if given, otherwise the closest `AssetCacheProvider`.
class FeedListView extends StatefulWidget {
  /// Creates a list of [itemCount] items of [itemExtent] each.
  const FeedListView({
    required this.itemCount,
    required this.itemExtent,
    required this.itemOf,
    required this.presetOf,
    super.key,
    this.policy = const FeedPolicy.list(),
    this.conditions,
    this.scope,
    this.controller,
    this.cellBuilder,
    this.onInViewChanged,
  });

  /// How many items the list has.
  final int itemCount;

  /// The extent of every item along the scroll axis.
  final double itemExtent;

  /// The feed facts of an item.
  final FeedItem Function(int index) itemOf;

  /// The size and decode of an item's clip, under the given profile.
  final AssetPreset Function(int index, AssetProfile profile) presetOf;

  /// The rules; list mode.
  final FeedPolicy policy;

  /// The device's conditions the autoplay gate weighs, live (a
  /// `FeedSignals`); the neutral `FeedConditions` when null. The list plans
  /// again when they change.
  final ValueListenable<FeedConditions>? conditions;

  /// The cache the clips attach to.
  final AssetCacheScope? scope;

  /// The scroll controller, or null for one of its own.
  final ScrollController? controller;

  /// Builds a cell around its clip; the clip alone when null.
  final FeedListCellBuilder? cellBuilder;

  /// Told the index in view when it changes, or null when none is.
  final ValueChanged<int?>? onInViewChanged;

  @override
  State<FeedListView> createState() => _FeedListViewState();
}

class _FeedListViewState extends State<FeedListView> {
  ScrollController? _ownController;
  ScrollController get _controller =>
      widget.controller ?? (_ownController ??= ScrollController());

  AssetCacheScope? _scope;
  Map<int, double> _visible = const {};
  FeedListPlan _plan = const FeedListPlan(
    autoplay: {},
    inView: null,
    preloads: {},
  );
  final Map<int, AssetPreload> _preloads = {};
  double _lastOffset = 0;
  FeedScrollDirection _direction = FeedScrollDirection.forward;
  bool _measureScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.conditions?.addListener(_conditionsChanged);
  }

  void _conditionsChanged() {
    if (mounted) _measure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = widget.scope ?? AssetCacheProvider.of(context);
    if (!identical(scope, _scope)) {
      _cancelAll();
      _scope = scope;
    }
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(FeedListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.conditions, oldWidget.conditions)) {
      oldWidget.conditions?.removeListener(_conditionsChanged);
      widget.conditions?.addListener(_conditionsChanged);
    }
    if (widget.scope != oldWidget.scope) {
      final scope = widget.scope ?? AssetCacheProvider.of(context);
      if (!identical(scope, _scope)) {
        _cancelAll();
        _scope = scope;
      }
    }
    _scheduleMeasure();
  }

  @override
  void dispose() {
    widget.conditions?.removeListener(_conditionsChanged);
    _cancelAll();
    _ownController?.dispose();
    super.dispose();
  }

  void _cancelAll() {
    for (final preload in _preloads.values) {
      preload.cancel();
    }
    _preloads.clear();
  }

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (mounted) _measure();
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 && notification is ScrollUpdateNotification) {
      _measure();
    }
    return false;
  }

  void _measure() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final offset = position.pixels;
    if (offset != _lastOffset) {
      _direction = offset > _lastOffset
          ? FeedScrollDirection.forward
          : FeedScrollDirection.backward;
      _lastOffset = offset;
    }
    final visible = _fractions(offset, position.viewportDimension);
    final centre = offset + position.viewportDimension / 2;
    final extent = widget.itemExtent;
    final scope = _scope!;
    final plan =
        FeedListPlanner(
          widget.policy,
          conditions: widget.conditions?.value ?? const FeedConditions(),
        ).plan(
          FeedListViewport(
            itemCount: widget.itemCount,
            visible: visible,
            centreDistances: {
              for (final index in visible.keys)
                index: ((index + 0.5) * extent - centre).abs(),
            },
            direction: _direction,
            fastScroll: scope.clock.pausedLayers.contains(
              PlaybackPauseLayer.fastScroll,
            ),
          ),
          widget.itemOf,
        );
    _applyPreloads(plan, visible.keys.toSet());
    final inViewChanged = plan.inView != _plan.inView;
    if (!_sameMaps(visible, _visible) ||
        !_sameMaps(plan.autoplay, _plan.autoplay)) {
      setState(() {
        _visible = visible;
        _plan = plan;
      });
    } else {
      _plan = plan;
    }
    if (inViewChanged) widget.onInViewChanged?.call(plan.inView);
  }

  Map<int, double> _fractions(double offset, double viewport) {
    final extent = widget.itemExtent;
    if (extent <= 0 || widget.itemCount == 0) return const {};
    final end = offset + viewport;
    final first = (offset / extent).floor().clamp(0, widget.itemCount - 1);
    final fractions = <int, double>{};
    for (var index = first; index < widget.itemCount; index++) {
      final top = index * extent;
      if (top >= end) break;
      final bottom = top + extent;
      final shown =
          (bottom < end ? bottom : end) - (top > offset ? top : offset);
      if (shown > 0) fractions[index] = (shown / extent).clamp(0.0, 1.0);
    }
    return fractions;
  }

  void _applyPreloads(FeedListPlan plan, Set<int> shown) {
    final scope = _scope!;
    final profile = widget.policy.clipProfile();
    for (final index in _preloads.keys.toList()) {
      final wanted = plan.preloads[index];
      final current = _preloads[index]!;
      // A visible item is held by its cell's binding; outside the window a
      // preload goes when the policy cancels on leave.
      final drop =
          shown.contains(index) ||
          (wanted == null && widget.policy.cancelOnLeave) ||
          (wanted != null && wanted != current.stage);
      if (drop) {
        current.cancel();
        _preloads.remove(index);
      }
    }
    for (final MapEntry(key: index, value: stage) in plan.preloads.entries) {
      if (_preloads.containsKey(index)) continue;
      _preloads[index] = scope.preload(
        widget.itemOf(index).key,
        widget.presetOf(index, profile).spec,
        stage: stage,
        distance: plan.distances[index] ?? 0,
      );
    }
  }

  static bool _sameMaps<V>(Map<int, V> a, Map<int, V> b) {
    if (a.length != b.length) return false;
    for (final MapEntry(:key, :value) in a.entries) {
      if (b[key] != value) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (notification) {
            if (notification.depth == 0) _measure();
            return false;
          },
          child: ListView.builder(
            controller: _controller,
            itemCount: widget.itemCount,
            itemExtent: widget.itemExtent,
            itemBuilder: _cell,
          ),
        ),
      );

  Widget _cell(BuildContext context, int index) {
    final plays = _plan.autoplay[index] == FeedAutoplay.full;
    final base = widget.policy.clipProfile();
    final profile = plays
        ? base
        : AssetProfile(
            loop: base.loop,
            cornerRadius: base.cornerRadius,
            fit: base.fit,
            advanceFloor: base.advanceFloor,
          );
    final clip = ContentView(
      content: widget.itemOf(index).key,
      preset: widget.presetOf(index, profile),
      scope: _scope,
      visibleFraction: _visible[index] ?? 0,
    );
    return widget.cellBuilder?.call(context, index, clip) ?? clip;
  }
}
