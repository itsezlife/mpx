import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_ui/src/library/library_grid_policy.dart';
import 'package:mpx_ui/src/library/library_grid_tokens.dart';
import 'package:mpx_ui/src/library/picker_selection.dart';
import 'package:mpx_ui/src/text/mpx_text_root.dart';

/// The selected-items preview: the items of a [PickerSelection] in their
/// order, each with its order number, in the grid's columns and gaps.
///
/// A tap on an item's number deselects it, a tap on the picture opens it
/// ([onOpen], with its place in the order), and a long press lifts it so a
/// drag moves it among the others ([onReorder]; no reorder when null). The
/// host shows the preview in place of the grid when the selection's counter
/// is tapped and swaps back as it likes; header words, a hint and the way
/// back are the host's.
///
/// Library items show their library thumbnail; any other key (a capture, a
/// file the host counts in the same order) shows through `ContentView` by
/// the key itself.
class PickerSelectionPreview extends StatefulWidget {
  /// Creates the preview of [selection].
  const PickerSelectionPreview({
    required this.selection,
    required this.labels,
    this.policy = LibraryGridPolicy.$Android,
    this.tokens = const LibraryGridTokens(),
    this.onOpen,
    this.onReorder,
    this.onRefused,
    this.controller,
    this.padding,
    super.key,
  });

  /// The selection shown and changed.
  final PickerSelection selection;

  /// Words.
  final LibraryGridLabels labels;

  /// Columns, gaps and check sizes.
  final LibraryGridPolicy policy;

  /// Colours.
  final LibraryGridTokens tokens;

  /// An item was tapped: its key and its 0-based place in the order.
  final void Function(MediaKey key, int index)? onOpen;

  /// A lifted item was dragged over the place [to] (0-based):
  /// `OrderedPickerSelection.move` for the default selection.
  final void Function(MediaKey key, int to)? onReorder;

  /// A toggle was refused (a host gate may refuse a deselect).
  final void Function(MediaKey key, PickerRefusal reason)? onRefused;

  /// The scroll controller; one of its own when null.
  final ScrollController? controller;

  /// Padding around the items; the policy's padding when null.
  final EdgeInsets? padding;

  @override
  State<PickerSelectionPreview> createState() => PickerSelectionPreviewState();
}

/// The state of a [PickerSelectionPreview].
class PickerSelectionPreviewState extends State<PickerSelectionPreview> {
  ScrollController? _ownController;
  ScrollController get _controller =>
      widget.controller ?? (_ownController ??= ScrollController());

  // The lifted item, where the pointer is (local to the preview) and where
  // in the item it took hold.
  MediaKey? _lifted;
  Offset _pointer = Offset.zero;
  Offset _grip = Offset.zero;

  // Geometry of the last build.
  int _columns = 1;
  double _extent = 0;
  EdgeInsets _padding = EdgeInsets.zero;

  /// The item lifted for a reorder, or null.
  MediaKey? get lifted => _lifted;

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(PickerSelectionPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selection, widget.selection)) {
      oldWidget.selection.removeListener(_rebuild);
      widget.selection.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.selection.removeListener(_rebuild);
    _ownController?.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Offset _local(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box == null ? global : box.globalToLocal(global);
  }

  // The place in the order under [local], clamped to the items.
  int _indexAt(Offset local, int count) {
    final gap = widget.policy.gap;
    final stride = _extent + gap;
    if (stride <= 0 || count == 0) return 0;
    final offset = _controller.hasClients ? _controller.offset : 0.0;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final width = (context.findRenderObject() as RenderBox?)?.size.width ?? 0;
    final x = rtl
        ? width - local.dx - _padding.right
        : local.dx - _padding.left;
    final y = local.dy - _padding.top + offset;
    final column = (x / stride).floor().clamp(0, _columns - 1);
    final row = math.max(0, (y / stride).floor());
    return (row * _columns + column).clamp(0, count - 1);
  }

  void _lift(MediaKey key, Offset global, Offset inCell) {
    if (widget.onReorder == null) return;
    unawaited(HapticFeedback.mediumImpact());
    setState(() {
      _lifted = key;
      _pointer = _local(global);
      _grip = inCell;
    });
  }

  void _drag(Offset global) {
    final key = _lifted;
    if (key == null) return;
    final keys = widget.selection.keys;
    setState(() => _pointer = _local(global));
    final to = _indexAt(_pointer, keys.length);
    if (keys.indexOf(key) != to) widget.onReorder?.call(key, to);
  }

  void _drop() {
    if (_lifted == null) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _lifted = null);
  }

  void _deselect(MediaKey key) {
    if (widget.selection.toggle(key) case PickerToggle$Refused(:final reason)) {
      widget.onRefused?.call(key, reason);
    }
  }

  // The text root: the grid and its states draw text of their own, and a
  // host that pushed them without one would draw it in the fallback style.
  @override
  Widget build(BuildContext context) =>
      MpxTextRoot.wrap(context, _content(context));

  Widget _content(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final policy = widget.policy;
      final size = constraints.biggest;
      final screen = MediaQuery.maybeSizeOf(context);
      _columns = policy.columnsFor(size, screen: screen);
      _padding = widget.padding ?? EdgeInsets.all(policy.padding);
      _extent = math.max(
        0,
        (size.width - _padding.horizontal - policy.gap * (_columns - 1)) /
            _columns,
      );
      final keys = widget.selection.keys;
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
      final pixels = (_extent * dpr).ceil();
      Widget item(MediaKey key, {required bool lifted}) => _PreviewItem(
        key: lifted ? null : ValueKey<MediaKey>(key),
        content: key,
        extent: _extent,
        pixels: pixels,
        devicePixelRatio: dpr,
        order: widget.selection.orderOf(key),
        policy: policy,
        tokens: widget.tokens,
        labels: widget.labels,
        hidden: !lifted && key == _lifted,
        onOpen: () => widget.onOpen?.call(key, keys.indexOf(key)),
        onDeselect: () => _deselect(key),
        onLift: (global, inCell) => _lift(key, global, inCell),
        onDrag: _drag,
        onDrop: _drop,
      );
      final lifted = _lifted;
      return Stack(
        children: [
          GridView.builder(
            controller: _controller,
            padding: _padding,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _columns,
              mainAxisSpacing: policy.gap,
              crossAxisSpacing: policy.gap,
            ),
            itemCount: keys.length,
            itemBuilder: (context, index) => item(keys[index], lifted: false),
          ),
          if (lifted != null && keys.contains(lifted))
            Positioned(
              left: _pointer.dx - _grip.dx,
              top: _pointer.dy - _grip.dy,
              child: IgnorePointer(
                child: Transform.scale(
                  scale: 1.05,
                  child: item(lifted, lifted: true),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _PreviewItem extends StatelessWidget {
  const _PreviewItem({
    required this.content,
    required this.extent,
    required this.pixels,
    required this.devicePixelRatio,
    required this.order,
    required this.policy,
    required this.tokens,
    required this.labels,
    required this.hidden,
    required this.onOpen,
    required this.onDeselect,
    required this.onLift,
    required this.onDrag,
    required this.onDrop,
    super.key,
  });

  final MediaKey content;
  final double extent;
  final int pixels;
  final double devicePixelRatio;
  final int? order;
  final LibraryGridPolicy policy;
  final LibraryGridTokens tokens;
  final LibraryGridLabels labels;
  final bool hidden;
  final VoidCallback onOpen;
  final VoidCallback onDeselect;
  final void Function(Offset global, Offset inCell) onLift;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final thumbnail = switch (LibraryKeys.read(content)) {
      final target? => LibraryKeys.thumbnailKeyFor(target.asset, pixels),
      null => content,
    };
    if (thumbnail != content) {
      // A library key resolves only through its descriptor, which the grid
      // tells for its cells; the preview holds keys alone, and a library
      // thumbnail is a still whatever the asset is.
      AssetCacheProvider.maybeOf(
        context,
      )?.know(MediaDescriptor(key: thumbnail, kind: MediaKind.still));
    }
    final check = policy.checkSize;
    final hit = policy.checkHitSize;
    return Semantics(
      button: true,
      label: labels.select,
      value: order?.toString(),
      checked: true,
      onTap: onOpen,
      customSemanticsActions: {
        CustomSemanticsAction(label: labels.open): onOpen,
      },
      // The press handlers stay on the item while it is lifted: the long
      // press that lifted it goes on reporting the drag to them.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        onLongPressStart: (d) => onLift(d.globalPosition, d.localPosition),
        onLongPressMoveUpdate: (d) => onDrag(d.globalPosition),
        onLongPressEnd: (_) => onDrop(),
        onLongPressCancel: onDrop,
        child: SizedBox.square(
          dimension: extent,
          child: hidden
              ? ColoredBox(color: tokens.cellPlaceholder)
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: tokens.cellPlaceholder,
                      child: ContentView(
                        content: thumbnail,
                        preset: AssetPresets.square(
                          extent: extent,
                          devicePixelRatio: devicePixelRatio,
                          profile: const AssetProfile(fit: AssetFit.cover),
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      top: 0,
                      end: 0,
                      width: hit,
                      height: hit,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onDeselect,
                        child: Align(
                          alignment: AlignmentDirectional.topEnd,
                          child: Padding(
                            padding: EdgeInsets.all((hit - check) / 4),
                            child: Container(
                              width: check,
                              height: check,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: tokens.checkFill,
                                border: Border.all(
                                  color: tokens.checkRing,
                                  width: 2,
                                ),
                              ),
                              child: Text(
                                '${order ?? ''}',
                                style: tokens.orderNumber(order ?? 0),
                                maxLines: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
