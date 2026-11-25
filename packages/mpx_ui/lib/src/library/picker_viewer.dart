import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/library/library_grid_policy.dart';
import 'package:mpx_ui/src/library/library_grid_tokens.dart';
import 'package:mpx_ui/src/library/library_pages.dart';
import 'package:mpx_ui/src/library/picker_captures.dart';
import 'package:mpx_ui/src/library/picker_selection.dart';
import 'package:mpx_ui/src/library/picker_strip_controller.dart';
import 'package:mpx_ui/src/text/mpx_text_root.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/media_viewer.dart';
import 'package:mpx_ui/src/viewer/origin_bridge.dart';
import 'package:mpx_ui/src/viewer/viewer_origin.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';
import 'package:mpx_ui/src/viewer/viewer_policy_scope.dart';
import 'package:mpx_ui/src/viewer/viewer_tokens.dart';

/// A [GallerySource] over a library album's [pages], after the host's
/// [captures] (newest first): the viewer pages what the grid shows, loading
/// around the item it shows.
///
/// Items carry the asset's key and descriptor; a library item's thumbnail
/// of [thumbnailPixels] (what a grid cell shows) is the stand-in while the
/// original loads.
final class LibraryGallerySource extends ChangeNotifier
    implements GallerySource {
  /// Creates the source over [pages] and [captures] (which the host owns).
  LibraryGallerySource(this.pages, {this.captures, this.thumbnailPixels = 320})
    : _items = PickerItems(pages, captures: captures) {
    _items.addListener(notifyListeners);
  }

  /// The album's pages.
  final LibraryPages pages;

  /// The host's captures, oldest first; null for none.
  final ValueListenable<List<PickerCapture>>? captures;

  final PickerItems _items;

  /// The size of the stand-in thumbnail.
  final int thumbnailPixels;

  @override
  int get count => _items.total;

  /// How many captures come first.
  int get captureCount => _items.captureCount;

  /// The asset at [index], or null while its page loads.
  LibraryAsset? assetAt(int index) => _items.assetAt(index);

  /// The index of the item [key] (a capture's or a library key) among the
  /// captures and the pages read, or null.
  int? indexOf(MediaKey key) => _items.indexOf(key);

  @override
  GalleryItem? itemAt(int index) {
    final asset = _items.assetAt(index);
    if (asset == null) return null;
    final size = asset.dimensions;
    return GalleryItem(
      PickerCaptureKeys.keyOf(asset),
      kind: switch (asset) {
        LibraryAsset(kind: LibraryAssetKind.video) => GalleryMediaKind.video,
        _ when asset.has(LibraryAssetSubtype.animated) =>
          GalleryMediaKind.animation,
        _ => GalleryMediaKind.photo,
      },
      size: size == null
          ? null
          : Size(size.width.toDouble(), size.height.toDouble()),
      descriptor: PickerCaptureKeys.descriptorOf(
        asset,
        thumbnailPixels: thumbnailPixels,
      ),
      // A capture's own still (a recording's first frame): a capture has
      // no library thumbnail to stand in while its player starts.
      standIn: PickerCaptureKeys.standInOf(asset),
    );
  }

  @override
  void loadAround(int index) {
    [index, index + 1, index - 1].forEach(_items.assetAt);
  }

  @override
  void dispose() {
    _items
      ..removeListener(notifyListeners)
      ..dispose();
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
    this.chromeShown = const _Constant(value: true),
    this.chrome = kAlwaysCompleteAnimation,
    this.dismissing = const _Constant(value: false),
    this.close = _noClose,
  });

  static Future<void> _noClose() async {}

  /// Closes the viewer as its back button does (a slot's own button that
  /// leaves it, say); nothing while it opens or closes.
  final Future<void> Function() close;

  /// The item's index in the album.
  final int index;

  /// The asset shown, or null while its page loads.
  final LibraryAsset? asset;

  /// The selection the check changes.
  final PickerSelection selection;

  /// Whether the chrome shows or is coming: false from the moment it starts
  /// to go (a dismiss drag starts, the viewer closes, a policy hides it),
  /// true from the moment it starts to come back. A slot lets go of its
  /// field's focus when it turns false.
  final ValueListenable<bool> chromeShown;

  /// How much the chrome shows, 0 to 1, as it fades: the slot fades with it
  /// when it draws something the chrome's fade does not cover.
  final Animation<double> chrome;

  /// True from the start of a dismiss drag until it closes the viewer or
  /// springs back.
  final ValueListenable<bool> dismissing;

  /// The asset's key, or null while it loads.
  MediaKey? get key => asset == null ? null : PickerCaptureKeys.keyOf(asset!);

  /// What the slot's action takes: the selection, or the item shown when
  /// nothing is checked.
  List<MediaKey> get keys {
    final selected = selection.keys;
    if (selected.isNotEmpty) return selected;
    return [?key];
  }
}

// A listenable that never changes, for an item made without a viewer.
final class _Constant implements ValueListenable<bool> {
  const _Constant({required this.value});

  @override
  final bool value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
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
  /// The info line of [asset] under the title: for a video its pixel size,
  /// duration and approximate bytes (`1920x1080, 0:08, ~2.3 MB`), each part
  /// when known; nothing for a photo. A host that knows the size it will
  /// send (after compression) passes its own line.
  static String? videoInfo(LibraryAsset asset) {
    if (asset.kind != LibraryAssetKind.video) return null;
    final parts = [
      if (asset.dimensions case final size?) '${size.width}x${size.height}',
      if (asset.duration case final duration?)
        LibraryGridLabels.formatDuration(duration),
      if (asset.byteSize case final bytes?) '~${formatBytes(bytes)}',
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// [bytes] as B, KB, MB or GB with one decimal, in 1024 steps.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(1)} ${units[unit]}';
  }

  /// The picker's video rules over the platform's [resolved] ones:
  /// - a tap on a video plays or pauses it, never the chrome;
  /// - the controls never hide by themselves, and the centre is empty while
  ///   the video plays;
  /// - a video keeps no position: back to one, it starts over;
  /// - a video does not play by itself when its page shows, and does not
  ///   loop: at its end it is back at its start, paused, the play button
  ///   shown, and play plays it again from there;
  /// - a video that cannot be played says nothing: its page keeps its
  ///   picture and play tries again ([ViewerVideoFailure.silent]).
  static ViewerVideoRules videoRules(ViewerVideoRules resolved) =>
      resolved.copyWith(
        autoHides: false,
        clickPlays: true,
        centreWhilePlaying: false,
        restarts: true,
        autoplay: false,
        loops: ViewerVideoRules.loopNever,
        failure: ViewerVideoFailure.silent,
      );

  /// Shows the viewer over [source] at [initialIndex]; completes when it
  /// closed. [bridge] is the grid's origins; by default the closest
  /// `ViewerOriginScope` above [context].
  ///
  /// [video] adjusts the picker's [videoRules] (a host whose videos should
  /// autoplay or loop, say).
  ///
  /// With [overCamera] (a viewer over the camera's shots) no grid origin is
  /// used, no vertical drag dismisses, and a close slides the picture off
  /// downwards, fading.
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
    void Function(MediaKey key, int to)? onReorder,
    LibraryAsset? Function(MediaKey key)? assetOf,
    PickerStripPolicy? selectedStrip = PickerStripPolicy.$Android,
    Widget Function(BuildContext context, PickerStripController strip)?
    selectedStripBuilder,
    String? title,
    bool bottomSlotHoldsKeyboard = false,
    String? Function(LibraryAsset asset)? subtitleOf,
    ValueChanged<int>? onIndexChanged,
    OriginBridge? bridge,
    bool overCamera = false,
    ViewerVideoRules Function(ViewerVideoRules picker)? video,
  }) {
    final scope = AssetCacheProvider.of(context);
    // Over a camera the pictures have no place on screen to come from or
    // return to.
    final origins = overCamera
        ? null
        : bridge ?? ViewerOriginScope.maybeOf(context)?.bridgeFor(source);
    final resolved = ViewerPolicyScope.resolve(context, policy: policy);
    // The picker's chrome never hides by itself: only a tap or the close
    // takes it away.
    final rules = resolved.copyWith(
      // A dismiss drag let go short of the close brings the chrome back.
      controlsReturnOnSpringBack: true,
      // Over a camera no drag dismisses, and a close slides the picture
      // off downwards.
      dismissDrag: overCamera ? false : null,
      plainCloseSlides: overCamera ? true : null,
      video: switch (video) {
        final adjust? => adjust(videoRules(resolved.video)),
        null => videoRules(resolved.video),
      },
    );
    final index = ValueNotifier(initialIndex);
    final controller = ViewerController();
    final text = MpxTextRoot.styleOf(context);
    // The height of the host's bottom bar: the viewer's own bottom controls
    // (a video's seek bar) stand above it.
    final bar = ValueNotifier<double>(0);
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
                  _AboveBar(
                    bar: bar,
                    child: MediaViewer(
                      // A tap on a photo toggles its selection (when the
                      // policy says so); on a video with no player it does
                      // nothing. The chrome stays either way.
                      onPictureTap: (index, item) {
                        if (item.kind == GalleryMediaKind.video ||
                            !gridPolicy.viewerTapSelects) {
                          return;
                        }
                        if (selection.toggle(item.key)
                            case PickerToggle$Refused(:final reason)) {
                          onRefused?.call(item.key, reason);
                        }
                      },
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
                    onReorder: onReorder,
                    assetOf: assetOf,
                    selectedStrip: selectedStrip,
                    selectedStripBuilder: selectedStripBuilder,
                    title: title,
                    bottomSlotHoldsKeyboard: bottomSlotHoldsKeyboard,
                    subtitleOf: subtitleOf,
                    onBottomHeight: (height) => bar.value = height,
                    viewer: controller,
                  ),
                ],
              ),
            ),
          ),
        )
        .whenComplete(() {
          index.dispose();
          bar.dispose();
        });
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
    this.onReorder,
    this.assetOf,
    this.selectedStrip = PickerStripPolicy.$Android,
    this.selectedStripBuilder,
    this.viewer,
    this.onBottomHeight,
    this.bottomSlotHoldsKeyboard = false,
    this.title,
    this.subtitleOf,
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

  /// A strip item lifted by a long press was dragged to the place [to]
  /// (0-based) of the selection; the strip does not reorder when null.
  final void Function(MediaKey key, int to)? onReorder;

  /// The item behind a selected key the viewer's source has not read (one
  /// picked in another album), so the strip shows its marks; the source's
  /// own items need none.
  final LibraryAsset? Function(MediaKey key)? assetOf;

  /// The selected strip's sizes and timing; no strip when null (the
  /// counter then opens nothing).
  final PickerStripPolicy? selectedStrip;

  /// Draws the selected strip in place of the viewer's own, over the same
  /// behaviour (the items, the leaving ones, a lift and its edge scroll).
  final Widget Function(BuildContext context, PickerStripController strip)?
  selectedStripBuilder;

  /// Told the height the host's bottom bar takes from the bottom of the
  /// screen (the bar, the keyboard under it and the safe area), so the
  /// viewer's own bottom controls stand above it.
  final ValueChanged<double>? onBottomHeight;

  /// Whether the host's bottom slot holds the keyboard's and the safe
  /// area's place itself (a dock that grows over the keyboard): the slot
  /// then sits on the screen's bottom edge and is never lifted by the
  /// keyboard; the viewer's controls and the bottom scrim still stand on
  /// its height. Off: the chrome lifts the slot to the higher of the
  /// keyboard and the safe area.
  final bool bottomSlotHoldsKeyboard;

  /// The top bar's title: where the media goes (a chat's name).
  final String? title;

  /// The top bar's info line for an item; [PickerViewer.videoInfo] when
  /// null.
  final String? Function(LibraryAsset asset)? subtitleOf;

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
  // The top bar: 56 px under the safe area, the check 11 px and the count
  // 64 px from its end, both centred on its line.
  static const double _barHeight = 56;
  static const double _checkEnd = 11;
  static const double _checkSlop = 6;
  static const double _counterEnd = 64;

  bool _stripShown = false;

  // The selected strip's behaviour, for the viewer's skin or the host's;
  // none when the host shows no strip.
  late final PickerStripController? _selectedStrip =
      switch (widget.selectedStrip) {
        final policy? => PickerStripController(
          selection: widget.selection,
          policy: policy,
          onReorder: widget.onReorder,
        ),
        null => null,
      };

  // The item behind a selected key: the viewer's source's, else the
  // host's.
  LibraryAsset? _assetOf(MediaKey key) => switch (widget.source.indexOf(key)) {
    final index? => widget.source.assetAt(index),
    null => widget.assetOf?.call(key),
  };

  // Shows a selected item (a tap in the strip).
  void _showKey(MediaKey key) {
    final at = _indexOf[key] ?? widget.source.indexOf(key);
    if (at != null) widget.onShow?.call(at);
  }

  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: PickerViewerChrome.fadeDuration,
  );

  bool get _shown {
    final viewer = widget.viewer;
    return viewer == null || !viewer.isAttached || viewer.controlsVisible;
  }

  @override
  void initState() {
    super.initState();
    widget.viewer?.addListener(_onViewer);
    // In with the viewer's open: from nothing, over the same 200 ms.
    _onViewer();
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
    _selectedStrip?.dispose();
    _chromeShown.dispose();
    widget.viewer?.removeListener(_onViewer);
    _fade.dispose();
    super.dispose();
  }

  // Where the fade heads; the controller tells of every change (an index,
  // a lease), and restarting the fade on each would hold it in place.
  bool? _heading;

  // Where the chrome heads, for the host's slot.
  final ValueNotifier<bool> _chromeShown = ValueNotifier(true);

  void _onViewer() {
    final shown = _shown;
    if (shown == _heading) return;
    _heading = shown;
    _chromeShown.value = shown;
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
      final key = asset == null ? null : PickerCaptureKeys.keyOf(asset);
      if (key != null) _indexOf[key] = index;
      final order = key == null ? null : widget.selection.orderOf(key);
      final count = widget.selection.keys.length;
      final item = PickerViewerItem(
        index: index,
        asset: asset,
        selection: widget.selection,
        chromeShown: _chromeShown,
        chrome: _fade,
        dismissing: widget.viewer?.dismissing ?? const _Constant(value: false),
        close: widget.viewer?.close ?? PickerViewerItem._noClose,
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
  ) => Stack(
    children: [
      ..._scrims(context),
      SafeArea(
        child: Stack(
          children: [
            // The top bar: back, the host's title with the item's info line,
            // the count and the check at the end.
            PositionedDirectional(
              top: 0,
              start: 0,
              end: 0,
              height: _barHeight,
              child: KeyedSubtree(
                key: const ValueKey('mpx-picker-viewer-bar'),
                child: Stack(
                  children: [
                    PositionedDirectional(
                      start: 0,
                      top: 0,
                      width: _barHeight,
                      height: _barHeight,
                      child: Semantics(
                        button: true,
                        label: widget.labels.back,
                        child: GestureDetector(
                          key: const ValueKey('mpx-picker-viewer-back'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => widget.viewer?.close(),
                          child: Center(
                            child: Transform.flip(
                              flipX:
                                  Directionality.of(context) ==
                                  TextDirection.rtl,
                              child: CustomPaint(
                                size: const Size.square(24),
                                painter: _BackArrow(
                                  tokens.checkNumber.color ??
                                      const Color(0xFFFFFFFF),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      start: 72,
                      end: _counterEnd + 40,
                      top: 0,
                      bottom: 0,
                      child: _BarTitle(
                        title: widget.title,
                        subtitle: switch (item.asset) {
                          final asset? when policy.viewerInfoLine =>
                            (widget.subtitleOf ?? PickerViewer.videoInfo)(
                              asset,
                            ),
                          _ => null,
                        },
                        tokens: tokens,
                      ),
                    ),
                    PositionedDirectional(
                      top: (_barHeight - _CounterPill.height) / 2,
                      end: _counterEnd,
                      child: _CounterPill(
                        key: const ValueKey('mpx-picker-viewer-counter'),
                        count: count,
                        open: _stripShown && count > 0,
                        tokens: tokens,
                        onTap: () {
                          if (count > 0 && _selectedStrip != null) {
                            setState(() => _stripShown = !_stripShown);
                          }
                        },
                      ),
                    ),
                    // The check: a circle of the policy's size, its order number
                    // in it; the touch area reaches past it.
                    PositionedDirectional(
                      top:
                          (_barHeight - policy.viewerCheckSize) / 2 -
                          _checkSlop,
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
                              key: const ValueKey(
                                'mpx-picker-viewer-check-mark',
                              ),
                              size: policy.viewerCheckSize,
                              order: order,
                              tokens: tokens,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // The selected strip, under the top bar, sliding and fading in.
            if (_selectedStrip case final strip? when _stripShown && count > 0)
              PositionedDirectional(
                top: _barHeight + 5,
                start: 0,
                end: 0,
                height: policy.selectedStripHeight,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 200),
                  builder: (context, t, child) => Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, -10 * (1 - t)),
                      child: child,
                    ),
                  ),
                  child: switch (widget.selectedStripBuilder) {
                    final builder? => builder(context, strip),
                    null => _SelectedStrip(
                      controller: strip,
                      assetOf: _assetOf,
                      current: key,
                      height: policy.selectedStripHeight,
                      tokens: tokens,
                      onTap: _showKey,
                      onDeselect: _toggle,
                    ),
                  },
                ),
              ),
          ],
        ),
      ),
      // The host's bottom bar (a caption field and a send button), from the
      // screen's bottom: on the keyboard while it is up, at the safe area
      // when it is down, whichever is higher on every frame of the
      // keyboard's animation. Placed by the raw insets, not inside a safe
      // area: an inset added to a padding the host may have stripped would
      // let the bar drop below its rest place as the keyboard goes.
      if (widget.bottomBuilder case final builder?)
        Positioned(
          left: MediaQuery.viewPaddingOf(context).left,
          right: MediaQuery.viewPaddingOf(context).right,
          bottom: _barLift(context),
          child: _SizeReport(
            onHeight: _bottomHeight,
            child: builder(context, item),
          ),
        ),
    ],
  );

  // How high the host's bottom bar stands over the screen's bottom.
  double _barLift(BuildContext context) => widget.bottomSlotHoldsKeyboard
      ? 0
      : math.max(
          MediaQuery.viewInsetsOf(context).bottom,
          MediaQuery.viewPaddingOf(context).bottom,
        );

  // The host bar's height, which the bottom scrim and the viewer's bottom
  // controls follow.
  double _bottomBar = 0;

  void _bottomHeight(double height) {
    if (height != _bottomBar && mounted) setState(() => _bottomBar = height);
    widget.onBottomHeight?.call(height + _barLift(context));
  }

  // The scrims the chrome stands on, from the screen's edges, under the
  // status bar: black fading to clear, 0xD0 from the top over one and a
  // half status bars and the bar, 0xBB from the bottom over the safe area,
  // half the host's bar and 20 px. No band of colour behind the bar.
  List<Widget> _scrims(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final top = padding.top * 1.5 + _barHeight;
    final bottom = _barLift(context) + _bottomBar / 2 + 20;
    return [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: top,
        child: const IgnorePointer(
          child: DecoratedBox(
            key: ValueKey('mpx-picker-viewer-top-scrim'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xD0000000), Color(0x00000000)],
              ),
            ),
          ),
        ),
      ),
      if (widget.bottomBuilder != null)
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: bottom,
          child: const IgnorePointer(
            child: DecoratedBox(
              key: ValueKey('mpx-picker-viewer-bottom-scrim'),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xBB000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
    ];
  }

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
        : Text('$order', style: tokens.orderNumber(order!), maxLines: 1),
  );
}

/// The selected items in a row, the viewer's skin over a
/// [PickerStripController]: a tap shows one, the check at its top end
/// deselects it, a long press lifts it so a drag moves it among the others,
/// and the one the viewer shows is outlined.
///
/// A deselected item fades out where it stood while the ones after it slide
/// into the gap, and the shade under the row follows them; a lifted item
/// held near either end of the row scrolls it.
class _SelectedStrip extends StatefulWidget {
  const _SelectedStrip({
    required this.controller,
    required this.assetOf,
    required this.current,
    required this.height,
    required this.tokens,
    required this.onTap,
    required this.onDeselect,
  });

  // The row: inset 12 at the sides and the top and 6 at the
  // bottom, on a rounded shade 6 in from the screen's sides.
  static const EdgeInsets inset = EdgeInsets.fromLTRB(12, 12, 12, 6);

  final PickerStripController controller;
  // The item a key stands for, when the viewer's source or the host holds
  // it: a capture's thumbnail and a video's duration come from it.
  final LibraryAsset? Function(MediaKey key) assetOf;
  final MediaKey? current;
  final double height;
  final LibraryGridTokens tokens;
  final ValueChanged<MediaKey> onTap;
  final ValueChanged<MediaKey> onDeselect;

  @override
  State<_SelectedStrip> createState() => _SelectedStripState();
}

class _SelectedStripState extends State<_SelectedStrip> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _list = GlobalKey();

  PickerStripController get _strip => widget.controller;

  @override
  void initState() {
    super.initState();
    _strip.target = PickerStripScrollTarget.controller(_scroll);
  }

  @override
  void didUpdateWidget(_SelectedStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.target = null;
      _strip.target = PickerStripScrollTarget.controller(_scroll);
    }
  }

  @override
  void dispose() {
    _strip
      ..drop()
      ..target = null;
    _scroll.dispose();
    super.dispose();
  }

  void _lift(MediaKey key) {
    if (!_strip.reorders) return;
    unawaited(HapticFeedback.mediumImpact());
    _strip.lift(key);
  }

  // The finger along the row's viewport, the part of the row on screen,
  // from its start edge.
  void _hold(Offset global) {
    final box = _list.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final x = box.globalToLocal(global).dx;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final width = box.size.width;
    _strip.hold(rtl ? width - x : x, width);
  }

  void _drop() {
    if (_strip.lifted == null) return;
    unawaited(HapticFeedback.selectionClick());
    _strip.drop();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _strip,
    builder: (context, _) => _row(context),
  );

  Widget _row(BuildContext context) {
    final policy = _strip.policy;
    final side = policy.item;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final pixels = (side * dpr).ceil();
    final tokens = widget.tokens;
    final keys = _strip.keys;
    final leaving = _strip.leaving;
    // A library key resolves only through its descriptor; the strip holds
    // keys alone, and a library thumbnail is a still.
    final scope = AssetCacheProvider.maybeOf(context);
    for (final key in [...keys, ...leaving.keys]) {
      if (_captureOf(key) case final capture?) {
        scope?.know(PickerCaptureKeys.thumbnailDescriptorOf(capture, pixels));
      } else if (LibraryKeys.read(key) case final target?) {
        scope?.know(
          MediaDescriptor(
            key: LibraryKeys.thumbnailKeyFor(target.asset, pixels),
            kind: MediaKind.still,
          ),
        );
      }
    }
    // Each item at its place, sliding there when its place changes; a
    // removed one stays at the place it left as it fades.
    Widget place(MediaKey key, int at, {bool leaving = false}) =>
        AnimatedPositionedDirectional(
          key: ValueKey(('mpx-picker-viewer-strip', key)),
          duration: policy.move,
          curve: policy.curve,
          start: _strip.startOf(at),
          top: 0,
          width: side,
          height: side,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 1, end: leaving ? 0 : 1),
            duration: policy.leave,
            curve: policy.curve,
            builder: (context, t, child) => Opacity(opacity: t, child: child),
            child: IgnorePointer(
              ignoring: leaving,
              child: _item(key, side, dpr, pixels),
            ),
          ),
        );
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: Container(
        key: const ValueKey('mpx-picker-viewer-selected'),
        margin: EdgeInsets.symmetric(
          horizontal: _SelectedStrip.inset.left - policy.ends,
        ),
        decoration: BoxDecoration(
          color: tokens.shade,
          borderRadius: BorderRadius.circular(8),
        ),
        height: widget.height,
        child: SingleChildScrollView(
          key: _list,
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: _SelectedStrip.inset.copyWith(
            left: policy.ends,
            right: policy.ends,
          ),
          // The row's length follows its items as they slide, so the shade
          // closes with them.
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: _strip.length),
            duration: policy.move,
            curve: policy.curve,
            builder: (context, length, child) =>
                SizedBox(width: length, height: side, child: child),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (final MapEntry(key: key, value: at) in leaving.entries)
                  place(key, at, leaving: true),
                for (final (i, key) in keys.indexed) place(key, i),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // The capture [key] stands for, when it is one.
  LibraryAsset? _captureOf(MediaKey key) {
    if (key is! MediaKey$Local) return null;
    final asset = widget.assetOf(key);
    return asset != null && PickerCaptureKeys.isCapture(asset) ? asset : null;
  }

  Widget _item(MediaKey key, double side, double dpr, int pixels) {
    final tokens = widget.tokens;
    final asset = widget.assetOf(key);
    final thumbnail = switch (_captureOf(key)) {
      final capture? => PickerCaptureKeys.thumbnailKeyOf(capture, pixels),
      null => switch (LibraryKeys.read(key)) {
        final target? => LibraryKeys.thumbnailKeyFor(target.asset, pixels),
        null => key,
      },
    };
    final current = key == widget.current;
    // A video's duration on a bar along the bottom; a live photo has none.
    final duration = switch (asset) {
      LibraryAsset(kind: LibraryAssetKind.video, :final duration?)
          when !asset.has(LibraryAssetSubtype.live) =>
        duration,
      _ => null,
    };
    return Transform.scale(
      scale: key == _strip.lifted ? 1.05 : 1,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onTap(key),
        onLongPressStart: (_) => _lift(key),
        onLongPressMoveUpdate: (d) => _hold(d.globalPosition),
        onLongPressEnd: (_) => _drop(),
        onLongPressCancel: _drop,
        child: SizedBox.square(
          dimension: side,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: AssetView(
                  content: thumbnail,
                  preset: AssetPresets.square(
                    extent: side,
                    devicePixelRatio: dpr,
                    profile: const AssetProfile(fit: AssetFit.cover),
                  ),
                ),
              ),
              if (duration != null)
                PositionedDirectional(
                  start: 0,
                  end: 0,
                  bottom: 0,
                  height: 16,
                  child: _StripDuration(duration),
                ),
              DecoratedBox(
                key: const ValueKey('mpx-picker-viewer-strip-frame'),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: current
                      ? Border.all(color: tokens.accent, width: 2)
                      : null,
                ),
              ),
              PositionedDirectional(
                top: 0,
                end: 0,
                width: 36,
                height: 36,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onDeselect(key),
                  child: Align(
                    alignment: AlignmentDirectional.topEnd,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: tokens.checkFill,
                          border: Border.all(color: tokens.checkRing, width: 2),
                        ),
                        child: CustomPaint(painter: _Tick(tokens.checkRing)),
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

// A strip item's video bar, as a picked-photo cell draws it:
// 16 high across the bottom on 50 % black with its bottom corners rounded
// 4, a camcorder mark 14 x 9 at 3 in, and the duration in 12 white 18 from
// the start.
class _StripDuration extends StatelessWidget {
  const _StripDuration(this.duration);

  final Duration duration;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('mpx-picker-viewer-strip-duration'),
    decoration: const BoxDecoration(
      color: Color(0x7F000000),
      borderRadius: BorderRadius.vertical(bottom: Radius.circular(4)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Stack(
        children: [
          const PositionedDirectional(
            start: 0,
            top: 3.5,
            width: 14,
            height: 9,
            child: CustomPaint(painter: _CamcorderMark()),
          ),
          PositionedDirectional(
            start: 18,
            top: 0,
            bottom: 0,
            child: Center(
              child: Text(
                LibraryGridLabels.formatDuration(duration),
                maxLines: 1,
                style: const TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 12,
                  height: 1,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// A camcorder: a rounded body 9 wide and a lens wedge opening to the end.
class _CamcorderMark extends CustomPainter {
  const _CamcorderMark();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFFFFFFF);
    final h = size.height;
    canvas
      ..drawRRect(
        RRect.fromLTRBR(0, 0, 9, h, const Radius.circular(1.5)),
        paint,
      )
      ..drawPath(
        Path()
          ..moveTo(10, h / 2)
          ..lineTo(size.width, 0)
          ..lineTo(size.width, h)
          ..close(),
        paint,
      );
  }

  @override
  bool shouldRepaint(_CamcorderMark oldDelegate) => false;
}

class _Tick extends CustomPainter {
  const _Tick(this.colour);

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.28, w * 0.5)
        ..lineTo(w * 0.44, w * 0.66)
        ..lineTo(w * 0.72, w * 0.36),
      paint,
    );
  }

  @override
  bool shouldRepaint(_Tick oldDelegate) => oldDelegate.colour != colour;
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

/// [child] with the bottom padding raised by the host's bottom bar, so
/// whatever it lays at its bottom (a video's controls) stands above the bar.
class _AboveBar extends StatelessWidget {
  const _AboveBar({required this.bar, required this.child});

  final ValueListenable<double> bar;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: bar,
    builder: (context, height, child) {
      // Always a MediaQuery, so the viewer under it is never remounted as
      // the bar's height arrives.
      final query = MediaQuery.of(context);
      return MediaQuery(
        data: query.copyWith(
          padding: query.padding.copyWith(
            bottom: math.max(query.padding.bottom, height),
          ),
        ),
        child: child!,
      );
    },
    child: child,
  );
}

/// Tells [onHeight] its child's height after each layout that changes it.
class _SizeReport extends SingleChildRenderObjectWidget {
  const _SizeReport({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReport(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSizeReport renderObject,
  ) {
    renderObject
      ..onHeight = onHeight
      ..report();
  }
}

class _RenderSizeReport extends RenderProxyBox {
  _RenderSizeReport(this.onHeight);

  ValueChanged<double> onHeight;
  @override
  void performLayout() {
    super.performLayout();
    report();
  }

  // After the frame: the listener rebuilds the viewer.
  void report() {
    if (!hasSize) return;
    final height = size.height;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!attached) return;
      onHeight(height);
    });
  }
}

class _BackArrow extends CustomPainter {
  const _BackArrow(this.colour);

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.8, w / 2)
        ..lineTo(w * 0.2, w / 2)
        ..moveTo(w * 0.45, w * 0.25)
        ..lineTo(w * 0.2, w / 2)
        ..lineTo(w * 0.45, w * 0.75),
      paint,
    );
  }

  @override
  bool shouldRepaint(_BackArrow oldDelegate) => oldDelegate.colour != colour;
}

/// The bar's title, and the info line under it when there is one: as the
/// line comes, it fades in from 3 px lower while the title rises 12 px and
/// shrinks to 0.87; as it goes, the reverse; a new line replaces the old
/// one, the old going up and out as the new comes up and in.
class _BarTitle extends StatefulWidget {
  const _BarTitle({
    required this.title,
    required this.subtitle,
    required this.tokens,
  });

  final String? title;
  final String? subtitle;
  final LibraryGridTokens tokens;

  @override
  State<_BarTitle> createState() => _BarTitleState();
}

class _BarTitleState extends State<_BarTitle> with TickerProviderStateMixin {
  // An ease-out quint.
  static const Curve _curve = Cubic(0.23, 1, 0.32, 1);

  late final AnimationController _presence;
  late final AnimationController _swap;
  String? _old;
  String? _now;
  // Whether the line went (no info for the item shown).
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _now = _line(widget.subtitle);
    _presence = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: _now == null ? 0 : 1,
    );
    _swap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: 1,
    );
  }

  static String? _line(String? text) =>
      text == null || text.isEmpty ? null : text;

  @override
  void didUpdateWidget(_BarTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _line(widget.subtitle);
    if (next == null) {
      // Going: the old text stays drawn while it fades out.
      if (!_gone) _presence.reverse().ignore();
      _gone = true;
      return;
    }
    if (_gone || _now == null) {
      // Coming, the same line or another: it fades in where it stands, with
      // no swap. A line that went keeps its text for its fade-out, so
      // coming back to it is a coming, not a "no change".
      _gone = false;
      _old = null;
      _now = next;
      _swap.value = 1;
      _presence.forward().ignore();
      return;
    }
    if (next == _now) return;
    _old = _now;
    _now = next;
    _swap.forward(from: 0).ignore();
  }

  @override
  void dispose() {
    _presence.dispose();
    _swap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    final colour = tokens.checkNumber.color ?? const Color(0xFFFFFFFF);
    final titleStyle = TextStyle(
      color: colour,
      fontSize: 20,
      fontWeight: FontWeight.bold,
    );
    final lineStyle = TextStyle(color: colour, fontSize: 14);
    return AnimatedBuilder(
      animation: Listenable.merge([_presence, _swap]),
      builder: (context, _) {
        final p = _curve.transform(_presence.value);
        final s = _curve.transform(_swap.value);
        Widget line(String text, double opacity, double dy) => Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 20,
          child: Opacity(
            opacity: opacity.clamp(0, 1),
            child: Transform.translate(
              offset: Offset(0, dy),
              child: Text(
                text,
                style: lineStyle,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
              ),
            ),
          ),
        );
        // The line's place: 30 px down with it, 33 without.
        final top = 33 - 3 * p;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (widget.title case final title?)
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(0, -12 * p),
                  child: Transform.scale(
                    scale: 1 - 0.13 * p,
                    alignment: AlignmentDirectional.centerStart,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        title,
                        style: titleStyle,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                      ),
                    ),
                  ),
                ),
              ),
            if (_now case final now?)
              Positioned(
                left: 0,
                right: 0,
                top: top,
                height: 20,
                child: Stack(
                  key: const ValueKey('mpx-picker-viewer-subtitle'),
                  clipBehavior: Clip.none,
                  children: [
                    if (_old case final old? when s < 1)
                      line(old, p * (1 - s), -8 * s),
                    line(now, p * (_old == null ? 1 : s), 8 * (1 - s)),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
