import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_ui/src/known_descriptors.dart';
import 'package:mpx_ui/src/library/library_grid_cell.dart';
import 'package:mpx_ui/src/library/library_grid_layout.dart';
import 'package:mpx_ui/src/library/library_grid_policy.dart';
import 'package:mpx_ui/src/library/library_grid_tokens.dart';
import 'package:mpx_ui/src/library/library_pages.dart';
import 'package:mpx_ui/src/library/picker_selection.dart';
import 'package:mpx_ui/src/text/mpx_text_root.dart';

/// What the camera slot's host builder is told: whether the preview in the
/// slot should pause.
@immutable
final class CameraSlotSignals {
  /// Creates the signals.
  const CameraSlotSignals({
    required this.onScreen,
    required this.viewerOpen,
    required this.active,
    this.cameraDenied = false,
  });

  /// Whether any of the slot is in the viewport.
  final bool onScreen;

  /// Whether the picker-mode viewer covers the grid.
  final bool viewerOpen;

  /// Whether the host's page holding the grid is active and uncovered.
  final bool active;

  /// Whether the host says camera access is denied (the slot shows its
  /// "allow access" state instead of a preview).
  final bool cameraDenied;

  /// Whether the preview should pause: off screen, covered, or inactive.
  bool get shouldPause => !onScreen || viewerOpen || !active;

  @override
  bool operator ==(Object other) =>
      other is CameraSlotSignals &&
      other.onScreen == onScreen &&
      other.viewerOpen == viewerOpen &&
      other.active == active &&
      other.cameraDenied == cameraDenied;

  @override
  int get hashCode => Object.hash(onScreen, viewerOpen, active, cameraDenied);

  @override
  String toString() =>
      'CameraSlotSignals(onScreen: $onScreen, viewerOpen: $viewerOpen, '
      'active: $active, cameraDenied: $cameraDenied)';
}

/// Builds the camera slot's content (a live preview): `mpx_ui` takes no
/// edge to `mpx_capture`, so the host fills the slot. [signals] says when
/// the preview should pause.
typedef CameraSlotBuilder =
    Widget Function(
      BuildContext context,
      ValueListenable<CameraSlotSignals> signals,
    );

/// What a [LibraryGrid] holds at a scroll offset: the asset of the row
/// there, for a host that labels places in the grid (a date beside a
/// scroll thumb, say).
///
/// The host makes one, hands it to the grid ([LibraryGrid.lookup]) and
/// disposes it. It answers for the grid it is attached to, and nothing
/// with none. It tells its listeners when an answer may have changed: a
/// page landed, the album or the layout changed.
final class LibraryGridLookup extends ChangeNotifier {
  LibraryGridState? _grid;

  /// The asset of the row at [scrollOffset] (the grid's scroll position),
  /// the first of the row in reading order; while its page loads, the held
  /// asset nearest to it (`LibraryPages.nearestAt`). Null with no grid
  /// attached or an empty album.
  LibraryAsset? assetAt(double scrollOffset) =>
      _grid?._assetAtScrollOffset(scrollOffset);

  /// The assets in the attached grid's album as last read; 0 with none
  /// attached.
  int get count => _grid?._pages.total ?? 0;

  void _detach(LibraryGridState grid) {
    if (identical(_grid, grid)) _grid = null;
  }

  void _tell() => notifyListeners();
}

/// A grid over a library album's pages: fixed square cells, thumbnails
/// through the asset cache, an ordered selection with numbered checks and
/// swipe select, and the host's camera slot at the leading top of the
/// all-media album.
///
/// The grid hands the host an ordered selection ([selection]); it knows
/// nothing of what the selection becomes. Pages load around what it builds
/// (one screen of prefetch); cells far off screen are not built, so nothing
/// is decoded for them. Library change events re-read the pages and keep the
/// selection (keyed by `MediaKey`); [LibraryGridPolicy.$Android] holds them
/// while [viewerOpen].
///
/// Taps: the check toggles (a refusal goes to [onRefused]); the picture
/// opens ([onOpen]). Swipe select follows [LibraryGridPolicy.swipeRule]:
/// the first cell's new state goes to every cell crossed, and the grid
/// scrolls by itself near its top and bottom edges.
class LibraryGrid extends StatefulWidget {
  /// Creates a grid over [album] of [library].
  const LibraryGrid({
    required this.library,
    required this.album,
    required this.selection,
    required this.labels,
    this.policy = LibraryGridPolicy.$Android,
    this.tokens = const LibraryGridTokens(),
    this.onOpen,
    this.onRefused,
    this.cameraSlotBuilder,
    this.cameraAllowed = true,
    this.cameraDenied = false,
    this.onCameraTap,
    this.onCameraLongPress,
    this.decorationBuilder,
    this.highQuality = false,
    this.physics,
    this.controller,
    this.viewerOpen = false,
    this.active = true,
    this.pageSize = 60,
    this.pages,
    this.lookup,
    super.key,
  });

  /// The album's pages when the host shares them (with a picker-mode
  /// viewer, say); the host owns and disposes them. Null for the grid's own
  /// over [album].

  /// The library read.
  final MediaLibrary library;

  /// The album shown.
  final LibraryAlbum album;

  /// The selection the checks show and change.
  final PickerSelection selection;

  /// Words.
  final LibraryGridLabels labels;

  /// The platform values.
  final LibraryGridPolicy policy;

  /// Colours and text styles.
  final LibraryGridTokens tokens;

  /// Called by a tap on a picture, with the asset and its index in the
  /// album.
  final void Function(LibraryAsset asset, int index)? onOpen;

  /// Called when the selection refused a key.
  final void Function(MediaKey key, PickerRefusal reason)? onRefused;

  /// Fills the camera slot; null shows none.
  final CameraSlotBuilder? cameraSlotBuilder;

  /// Whether the host allows the camera here (camera access granted, media
  /// allowed); false shows no slot.
  final bool cameraAllowed;

  /// Whether camera access is denied: [LibraryGridPolicy.$IOS] shows no
  /// slot then; [LibraryGridPolicy.$Android] keeps it and tells its builder
  /// ([CameraSlotSignals.cameraDenied]).
  final bool cameraDenied;

  /// Called by a tap on the camera slot.
  final VoidCallback? onCameraTap;

  /// Called by a long press on the camera slot.
  final VoidCallback? onCameraLongPress;

  /// Builds a host mark over a cell's picture (a spoiler, say), or null.
  final Widget? Function(BuildContext context, LibraryAsset asset)?
  decorationBuilder;

  /// Whether checked photos go in high quality: their badges say HD.
  final bool highQuality;

  /// The scroll physics, from the host.
  final ScrollPhysics? physics;

  /// The scroll controller, or null for the grid's own.
  final ScrollController? controller;

  /// Whether the picker-mode viewer covers the grid.
  final bool viewerOpen;

  /// Whether the host's page holding the grid is active and uncovered.
  final bool active;

  /// Assets per page read.
  final int pageSize;

  /// See the constructor.
  final LibraryPages? pages;

  /// Answers what the grid holds at a scroll offset, for the host; null for
  /// none. The host owns it.
  final LibraryGridLookup? lookup;

  @override
  State<LibraryGrid> createState() => LibraryGridState();
}

/// The state of a [LibraryGrid]; public for tests and diagnostics.
class LibraryGridState extends State<LibraryGrid>
    with SingleTickerProviderStateMixin {
  late LibraryPages _pages = _makePages();
  ScrollController? _ownController;
  StreamSubscription<LibraryChange>? _changes;
  bool _pendingChange = false;
  final KnownDescriptors _known = KnownDescriptors();
  final ValueNotifier<CameraSlotSignals> _signals = ValueNotifier(
    const CameraSlotSignals(onScreen: true, viewerOpen: false, active: true),
  );

  // Swipe select.
  int? _anchor;
  bool _selecting = true;
  // The cells the swipe has taken (by album index, the pressed one aside)
  // and whether each was selected before: a cell the swipe leaves behind as
  // it comes back toward its start goes back to that state.
  final Map<int, bool> _before = {};
  Offset? _pointer;
  Ticker? _ticker;
  Ticker get _autoScroll => _ticker ??= createTicker(_onAutoScroll);
  bool _swiping = false;

  // Layout of the last build, for hit tests.
  LibraryGridLayout? _layout;
  double _padding = 0;
  bool _hasCamera = false;

  /// The pages read so far, for tests and diagnostics.
  LibraryPages get pages => _pages;

  ScrollController get _controller =>
      widget.controller ?? (_ownController ??= ScrollController());

  LibraryPages _makePages() =>
      (widget.pages ??
            LibraryPages(
              library: widget.library,
              album: widget.album,
              pageSize: widget.pageSize,
            ))
        ..addListener(_onPages);

  // Layout of the last build that the lookup answered from, to tell it when
  // a new one moves its answers.
  (int, double, bool)? _toldLayout;

  void _dropPages() {
    _pages.removeListener(_onPages);
    if (!identical(_pages, widget.pages)) _pages.dispose();
  }

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_rebuild);
    _controller.addListener(_onScroll);
    widget.lookup?._grid = this;
    _subscribe();
    _updateSignals();
    if (widget.album.startsAtEnd) _jumpToStart();
  }

  // An album opens at its top, or at its end when it runs oldest first
  // (`startsAtEnd`): after the frame that lays it out, and again once its
  // first page grew the extent.
  void _jumpToStart() {
    void jump() {
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      _controller.jumpTo(
        widget.album.startsAtEnd ? position.maxScrollExtent : 0,
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      jump();
      if (widget.album.startsAtEnd) {
        WidgetsBinding.instance.addPostFrameCallback((_) => jump());
      }
    });
  }

  @override
  void didUpdateWidget(LibraryGrid oldWidget) {
    final old = oldWidget;
    super.didUpdateWidget(oldWidget);
    if (!identical(old.selection, widget.selection)) {
      old.selection.removeListener(_rebuild);
      widget.selection.addListener(_rebuild);
    }
    if (!identical(old.library, widget.library) ||
        old.album.id != widget.album.id ||
        old.pageSize != widget.pageSize ||
        !identical(old.pages, widget.pages)) {
      _pages.removeListener(_onPages);
      if (old.pages == null) _pages.dispose();
      _pages = _makePages();
      widget.lookup?._tell();
      if (old.album.id != widget.album.id) _jumpToStart();
    }
    if (!identical(old.library, widget.library)) {
      unawaited(_changes?.cancel());
      _subscribe();
    }
    if (!identical(old.lookup, widget.lookup)) {
      old.lookup?._detach(this);
      widget.lookup?._grid = this;
      _toldLayout = null;
    }
    if (!identical(old.controller, widget.controller)) {
      (old.controller ?? _ownController)?.removeListener(_onScroll);
      _controller.addListener(_onScroll);
    }
    if (old.viewerOpen && !widget.viewerOpen && _pendingChange) {
      _pendingChange = false;
      _pages.reload();
    }
    _updateSignals();
  }

  @override
  void dispose() {
    widget.selection.removeListener(_rebuild);
    _controller.removeListener(_onScroll);
    widget.lookup?._detach(this);
    unawaited(_changes?.cancel());
    _ticker?.dispose();
    _dropPages();
    _ownController?.dispose();
    _signals.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  // The pages notify as they land (and on swap); the lookup's answers move
  // with them.
  void _onPages() {
    _rebuild();
    widget.lookup?._tell();
  }

  // After a build whose layout differs from the one the lookup last told
  // of (a first layout, a rotation, the camera slot coming or going): told
  // after the frame, as listeners may rebuild.
  void _tellLayout() {
    final layout = _layout;
    final lookup = widget.lookup;
    if (layout == null || lookup == null) return;
    final now = (layout.columns, layout.extent, layout.cameraSlot);
    if (now == _toldLayout) return;
    _toldLayout = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.lookup?._tell();
    });
  }

  // The first asset of the row at [scrollOffset] (the camera slot takes the
  // first column of the first two rows), or null before a layout or with no
  // assets.
  LibraryAsset? _assetAtScrollOffset(double scrollOffset) {
    final layout = _layout;
    final total = _pages.total;
    if (layout == null || total == 0) return null;
    final stride = layout.extent + layout.gap;
    if (stride <= 0) return null;
    final y = math.max(0, scrollOffset - _padding);
    final row = y ~/ stride;
    final n = layout.columns;
    final index = !_hasCamera
        ? row * n
        : row < 2
        ? row * (n - 1)
        : 2 * (n - 1) + (row - 2) * n;
    return _pages.nearestAt(math.min(index, total - 1));
  }

  void _subscribe() {
    _changes = widget.library.changes.listen((_) {
      if (widget.viewerOpen && widget.policy.defersChangesWhileViewerOpen) {
        _pendingChange = true;
        return;
      }
      _pages.reload();
    });
  }

  void _onScroll() => _updateSignals();

  void _updateSignals() {
    final layout = _layout;
    final offset = _controller.hasClients ? _controller.offset : 0.0;
    final slotEnd = layout == null
        ? double.infinity
        : _padding + 2 * layout.extent + layout.gap;
    _signals.value = CameraSlotSignals(
      onScreen: offset < slotEnd,
      viewerOpen: widget.viewerOpen,
      active: widget.active,
      cameraDenied: widget.cameraDenied,
    );
  }

  // --- Selection ---

  void _report(MediaKey key, PickerRefusal reason) {
    if (widget.policy.errorHaptic) unawaited(HapticFeedback.heavyImpact());
    widget.onRefused?.call(key, reason);
  }

  void _toggle(LibraryAsset asset) {
    final key = LibraryKeys.libraryKeyOf(asset);
    if (widget.selection.toggle(key) case PickerToggle$Refused(:final reason)) {
      _report(key, reason);
    }
  }

  // --- Swipe select ---

  /// The album index of the asset under [local] (the grid's coordinates),
  /// or null for the camera slot, a gap or nothing.
  int? _indexAt(Offset local) {
    final layout = _layout;
    if (layout == null) return null;
    final offset = _controller.hasClients ? _controller.offset : 0.0;
    final x = local.dx - _padding;
    final y = local.dy - _padding + offset;
    if (x < 0 || y < 0) return null;
    final stride = layout.extent + layout.gap;
    final row = y ~/ stride;
    var column = x ~/ stride;
    if (column >= layout.columns) return null;
    if (layout.reverseCrossAxis) column = layout.columns - 1 - column;
    final n = layout.columns;
    final int asset;
    if (_hasCamera && row < 2) {
      if (column == 0) return null;
      asset = row * (n - 1) + column - 1;
    } else {
      asset = (_hasCamera ? 2 * (n - 1) + (row - 2) * n : row * n) + column;
    }
    return asset < _pages.total ? asset : null;
  }

  void _swipeStart(Offset local) {
    final index = _indexAt(local);
    final asset = index == null ? null : _pages.assetAt(index);
    if (index == null || asset == null) return;
    final key = LibraryKeys.libraryKeyOf(asset);
    final result = widget.selection.toggle(key);
    if (result case PickerToggle$Refused(:final reason)) {
      _report(key, reason);
      _selecting = true;
    } else {
      _selecting = result is PickerToggle$Selected;
    }
    setState(() {
      _anchor = index;
      _swiping = true;
      _before.clear();
      _pointer = local;
    });
    unawaited(HapticFeedback.selectionClick());
  }

  void _swipeUpdate(Offset local) {
    _pointer = local;
    _extendTo(local);
    _updateAutoScroll(local);
  }

  // The cells between the start and the pointer take the swipe's state;
  // the ones taken earlier and now outside that range get their own back.
  void _extendTo(Offset local) {
    final anchor = _anchor;
    final index = _indexAt(local);
    if (anchor == null || index == null) return;
    final from = math.min(anchor, index);
    final to = math.max(anchor, index);
    final take = <MediaKey>[];
    final reselect = <MediaKey>[];
    final deselect = <MediaKey>[];
    for (final MapEntry(key: i, value: was) in _before.entries.toList()) {
      if (i >= from && i <= to) continue;
      _before.remove(i);
      final asset = _pages.assetAt(i);
      if (asset == null) continue;
      (was ? reselect : deselect).add(LibraryKeys.libraryKeyOf(asset));
    }
    for (var i = from; i <= to; i++) {
      if (i == anchor || _before.containsKey(i)) continue;
      final asset = _pages.assetAt(i);
      if (asset == null) continue;
      final key = LibraryKeys.libraryKeyOf(asset);
      _before[i] = widget.selection.orderOf(key) != null;
      take.add(key);
    }
    final selection = widget.selection;
    for (final (keys, state) in [
      (deselect, false),
      (reselect, true),
      (take, _selecting),
    ]) {
      if (keys.isEmpty) continue;
      for (final (key, reason) in selection.toggleRange(keys, to: state)) {
        _report(key, reason);
      }
    }
  }

  void _swipeEnd() {
    _ticker?.stop();
    setState(() {
      _anchor = null;
      _swiping = false;
      _pointer = null;
      _before.clear();
    });
  }

  void _updateAutoScroll(Offset local) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final edge = widget.policy.autoScrollEdge;
    final near = local.dy < edge || local.dy > box.size.height - edge;
    if (near && !_autoScroll.isActive) {
      unawaited(_autoScroll.start());
    } else if (!near && _autoScroll.isActive) {
      _autoScroll.stop();
    }
  }

  void _onAutoScroll(Duration _) {
    final pointer = _pointer;
    final box = context.findRenderObject() as RenderBox?;
    if (pointer == null || box == null || !_controller.hasClients) return;
    final edge = widget.policy.autoScrollEdge;
    final height = box.size.height;
    // Faster the deeper the pointer is in the edge band, up to 16 px a frame.
    final depth = pointer.dy < edge
        ? -(edge - pointer.dy) / edge
        : pointer.dy > height - edge
        ? (pointer.dy - (height - edge)) / edge
        : 0.0;
    if (depth == 0) return;
    final position = _controller.position;
    final target = (position.pixels + depth.clamp(-1, 1) * 16).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    _controller.jumpTo(target);
    _extendTo(pointer);
  }

  Map<Type, GestureRecognizerFactory> _gestures(double width) {
    final rule = widget.policy.swipeRule;
    return switch (rule) {
      SwipeSelectRule.longPressDrag => {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..onLongPressStart = ((d) => _swipeStart(d.localPosition))
                ..onLongPressMoveUpdate = ((d) => _swipeUpdate(d.localPosition))
                ..onLongPressEnd = ((_) => _swipeEnd())
                ..onLongPressCancel = _swipeEnd,
            ),
      },
      SwipeSelectRule.horizontalPan => {
        HorizontalSwipeSelectRecognizer:
            GestureRecognizerFactoryWithHandlers<
              HorizontalSwipeSelectRecognizer
            >(
              () => HorizontalSwipeSelectRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..startInset = widget.policy.swipeStartInset
                ..verticalSlop = widget.policy.swipeVerticalSlop
                ..horizontalSlop = widget.policy.swipeHorizontalSlop
                ..leadingEdgeIsRight =
                    Directionality.of(context) == TextDirection.rtl
                ..width = width
                ..onStart = _swipeStart
                ..onUpdate = _swipeUpdate
                ..onEnd = _swipeEnd,
            ),
      },
    };
  }

  // --- Build ---

  // The text root: the grid and its states draw text of their own, and a
  // host that pushed them without one would draw it in the fallback style.
  @override
  Widget build(BuildContext context) =>
      MpxTextRoot.wrap(context, _content(context));

  Widget _content(BuildContext context) {
    final policy = widget.policy;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final screen = MediaQuery.maybeSizeOf(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return ColoredBox(
      color: widget.tokens.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final columns = policy.columnsFor(size, screen: screen);
          final extent = policy.cellExtent(size.width, columns);
          final camera =
              widget.cameraSlotBuilder != null &&
              widget.cameraAllowed &&
              !(widget.cameraDenied && !policy.keepsDeniedCameraSlot) &&
              policy.showsCameraSlot(
                isAllMedia: widget.album.kind == LibraryAlbumKind.allMedia,
                columns: columns,
              );
          _hasCamera = camera;
          _padding = policy.padding;
          final delegate = LibraryGridDelegate(
            columns: columns,
            extent: extent,
            gap: policy.gap,
            cameraSlot: camera,
          );
          _layout = LibraryGridLayout(
            columns: columns,
            extent: extent,
            gap: policy.gap,
            cameraSlot: camera,
            reverseCrossAxis: rtl,
            crossAxisExtent: size.width - 2 * policy.padding,
          );
          _tellLayout();
          final pixels = (extent * dpr).ceil();
          final scope = AssetCacheProvider.maybeOf(context);
          final count = _pages.total + (camera ? 1 : 0);
          return RawGestureDetector(
            gestures: _gestures(size.width),
            child: CustomScrollView(
              controller: _controller,
              physics: _swiping
                  ? const NeverScrollableScrollPhysics()
                  : widget.physics,
              // One screen of prefetch; cells past it are not built.
              cacheExtent: size.height.isFinite ? size.height : 500,
              slivers: [
                SliverPadding(
                  // The host's bars over the grid's bottom (a caption bar,
                  // tabs, the safe area) come as the bottom padding: the
                  // last row scrolls clear of them.
                  padding: EdgeInsets.all(policy.padding).copyWith(
                    bottom:
                        policy.padding + MediaQuery.paddingOf(context).bottom,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: delegate,
                    delegate: SliverChildBuilderDelegate(
                      (context, child) => _cell(
                        context,
                        child,
                        camera: camera,
                        columns: columns,
                        extent: extent,
                        pixels: pixels,
                        scope: scope,
                      ),
                      childCount: count,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    int child, {
    required bool camera,
    required int columns,
    required double extent,
    required int pixels,
    required AssetCacheScope? scope,
  }) {
    final layout = _layout!;
    final (row, column) = layout.cellOf(child);
    final corner = Radius.circular(widget.policy.firstRowCornerRadius);
    final radius = BorderRadiusDirectional.only(
      topStart: row == 0 && column == 0 ? corner : Radius.zero,
      topEnd: row == 0 && column == columns - 1 ? corner : Radius.zero,
    ).resolve(Directionality.of(context));
    if (camera && child == 0) {
      return Semantics(
        button: true,
        label: widget.labels.camera,
        onTap: widget.onCameraTap,
        onLongPress: widget.onCameraLongPress,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onCameraTap,
          onLongPress: widget.onCameraLongPress,
          child: ClipRRect(
            borderRadius: radius,
            child: ColoredBox(
              color: widget.tokens.cameraSlotBackground,
              child: widget.cameraSlotBuilder!(context, _signals),
            ),
          ),
        ),
      );
    }
    final index = camera ? child - 1 : child;
    final asset = _pages.assetAt(index);
    if (asset != null) {
      _known.tell(scope, LibraryKeys.thumbnailDescriptorOf(asset, pixels));
    }
    final key = asset == null ? null : LibraryKeys.libraryKeyOf(asset);
    return LibraryGridCell(
      key: key == null ? null : ValueKey<MediaKey>(key),
      originIndex: index,
      asset: asset,
      extent: extent,
      thumbnailPixels: pixels,
      policy: widget.policy,
      tokens: widget.tokens,
      labels: widget.labels,
      order: key == null ? null : widget.selection.orderOf(key),
      dimmed: key != null && widget.selection.refusalOf(key) != null,
      radius: radius,
      decoration: asset == null
          ? null
          : widget.decorationBuilder?.call(context, asset),
      highQuality: widget.highQuality,
      onToggle: () {
        if (asset != null) _toggle(asset);
      },
      onOpen: () {
        if (asset != null) widget.onOpen?.call(asset, index);
      },
    );
  }
}

/// The horizontal swipe of [SwipeSelectRule.horizontalPan]: it starts only
/// past [startInset] from the leading edge, fails when the pointer moves
/// more than [verticalSlop] vertically before [horizontalSlop]
/// horizontally, and wins the arena (over the vertical scroll) once it
/// moved [horizontalSlop] horizontally.
class HorizontalSwipeSelectRecognizer extends OneSequenceGestureRecognizer {
  /// Creates the recognizer.
  HorizontalSwipeSelectRecognizer({super.debugOwner});

  /// The leading band where a swipe may not start.
  double startInset = 44;

  /// The vertical movement that fails it before it is accepted.
  double verticalSlop = 5;

  /// The horizontal movement that accepts it.
  double horizontalSlop = 8;

  /// Whether the leading edge is the right one (right-to-left).
  bool leadingEdgeIsRight = false;

  /// The width of the region, for a right leading edge.
  double? width;

  /// Called once accepted, with where the pointer went down (local).
  ValueChanged<Offset>? onStart;

  /// Called as the pointer moves once accepted (local).
  ValueChanged<Offset>? onUpdate;

  /// Called when the pointer goes up or the swipe is cancelled.
  VoidCallback? onEnd;

  Offset? _down;
  Offset? _downLocal;
  bool _accepted = false;
  Matrix4? _transform;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    final x = event.localPosition.dx;
    final fromLeading = leadingEdgeIsRight && width != null ? width! - x : x;
    return fromLeading > startInset && super.isPointerAllowed(event);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_down != null) return;
    super.addAllowedPointer(event);
    _down = event.position;
    _downLocal = event.localPosition;
    _transform = event.transform;
    _accepted = false;
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _down;
    if (down == null) return;
    if (event is PointerMoveEvent) {
      final delta = event.position - down;
      if (!_accepted) {
        if (delta.dy.abs() > verticalSlop) {
          resolve(GestureDisposition.rejected);
          stopTrackingPointer(event.pointer);
          return;
        }
        if (delta.dx.abs() > horizontalSlop) {
          _accepted = true;
          resolve(GestureDisposition.accepted);
          onStart?.call(_downLocal!);
        }
      }
      if (_accepted) {
        onUpdate?.call(
          PointerEvent.transformPosition(_transform, event.position),
        );
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_accepted) onEnd?.call();
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _down = null;
    _downLocal = null;
    _accepted = false;
  }

  @override
  void rejectGesture(int pointer) {
    if (_accepted) onEnd?.call();
    super.rejectGesture(pointer);
  }

  @override
  String get debugDescription => 'horizontal swipe select';
}
