import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/feed/feed_controller.dart';
import 'package:mpx_player/src/feed/feed_item.dart';

/// Makes a [FeedController] available to the [FeedSlot]s below, so a host's
/// cells find it without passing it down.
///
/// The host creates the controller and disposes it; the scope only hands it
/// out.
class FeedScope extends InheritedWidget {
  /// Provides [controller] to [child] and everything below.
  const FeedScope({required this.controller, required super.child, super.key});

  /// The controller the slots below register with.
  final FeedController controller;

  /// The controller of the closest scope above [context], or null.
  static FeedController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeedScope>()?.controller;

  @override
  bool updateShouldNotify(FeedScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}

/// Wraps one item of any host scrollable so a [FeedController] plays it.
///
/// The slot registers [index] and [item] with [controller] (or the closest
/// [FeedScope]'s) and measures how much of itself shows
/// (`ViewportVisibility`): its box is clipped by the closest enclosing
/// viewport, then by every viewport around that one, so a slot in a
/// horizontal list inside a vertical one is clipped by both; a slot laid out
/// out of view reports how many viewports away it is. It needs no extent, axis or viewport
/// type: any `RenderAbstractViewport` clips it (lists, grids, slivers,
/// pagers, a host's own viewport), and a slot its parents do not paint (a
/// cell kept alive off screen, an offstage page) counts as hidden.
///
/// It asks to be measured after its own layout and whenever a scrollable
/// around it scrolls; any slot registering, moving or leaving measures them
/// all. The controller measures every slot once per frame that needs it,
/// after layout. A host whose viewport moves its items otherwise (a viewport
/// that resizes along its axis) calls `FeedController.markNeedsMeasure`. A
/// recycled slot moves its registration to its new index.
///
/// Widgets below read the slot's decision through [FeedSlot.of].
class FeedSlot extends StatefulWidget {
  /// Wraps [child], the item at [index].
  const FeedSlot({
    required this.index,
    required this.child,
    this.item,
    this.controller,
    super.key,
  });

  /// The item's index in the feed.
  final int index;

  /// The item's facts; the controller's `itemOf` when null.
  final FeedItem? item;

  /// The controller to register with, instead of the closest [FeedScope]'s.
  final FeedController? controller;

  /// The item's cell.
  final Widget child;

  /// The registration of the closest slot above [context], or null. Widgets
  /// below rebuild when the slot moves to another index or controller.
  static FeedSlotRegistration? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FeedSlotScope>()?.slot;

  /// The registration of the closest slot above [context].
  ///
  /// Throws a [FlutterError] when there is none.
  static FeedSlotRegistration of(BuildContext context) {
    final slot = maybeOf(context);
    if (slot != null) return slot;
    throw FlutterError.fromParts([
      ErrorSummary('No FeedSlot found above this widget.'),
      ErrorHint('Wrap the item in FeedSlot(index: ..., child: ...).'),
    ]);
  }

  @override
  State<FeedSlot> createState() => _FeedSlotState();
}

class _FeedSlotState extends State<FeedSlot> {
  FeedSlotRegistration? _registration;
  List<ScrollPosition> _positions = const [];
  final GlobalKey _box = GlobalKey();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _register();
    _follow();
  }

  @override
  void didUpdateWidget(FeedSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _register();
  }

  @override
  void dispose() {
    _registration?.unregister();
    _registration = null;
    _follow(stop: true);
    super.dispose();
  }

  void _register() {
    final controller = widget.controller ?? FeedScope.maybeOf(context);
    assert(
      controller != null,
      'A FeedSlot needs a controller: pass one or put a FeedScope above.',
    );
    final current = _registration;
    if (current != null && identical(current.controller, controller)) {
      current.update(index: widget.index, item: widget.item);
      return;
    }
    current?.unregister();
    _registration = controller?.register(
      widget.index,
      item: widget.item,
      measure: _measure,
    );
  }

  // Every scrollable around the slot moves it; the closest one alone would
  // miss an outer list scrolling a nested one past its edge.
  void _follow({bool stop = false}) {
    final positions = <ScrollPosition>[];
    if (!stop) {
      // The closest one is a dependency (a new position rebuilds the slot);
      // the outer ones are only looked up.
      var scrollable = Scrollable.maybeOf(context);
      while (scrollable != null) {
        positions.add(scrollable.position);
        scrollable = scrollable.context
            .findAncestorStateOfType<ScrollableState>();
      }
    }
    for (final position in _positions) {
      if (!positions.contains(position)) position.removeListener(_moved);
    }
    for (final position in positions) {
      if (!_positions.contains(position)) position.addListener(_moved);
    }
    _positions = positions;
  }

  void _moved() => _registration?.markNeedsMeasure();

  FeedVisibility _measure() {
    final box = _box.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      return FeedVisibility.hidden;
    }
    final seen = ViewportVisibility.of(box);
    if (!seen.shows) {
      return seen.viewportsAway.isInfinite
          ? FeedVisibility.hidden
          : FeedVisibility(fraction: 0, viewportsAway: seen.viewportsAway);
    }
    return FeedVisibility(
      fraction: seen.fraction,
      centreDistance: seen.centreDistance,
    );
  }

  @override
  Widget build(BuildContext context) => _FeedSlotScope(
    slot: _registration,
    index: widget.index,
    item: widget.item,
    child: _LayoutReporter(key: _box, onLayout: _moved, child: widget.child),
  );
}

class _FeedSlotScope extends InheritedWidget {
  const _FeedSlotScope({
    required this.slot,
    required this.index,
    required this.item,
    required super.child,
  });

  final FeedSlotRegistration? slot;
  final int index;
  final FeedItem? item;

  @override
  bool updateShouldNotify(_FeedSlotScope oldWidget) =>
      !identical(slot, oldWidget.slot) ||
      index != oldWidget.index ||
      item != oldWidget.item;
}

/// Calls [onLayout] after every layout of its child: a slot that resizes or
/// is laid out anew may show a different share of itself.
class _LayoutReporter extends SingleChildRenderObjectWidget {
  const _LayoutReporter({
    required this.onLayout,
    required super.child,
    super.key,
  });

  final VoidCallback onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLayoutReporter(onLayout);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLayoutReporter renderObject,
  ) => renderObject.onLayout = onLayout;
}

class _RenderLayoutReporter extends RenderProxyBox {
  _RenderLayoutReporter(this.onLayout);

  VoidCallback onLayout;

  @override
  void performLayout() {
    super.performLayout();
    onLayout();
  }
}
