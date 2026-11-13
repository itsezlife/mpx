import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/feed/feed_clip.dart';

/// Builds the cell of [index] around its [clip], the view of the item's media.
typedef FeedListCellBuilder =
    Widget Function(BuildContext context, int index, Widget clip);

/// A vertical list where every visible clip plays muted and loops on the
/// software path, as a list-mode [FeedPolicy] says.
///
/// The assembled default of the feed's pieces: a list-mode
/// [FeedController] over a `ListView` whose cells are `FeedSlot`s showing a
/// [FeedClip]. A host with its own scrollable uses those pieces directly.
///
/// Items may have any extent; [itemExtent], when every item has the same,
/// only spares the list its layout of off-screen items.
///
/// [scope] if given, otherwise the closest `AssetCacheProvider`.
class FeedListView extends StatefulWidget {
  /// Creates a list of [itemCount] items.
  const FeedListView({
    required this.itemCount,
    required this.itemOf,
    required this.presetOf,
    super.key,
    this.itemExtent,
    this.policy = const FeedPolicy.list(),
    this.conditions,
    this.scope,
    this.controller,
    this.cellBuilder,
    this.onInViewChanged,
  });

  /// How many items the list has.
  final int itemCount;

  /// The extent of every item along the scroll axis, when they share one.
  final double? itemExtent;

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
  State<FeedListView> createState() => FeedListViewState();
}

/// The state of a [FeedListView]; [feed] is the controller it drives.
class FeedListViewState extends State<FeedListView> {
  late FeedController _feed = _create();

  /// The feed: per-item decisions and the item in view.
  FeedController get feed => _feed;

  // The host's callbacks are read through the widget, so a parent that
  // rebuilds with new closures is followed without a new controller.
  FeedController _create() => FeedController(
    policy: widget.policy,
    itemCount: widget.itemCount,
    itemOf: (index) => widget.itemOf(index),
    presetOf: (index, profile) => widget.presetOf(index, profile),
    conditions: widget.conditions,
  )..inView.addListener(_inViewChanged);

  void _inViewChanged() => widget.onInViewChanged?.call(_feed.inView.value);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _feed.scope = widget.scope ?? AssetCacheProvider.of(context);
  }

  @override
  void didUpdateWidget(FeedListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.policy != oldWidget.policy ||
        !identical(widget.conditions, oldWidget.conditions)) {
      _dispose(_feed);
      _feed = _create();
    }
    _feed
      ..itemCount = widget.itemCount
      ..scope = widget.scope ?? AssetCacheProvider.of(context);
  }

  @override
  void dispose() {
    _dispose(_feed);
    super.dispose();
  }

  void _dispose(FeedController feed) => feed
    ..inView.removeListener(_inViewChanged)
    ..dispose();

  @override
  Widget build(BuildContext context) => FeedScope(
    controller: _feed,
    child: ListView.builder(
      controller: widget.controller,
      itemCount: widget.itemCount,
      itemExtent: widget.itemExtent,
      itemBuilder: (context, index) {
        const clip = FeedClip();
        return FeedSlot(
          index: index,
          item: widget.itemOf(index),
          child: widget.cellBuilder?.call(context, index, clip) ?? clip,
        );
      },
    ),
  );
}
