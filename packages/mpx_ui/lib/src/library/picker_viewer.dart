import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/library/library_grid_policy.dart';
import 'package:mpx_ui/src/library/library_grid_tokens.dart';
import 'package:mpx_ui/src/library/library_pages.dart';
import 'package:mpx_ui/src/library/picker_selection.dart';
import 'package:mpx_ui/src/text/mpx_text_root.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/media_viewer.dart';
import 'package:mpx_ui/src/viewer/origin_bridge.dart';
import 'package:mpx_ui/src/viewer/viewer_origin.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';
import 'package:mpx_ui/src/viewer/viewer_policy_scope.dart';
import 'package:mpx_ui/src/viewer/viewer_tokens.dart';

/// A [GallerySource] over a library album's [pages]: the viewer pages the
/// album the grid shows, loading around the item it shows.
///
/// Items carry the asset's library key and descriptor, its thumbnail of
/// [thumbnailPixels] (what a grid cell shows) as the stand-in while the
/// original loads.
final class LibraryGallerySource extends ChangeNotifier
    implements GallerySource {
  /// Creates the source over [pages] (which the host owns).
  LibraryGallerySource(this.pages, {this.thumbnailPixels = 320}) {
    pages.addListener(notifyListeners);
  }

  /// The album's pages.
  final LibraryPages pages;

  /// The size of the stand-in thumbnail.
  final int thumbnailPixels;

  @override
  int get count => pages.total;

  /// The asset at [index], or null while its page loads.
  LibraryAsset? assetAt(int index) => pages.assetAt(index);

  @override
  GalleryItem? itemAt(int index) {
    final asset = pages.assetAt(index);
    if (asset == null) return null;
    final size = asset.dimensions;
    return GalleryItem(
      LibraryKeys.libraryKeyOf(asset),
      kind: switch (asset) {
        LibraryAsset(kind: LibraryAssetKind.video) => GalleryMediaKind.video,
        _ when asset.has(LibraryAssetSubtype.animated) =>
          GalleryMediaKind.animation,
        _ => GalleryMediaKind.photo,
      },
      size: size == null
          ? null
          : Size(size.width.toDouble(), size.height.toDouble()),
      descriptor: LibraryKeys.descriptorOf(
        asset,
        thumbnailPixels: thumbnailPixels,
      ),
    );
  }

  @override
  void loadAround(int index) {
    [index, index + 1, index - 1].forEach(pages.assetAt);
  }

  @override
  void dispose() {
    pages.removeListener(notifyListeners);
    super.dispose();
  }
}

/// What the picker-mode viewer's bottom slot is given: the item shown, and
/// the selection.
@immutable
final class PickerViewerItem {
  /// Describes the item at [index].
  const PickerViewerItem({
    required this.index,
    required this.asset,
    required this.selection,
  });

  /// The item's index in the album.
  final int index;

  /// The asset shown, or null while its page loads.
  final LibraryAsset? asset;

  /// The selection the check changes.
  final PickerSelection selection;

  /// The asset's key, or null while it loads.
  MediaKey? get key => asset == null ? null : LibraryKeys.libraryKeyOf(asset!);

  /// What the slot's action takes: the selection, or the item shown when
  /// nothing is checked.
  List<MediaKey> get keys {
    final selected = selection.keys;
    if (selected.isNotEmpty) return selected;
    return [?key];
  }
}

/// The picker-mode viewer: the fullscreen viewer of ADR 0006 over a
/// library album ([LibraryGallerySource]), composed from its pieces, with
/// the picker's chrome over it: a top-end check that goes through the
/// [PickerSelection] and its gate, a counter of the selection that shows
/// the selected items in a strip, and a bottom slot the host fills (a
/// caption and a send button in a messenger; nothing in a profile picker).
///
/// It opens from and closes to the grid cell of the item through the
/// `ViewerOrigin`s of a `ViewerOriginScope` above the grid, which hides the
/// cell while the viewer covers it.
abstract final class PickerViewer {
  /// Shows the viewer over [source] at [initialIndex]; completes when it
  /// closed. [bridge] is the grid's origins; by default the closest
  /// `ViewerOriginScope` above [context].
  static Future<void> show(
    BuildContext context, {
    required LibraryGallerySource source,
    required int initialIndex,
    required PickerSelection selection,
    required LibraryGridLabels labels,
    LibraryGridPolicy gridPolicy = LibraryGridPolicy.$Android,
    LibraryGridTokens tokens = const LibraryGridTokens(),
    ViewerPolicy? policy,
    ViewerTokens viewerTokens = const ViewerTokens(),
    PlayerPool? players,
    Widget Function(BuildContext context, PickerViewerItem item)? bottomBuilder,
    void Function(MediaKey key, PickerRefusal reason)? onRefused,
    ValueChanged<int>? onIndexChanged,
    OriginBridge? bridge,
  }) {
    final scope = AssetCacheProvider.of(context);
    final origins =
        bridge ?? ViewerOriginScope.maybeOf(context)?.bridgeFor(source);
    final rules = ViewerPolicyScope.resolve(context, policy: policy);
    final index = ValueNotifier(initialIndex);
    final controller = ViewerController();
    final text = MpxTextRoot.styleOf(context);
    return Navigator.of(context)
        .push<void>(
          PageRouteBuilder<void>(
            opaque: false,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (routeContext, _, _) => MpxTextRoot.over(
              text,
              Stack(
                fit: StackFit.expand,
                children: [
                  MediaViewer(
                    source: source,
                    initialIndex: initialIndex,
                    bridge: origins,
                    policy: rules,
                    tokens: viewerTokens,
                    scope: scope,
                    players: players,
                    controller: controller,
                    onIndexChanged: (value) {
                      index.value = value;
                      onIndexChanged?.call(value);
                    },
                    onClosed: () => Navigator.of(routeContext).pop(),
                  ),
                  PickerViewerChrome(
                    source: source,
                    index: index,
                    selection: selection,
                    labels: labels,
                    policy: gridPolicy,
                    tokens: tokens,
                    bottomBuilder: bottomBuilder,
                    onRefused: onRefused,
                    onShow: controller.jumpTo,
                    viewer: controller,
                  ),
                ],
              ),
            ),
          ),
        )
        .whenComplete(index.dispose);
  }
}

/// The picker's chrome over the viewer: the check, the counter with its
/// strip of selected items, and the host's bottom slot. Public so a host
/// that composes its own viewer from the pieces lays the same chrome.
class PickerViewerChrome extends StatefulWidget {
  /// Creates the chrome.
  const PickerViewerChrome({
    required this.source,
    required this.index,
    required this.selection,
    required this.labels,
    this.policy = LibraryGridPolicy.$Android,
    this.tokens = const LibraryGridTokens(),
    this.bottomBuilder,
    this.onRefused,
    this.onShow,
    this.viewer,
    super.key,
  });

  /// The gallery the viewer pages.
  final LibraryGallerySource source;

  /// The index the viewer shows.
  final ValueListenable<int> index;

  /// The selection the check changes.
  final PickerSelection selection;

  /// Words.
  final LibraryGridLabels labels;

  /// Check and strip sizes.
  final LibraryGridPolicy policy;

  /// Colours.
  final LibraryGridTokens tokens;

  /// Fills the bottom slot.
  final Widget Function(BuildContext context, PickerViewerItem item)?
  bottomBuilder;

  /// Called when the selection refuses the item shown.
  final void Function(MediaKey key, PickerRefusal reason)? onRefused;

  /// Moves the viewer to an index (a tap in the strip).
  final ValueChanged<int>? onShow;

  /// The viewer under the chrome: the chrome shows while its controls do,
  /// so it fades out as a dismiss drag starts and with a tap that hides
  /// them. Always shown when null.
  final ViewerController? viewer;

  /// How long the chrome takes to fade in or out.
  static const Duration fadeDuration = Duration(milliseconds: 200);

  @override
  State<PickerViewerChrome> createState() => _PickerViewerChromeState();
}

class _PickerViewerChromeState extends State<PickerViewerChrome>
    with SingleTickerProviderStateMixin {
  // Where the check and the count stand, from the top end of the safe
  // area: under the viewer's 56 px top bar, as the reference lays them.
  static const double _checkTop = 71;
  static const double _checkEnd = 11;
  static const double _checkSlop = 6;
  static const double _counterEnd = 64;

  bool _strip = false;
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: PickerViewerChrome.fadeDuration,
    value: _shown ? 1 : 0,
  );

  bool get _shown {
    final viewer = widget.viewer;
    return viewer == null || !viewer.isAttached || viewer.controlsVisible;
  }

  @override
  void initState() {
    super.initState();
    widget.viewer?.addListener(_onViewer);
  }

  @override
  void didUpdateWidget(PickerViewerChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.viewer, widget.viewer)) {
      oldWidget.viewer?.removeListener(_onViewer);
      widget.viewer?.addListener(_onViewer);
      _onViewer();
    }
  }

  @override
  void dispose() {
    widget.viewer?.removeListener(_onViewer);
    _fade.dispose();
    super.dispose();
  }

  // Where the fade heads; the controller tells of every change (an index,
  // a lease), and restarting the fade on each would hold it in place.
  bool? _heading;

  void _onViewer() {
    final shown = _shown;
    if (shown == _heading) return;
    _heading = shown;
    if (shown) {
      unawaited(_fade.forward());
    } else {
      unawaited(_fade.reverse());
    }
  }

  // Where selected keys were seen, so the strip can show them again.
  final Map<MediaKey, int> _indexOf = {};

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.index,
      widget.selection,
      widget.source,
    ]),
    builder: (context, _) {
      final index = widget.index.value;
      final asset = widget.source.assetAt(index);
      final key = asset == null ? null : LibraryKeys.libraryKeyOf(asset);
      if (key != null) _indexOf[key] = index;
      final order = key == null ? null : widget.selection.orderOf(key);
      final count = widget.selection.keys.length;
      final item = PickerViewerItem(
        index: index,
        asset: asset,
        selection: widget.selection,
      );
      final policy = widget.policy;
      final tokens = widget.tokens;
      // Faded out, the chrome takes no touches: they reach the viewer.
      return ValueListenableBuilder<double>(
        valueListenable: _fade,
        builder: (context, opacity, child) =>
            IgnorePointer(ignoring: opacity == 0, child: child),
        child: FadeTransition(
          opacity: _fade,
          child: _chrome(context, key, order, count, item, policy, tokens),
        ),
      );
    },
  );

  Widget _chrome(
    BuildContext context,
    MediaKey? key,
    int? order,
    int count,
    PickerViewerItem item,
    LibraryGridPolicy policy,
    LibraryGridTokens tokens,
  ) => SafeArea(
    child: Stack(
      children: [
        // The check: a circle of the policy's size, its order number in it,
        // under the viewer's top bar at the end; the touch area reaches
        // past it.
        PositionedDirectional(
          top: _checkTop - _checkSlop,
          end: _checkEnd - _checkSlop,
          child: Semantics(
            key: const ValueKey('mpx-picker-viewer-check'),
            button: true,
            checked: order != null,
            label: widget.labels.select,
            value: order?.toString(),
            onTap: () => _toggle(key),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _toggle(key),
              child: Padding(
                padding: const EdgeInsets.all(_checkSlop),
                child: _ViewerCheck(
                  key: const ValueKey('mpx-picker-viewer-check-mark'),
                  size: policy.viewerCheckSize,
                  order: order,
                  tokens: tokens,
                ),
              ),
            ),
          ),
        ),
        // The count: an outlined pill on the check's line, which shows or
        // hides the selected strip (a cross while it shows).
        PositionedDirectional(
          top: _checkTop + policy.viewerCheckSize / 2 - _CounterPill.height / 2,
          end: _counterEnd,
          child: _CounterPill(
            key: const ValueKey('mpx-picker-viewer-counter'),
            count: count,
            open: _strip && count > 0,
            tokens: tokens,
            onTap: () {
              if (count > 0) setState(() => _strip = !_strip);
            },
          ),
        ),
        if (_strip && count > 0)
          PositionedDirectional(
            top: policy.viewerCheckSize + 24,
            start: 0,
            end: 0,
            height: policy.selectedStripHeight,
            child: _SelectedStrip(
              keys: widget.selection.keys,
              height: policy.selectedStripHeight,
              tokens: tokens,
              onTap: (key) {
                final at = _indexOf[key];
                if (at != null) widget.onShow?.call(at);
              },
            ),
          ),
        if (widget.bottomBuilder case final builder?)
          PositionedDirectional(
            start: 0,
            end: 0,
            bottom: 0,
            child: builder(context, item),
          ),
      ],
    ),
  );

  void _toggle(MediaKey? key) {
    if (key == null) return;
    if (widget.selection.toggle(key) case PickerToggle$Refused(:final reason)) {
      widget.onRefused?.call(key, reason);
    }
  }
}

class _ViewerCheck extends StatelessWidget {
  const _ViewerCheck({
    required this.size,
    required this.tokens,
    this.order,
    super.key,
  });

  final double size;
  final LibraryGridTokens tokens;
  final int? order;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: order == null ? tokens.checkIdleFill : tokens.checkFill,
      border: Border.all(color: tokens.checkRing, width: 2),
    ),
    child: order == null
        ? null
        : Text('$order', style: tokens.checkNumber, maxLines: 1),
  );
}

class _SelectedStrip extends StatelessWidget {
  const _SelectedStrip({
    required this.keys,
    required this.height,
    required this.tokens,
    required this.onTap,
  });

  final List<MediaKey> keys;
  final double height;
  final LibraryGridTokens tokens;
  final ValueChanged<MediaKey> onTap;

  @override
  Widget build(BuildContext context) {
    final side = height - 16;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final pixels = (side * dpr).ceil();
    // A library key resolves only through its descriptor; the strip holds
    // keys alone, and a library thumbnail is a still.
    final scope = AssetCacheProvider.maybeOf(context);
    for (final key in keys) {
      if (LibraryKeys.read(key) case final target?) {
        scope?.know(
          MediaDescriptor(
            key: LibraryKeys.thumbnailKeyFor(target.asset, pixels),
            kind: MediaKind.still,
          ),
        );
      }
    }
    return ColoredBox(
      color: tokens.shade,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(8),
        children: [
          for (final key in keys)
            if (LibraryKeys.read(key) case final target?)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                child: GestureDetector(
                  onTap: () => onTap(key),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: ContentView(
                      content: LibraryKeys.thumbnailKeyFor(
                        target.asset,
                        pixels,
                      ),
                      preset: AssetPresets.square(
                        extent: side,
                        devicePixelRatio: dpr,
                        profile: const AssetProfile(fit: AssetFit.cover),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// The selection count: an outlined pill with the number in bold, which
/// springs as the count changes, grows from nothing at the first item and
/// shrinks away at none; a cross while the selected strip shows.
class _CounterPill extends StatefulWidget {
  const _CounterPill({
    required this.count,
    required this.open,
    required this.tokens,
    required this.onTap,
    super.key,
  });

  static const double height = 28;

  final int count;
  final bool open;
  final LibraryGridTokens tokens;
  final VoidCallback onTap;

  @override
  State<_CounterPill> createState() => _CounterPillState();
}

class _CounterPillState extends State<_CounterPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spring;
  double _from = 1;
  double _to = 1;
  Curve _curve = Curves.easeOutBack;
  late int _shown;

  @override
  void initState() {
    super.initState();
    _shown = widget.count;
    _from = _to = widget.count == 0 ? 0 : 1;
    _spring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: 1,
    );
  }

  @override
  void didUpdateWidget(_CounterPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.count;
    final now = widget.count;
    if (now == before) return;
    final (from, to, curve) = switch (now) {
      0 => (1.0, 0.0, Curves.decelerate),
      _ when before == 0 => (0.0, 1.0, Curves.decelerate),
      _ when now < before => (1.1, 1.0, Curves.easeOutBack),
      _ => (0.9, 1.0, Curves.easeOutBack),
    };
    _from = from;
    _to = to;
    _curve = curve;
    if (now > 0) _shown = now;
    _spring.forward(from: 0).ignore();
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.tokens.checkNumber.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.bold,
    );
    final colour = style.color ?? const Color(0xFFFFFFFF);
    return AnimatedBuilder(
      animation: _spring,
      builder: (context, child) {
        final t = _curve.transform(_spring.value);
        final scale = _from + (_to - _from) * t;
        return Transform.scale(
          scale: scale,
          child: IgnorePointer(ignoring: scale == 0, child: child),
        );
      },
      child: Semantics(
        button: true,
        value: '$_shown',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: 30,
              minHeight: _CounterPill.height,
              maxHeight: _CounterPill.height,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: colour, width: 2),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Center(
                  widthFactor: 1,
                  child: widget.open
                      ? CustomPaint(
                          size: const Size.square(10),
                          painter: _Cross(colour),
                        )
                      : Text('$_shown', style: style, maxLines: 1),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Cross extends CustomPainter {
  const _Cross(this.colour);

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas
      ..drawLine(Offset.zero, Offset(size.width, size.height), paint)
      ..drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
  }

  @override
  bool shouldRepaint(_Cross oldDelegate) => oldDelegate.colour != colour;
}
