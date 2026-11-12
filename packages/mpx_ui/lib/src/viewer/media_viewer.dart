import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/origin_bridge.dart';
import 'package:mpx_ui/src/viewer/viewer_actions.dart';
import 'package:mpx_ui/src/viewer/viewer_chrome_overlay.dart';
import 'package:mpx_ui/src/viewer/viewer_photo_page.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';
import 'package:mpx_ui/src/viewer/viewer_tokens.dart';

/// The fullscreen viewer: pages through a [GallerySource], opening from and
/// closing to each item's place on the host's surface through an
/// [OriginBridge], with the gestures and timings of a [ViewerPolicy] and the
/// colours of the host's [ViewerTokens].
///
/// ## Open and close
///
/// The picture morphs from its origin (rectangle, corners, clip) to its
/// fitted place while the background fades in, and the origin is hidden on
/// the surface ([OriginBridge.setHidden]) as long as the viewer stands over
/// it. Closing on another item asks the bridge to reveal that item's origin
/// first. Without an origin the picture slides off the way it was dragged,
/// or the viewer shrinks and fades when it closes without a drag.
///
/// ## Gestures
///
/// A vertical drag (past the policy's slop, twice as vertical as horizontal)
/// moves the picture and fades the background down to the policy's floor;
/// released past the policy's fraction of the height it closes, otherwise
/// it springs back. Double tap zooms around the tap, a pinch zooms within
/// the policy's range, and a horizontal swipe pages while the picture is not
/// zoomed.
///
/// ## Chrome
///
/// With [chrome] the viewer draws the top bar, the counter, the caption, the
/// thumbnail strip and the overflow menu; a tap on the picture shows or hides
/// them. The host supplies the actions per item and the title, subtitle and
/// caption builders. An action gets the item's cached file (through
/// [ViewerChrome.openFile], released when the action completes) and the
/// picture as it shows.
///
/// Media is drawn through the core's asset cache ([scope], or the closest
/// `AssetCacheProvider`); until the item's own picture arrives the origin's
/// current frame shows.
class MediaViewer extends StatefulWidget {
  /// Creates a viewer on [source], opened at [initialIndex].
  const MediaViewer({
    required this.source,
    required this.initialIndex,
    super.key,
    this.bridge,
    this.policy = ViewerPolicy.$Android,
    this.tokens = const ViewerTokens(),
    this.scope,
    this.onClosed,
    this.onIndexChanged,
    this.onBackdropScale,
    this.chrome,
  });

  /// The items.
  final GallerySource source;

  /// The item the viewer opens on.
  final int initialIndex;

  /// The link to the surface the viewer opened from; null opens and closes
  /// without a morph.
  final OriginBridge? bridge;

  /// The gestures, transitions and timings.
  final ViewerPolicy policy;

  /// The colours and type.
  final ViewerTokens tokens;

  /// The cache the pictures attach to.
  final AssetCacheScope? scope;

  /// Called once the close transition has run: remove the viewer.
  final VoidCallback? onClosed;

  /// Told the index of the item shown when it changes.
  final ValueChanged<int>? onIndexChanged;

  /// Told the scale the host draws its surface behind the viewer at, as the
  /// viewer opens, is dragged and closes; see
  /// [ViewerPolicy.backdropScale].
  final ValueChanged<double>? onBackdropScale;

  /// The bars, menu and caption, and the host's actions; none when null.
  final ViewerChrome? chrome;

  /// Pushes a viewer as a transparent route over [context]'s navigator and
  /// completes when it has closed.
  static Future<void> show(
    BuildContext context, {
    required GallerySource source,
    required int initialIndex,
    OriginBridge? bridge,
    ViewerPolicy policy = ViewerPolicy.$Android,
    ViewerTokens tokens = const ViewerTokens(),
    AssetCacheScope? scope,
    ValueChanged<double>? onBackdropScale,
    ViewerChrome? chrome,
  }) {
    final cache = scope ?? AssetCacheProvider.of(context);
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (routeContext, _, _) => MediaViewer(
          source: source,
          initialIndex: initialIndex,
          bridge: bridge,
          policy: policy,
          tokens: tokens,
          scope: cache,
          onBackdropScale: onBackdropScale,
          chrome: chrome,
          onClosed: () => Navigator.of(routeContext).pop(),
        ),
      ),
    );
  }

  @override
  State<MediaViewer> createState() => MediaViewerState();
}

enum _Phase { opening, open, closing, closed }

/// The state of a [MediaViewer]: [close] closes it as the back button does.
class MediaViewerState extends State<MediaViewer>
    with TickerProviderStateMixin {
  late int _index = widget.initialIndex;
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late final AnimationController _transition;
  late final AnimationController _springBack;
  final ValueNotifier<bool> _controls = ValueNotifier(true);

  _Phase _phase = _Phase.opening;
  Size _size = Size.zero;
  // The morph in progress: from and to, in global coordinates.
  _Frame? _from;
  _Frame? _to;
  // The background opacity the close starts from.
  double _closeFromBackground = 1;
  // How the picture leaves when nothing morphs: slide or shrink.
  bool _fadeOut = false;
  // The vertical offset of a dismiss drag, and the one a spring back left.
  double _drag = 0;
  double _springFrom = 0;
  bool _dragging = false;
  bool _zoomed = false;
  final Set<int> _hidden = {};

  /// The index of the item shown.
  int get index => _index;

  /// Whether the open transition has finished and the close has not begun.
  bool get isOpen => _phase == _Phase.open;

  /// Whether the chrome shows.
  bool get controlsVisible => _controls.value;

  /// The vertical offset of the picture from where it rests, positive down.
  double get dragOffset => _drag;

  /// The background's opacity now.
  double get backgroundOpacity => switch (_phase) {
    _Phase.opening => _transitionT,
    _Phase.open => widget.policy.backgroundOpacityAt(_drag, _size.width),
    _Phase.closing => _closeFromBackground * (1 - _transitionT),
    _Phase.closed => 0,
  };

  double get _transitionT =>
      widget.policy.openCurve.transform(_transition.value);

  @override
  void initState() {
    super.initState();
    _transition = AnimationController(vsync: this)..addListener(_onTransition);
    _springBack = AnimationController(
      vsync: this,
      duration: widget.policy.settleDuration,
    )..addListener(_onSpringBack);
    _controls.value = widget.policy.controlsVisibleOnOpen;
    widget.source.addListener(_onSource);
    widget.source.loadAround(_index);
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    widget.source.removeListener(_onSource);
    for (final index in _hidden) {
      widget.bridge?.setHidden(index, hidden: false);
    }
    _transition.dispose();
    _springBack.dispose();
    _pages.dispose();
    _controls.dispose();
    super.dispose();
  }

  void _onSource() {
    if (mounted) setState(() {});
  }

  void _hide(int index, {required bool hidden}) {
    final bridge = widget.bridge;
    if (bridge == null) return;
    if (hidden ? _hidden.add(index) : _hidden.remove(index)) {
      bridge.setHidden(index, hidden: hidden);
    }
  }

  // --- Actions --------------------------------------------------------------

  final Map<int, GlobalKey> _frameKeys = {};

  /// Runs [action] for the item at [index]: hands it the item, a way to open
  /// its cached file and the picture as shown, waits for it, then releases
  /// the files it opened.
  Future<void> runAction(ViewerAction action, int index) async {
    final item = widget.source.itemAt(index);
    if (item == null) return;
    final opener = widget.chrome?.openFile;
    final request = ViewerActionRequest(
      index: index,
      item: item,
      openFile: () async => opener == null ? null : await opener(item.key),
      captureFrame: () => _captureFrame(index),
    );
    try {
      await action.onSelected(request);
    } finally {
      request.complete();
    }
  }

  Future<ui.Image?> _captureFrame(int index) async {
    final boundary = _frameKeys[index]?.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return null;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return boundary.toImage(pixelRatio: dpr);
  }

  // --- Open -----------------------------------------------------------------

  void _open() {
    if (!mounted) return;
    final origin = widget.bridge?.originOf(_index);
    final fitted = _fittedRect(_index, origin);
    _hide(_index, hidden: true);
    _from = origin == null
        ? _Frame(fitted, opacity: 0)
        : _Frame(origin.rect, radius: origin.radius, clip: origin.clip);
    _to = _Frame(fitted);
    _transition
      ..duration = widget.policy.openDuration
      ..forward(from: 0).whenComplete(() {
        if (!mounted || _phase != _Phase.opening) return;
        setState(() => _phase = _Phase.open);
      });
  }

  // --- Close ----------------------------------------------------------------

  /// Closes the viewer on the item it shows.
  Future<void> close() async {
    if (_phase == _Phase.closing || _phase == _Phase.closed) return;
    final from = _fittedRect(_index, null).shift(Offset(0, _drag));
    final startBackground = backgroundOpacity;
    final bridge = widget.bridge;
    if (bridge != null && _index != widget.initialIndex) {
      _hide(widget.initialIndex, hidden: false);
      await bridge.reveal(_index);
      if (!mounted) return;
      _hide(_index, hidden: true);
    }
    final origin = bridge?.originOf(_index);
    final policy = widget.policy;
    _transition.stop();
    _springBack.stop();
    setState(() {
      _phase = _Phase.closing;
      _closeFromBackground = startBackground;
      _from = _Frame(from);
      _fadeOut = origin == null;
      if (origin != null) {
        _to = _Frame(origin.rect, radius: origin.radius, clip: origin.clip);
        _transition.duration = policy.closeDuration;
      } else if (_drag != 0) {
        // The origin is gone: the picture leaves the way it was dragged.
        _to = _Frame(
          from.shift(Offset(0, _drag.sign * _size.height)),
          opacity: 0,
        );
        _transition.duration = policy.slideOffDuration;
      } else {
        final shrunk = Rect.fromCenter(
          center: from.center,
          width: from.width * policy.plainCloseScale,
          height: from.height * policy.plainCloseScale,
        );
        _to = _Frame(shrunk, opacity: 0);
        _transition.duration = policy.closeDuration;
      }
    });
    await _transition.forward(from: 0);
    if (!mounted) return;
    _hide(_index, hidden: false);
    setState(() => _phase = _Phase.closed);
    widget.onClosed?.call();
  }

  // --- Drag -----------------------------------------------------------------

  late final ViewerDragEvents _dragEvents = ViewerDragEvents(
    onStart: () {
      _springBack.stop();
      _dragging = true;
      _controls.value = false;
    },
    onUpdate: (offset) {
      if (_phase != _Phase.open) return;
      setState(() => _drag = offset);
      _reportBackdrop();
    },
    onEnd: (offset) {
      _dragging = false;
      if (_phase != _Phase.open) return;
      _drag = offset;
      if (widget.policy.dismisses(offset, _size.height)) {
        unawaited(close());
      } else {
        _springFrom = offset;
        _springBack.forward(from: 0);
      }
    },
  );

  void _onSpringBack() {
    final t = widget.policy.settleCurve.transform(_springBack.value);
    setState(() => _drag = _springFrom * (1 - t));
    _reportBackdrop();
  }

  // --- Transition -----------------------------------------------------------

  void _onTransition() {
    setState(() {});
    _reportBackdrop();
  }

  void _reportBackdrop() {
    final report = widget.onBackdropScale;
    if (report == null || _size.height <= 0) return;
    final opened = switch (_phase) {
      _Phase.opening => _transitionT,
      _Phase.open => 1.0,
      _Phase.closing => 1 - _transitionT,
      _Phase.closed => 0.0,
    };
    final pulled = math.min(1, _drag.abs() / (_size.height / 2));
    report(1 + widget.policy.backdropScale * opened * (1 - pulled));
  }

  // --- Layout ---------------------------------------------------------------

  // The item's picture fitted into the viewer, in global coordinates (the
  // viewer covers the screen, so local and global agree).
  Rect _fittedRect(int index, GalleryOrigin? origin) {
    final size = _size;
    final aspect = _aspectOf(index, origin);
    if (size.isEmpty || aspect <= 0) return Offset.zero & size;
    final fitsWidth = size.width / size.height < aspect;
    final width = fitsWidth ? size.width : size.height * aspect;
    final height = fitsWidth ? size.width / aspect : size.height;
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: width,
      height: height,
    );
  }

  double _aspectOf(int index, GalleryOrigin? origin) {
    final itemSize = widget.source.itemAt(index)?.size;
    if (itemSize != null && !itemSize.isEmpty) {
      return itemSize.width / itemSize.height;
    }
    final rect = (origin ?? widget.bridge?.originOf(index))?.rect;
    if (rect != null && !rect.isEmpty) return rect.width / rect.height;
    return _size.isEmpty ? 1 : _size.width / _size.height;
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _size = constraints.biggest;
      final background = widget.tokens.background;
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(close());
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: ColoredBox(
                color: background.withValues(
                  alpha: background.a * backgroundOpacity.clamp(0.0, 1.0),
                ),
              ),
            ),
            if (_phase == _Phase.open) _pagesView() else _morph(),
            if (widget.chrome case final chrome? when _phase == _Phase.open)
              ViewerChromeOverlay(
                chrome: chrome,
                index: _index,
                source: widget.source,
                controls: _controls,
                tokens: widget.tokens,
                policy: widget.policy,
                scope: widget.scope,
                onBack: () => unawaited(close()),
                onSelectIndex: (index) => unawaited(
                  _pages.animateToPage(
                    index,
                    duration: widget.policy.controlsDuration,
                    curve: Curves.easeOut,
                  ),
                ),
                onAction: (action, index) =>
                    unawaited(runAction(action, index)),
              ),
          ],
        ),
      );
    },
  );

  Widget _pagesView() {
    final gap = widget.policy.pageGap;
    return Transform.translate(
      offset: Offset(0, _drag),
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: _size.width + gap,
          maxWidth: _size.width + gap,
          child: PageView.builder(
            controller: _pages,
            physics: _zoomed || _dragging
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemCount: widget.source.count,
            onPageChanged: (index) {
              setState(() => _index = index);
              widget.source.loadAround(index);
              widget.onIndexChanged?.call(index);
            },
            itemBuilder: (context, index) => Padding(
              padding: EdgeInsets.only(right: gap),
              child: _page(index),
            ),
          ),
        ),
      ),
    );
  }

  Widget _page(int index) {
    final item = widget.source.itemAt(index);
    final fitted = _fittedRect(index, null).size;
    if (item == null) {
      return Center(
        child: SizedBox.fromSize(
          size: fitted,
          child: ColoredBox(color: widget.tokens.placeholder),
        ),
      );
    }
    return ViewerPhotoPage(
      key: ValueKey(('mpx-viewer-page', index)),
      contentSize: fitted,
      policy: widget.policy,
      drag: _dragEvents,
      onZoomedChanged: (zoomed) => setState(() => _zoomed = zoomed),
      onTap: () => _controls.value = !_controls.value,
      child: RepaintBoundary(
        key: _frameKeys.putIfAbsent(index, GlobalKey.new),
        child: _picture(index, item, fitted, BoxFit.contain),
      ),
    );
  }

  Widget _morph() {
    final from = _from;
    final to = _to;
    final item = widget.source.itemAt(_index);
    if (from == null || to == null || item == null) {
      return const SizedBox.shrink();
    }
    final t = _transitionT;
    final rect = Rect.lerp(from.rect, to.rect, t)!;
    final radius = BorderRadius.lerp(from.radius, to.radius, t)!;
    final opacity = from.opacity + (to.opacity - from.opacity) * t;
    final screen = Offset.zero & _size;
    final clip = Rect.lerp(from.clip ?? screen, to.clip ?? screen, t)!;
    final fitted = _fittedRect(_index, null).size;
    // Morphing to an origin crops the picture as the surface does; a picture
    // that fades or slides keeps its whole frame.
    final fit = _phase == _Phase.closing && _fadeOut
        ? BoxFit.contain
        : BoxFit.cover;
    return Stack(
      children: [
        Positioned.fromRect(
          key: const ValueKey('mpx-viewer-morph'),
          rect: rect,
          child: ClipRect(
            clipper: _GlobalClip(clip, rect.topLeft),
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: ClipRRect(
                borderRadius: radius,
                child: _picture(_index, item, fitted, fit),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // The picture of [item]: the origin's frame under the item's own content,
  // which covers it once it arrives. [size] is the decode size, kept the same
  // through the morph so the morph never attaches again.
  Widget _picture(int index, GalleryItem item, Size size, BoxFit fit) {
    final frame = widget.bridge?.originOf(index)?.frame;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return FittedBox(
      fit: fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox.fromSize(
        size: size.isEmpty ? const Size(1, 1) : size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (frame != null) RawImage(image: frame, fit: BoxFit.cover),
            ContentView(
              content: item.key,
              scope: widget.scope,
              preset: AssetPresets.media(
                size: size.isEmpty ? const Size(1, 1) : size,
                devicePixelRatio: dpr,
                profile: const AssetProfile(animate: true),
              ),
              placeholder: const RectPlaceholder(),
              placeholderTint: const Color(0x00000000),
            ),
          ],
        ),
      ),
    );
  }
}

/// One end of a morph.
@immutable
final class _Frame {
  const _Frame(
    this.rect, {
    this.radius = BorderRadius.zero,
    this.clip,
    this.opacity = 1,
  });

  final Rect rect;
  final BorderRadius radius;
  final Rect? clip;
  final double opacity;
}

// Clips to [clip], given in the viewer's coordinates, for a child placed at
// [origin].
final class _GlobalClip extends CustomClipper<Rect> {
  const _GlobalClip(this.clip, this.origin);

  final Rect clip;
  final Offset origin;

  @override
  Rect getClip(Size size) => clip.shift(-origin);

  @override
  bool shouldReclip(_GlobalClip oldClipper) =>
      oldClipper.clip != clip || oldClipper.origin != origin;
}
