import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/src/asset/asset_binding.dart';
import 'package:mpx_core/src/asset/asset_cache_scope.dart';
import 'package:mpx_core/src/asset/asset_fade.dart';
import 'package:mpx_core/src/asset/asset_paintable.dart';
import 'package:mpx_core/src/asset/asset_preset.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/asset/asset_texture_layer.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';
import 'package:mpx_core/src/asset/outline_paintable.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/pipeline/auto_download.dart';
import 'package:mpx_core/src/playback/playback_clock.dart';
import 'package:mpx_core/src/widget/asset_cache_provider.dart';
import 'package:mpx_core/src/widget/media_badge.dart';
import 'package:mpx_core/src/widget/media_loading_style.dart';
import 'package:mpx_core/src/widget/media_status.dart';
import 'package:mpx_core/src/widget/media_status_control.dart';
import 'package:mpx_core/src/widget/media_status_mode.dart';
import 'package:mpx_core/src/widget/viewport_visibility.dart';

/// Shows cache content: attaches `(content, preset.spec, preset.profile)` to
/// the host's [AssetCacheScope], paints the binding's paintable and detaches
/// when it leaves the tree.
///
/// It is the widget for a surface that draws one piece of content outside the
/// grid viewport (a text field, a list item, a header). Stages, the
/// budget, the shared playback clock and the host's pause layers all come
/// from the binding; the view only repaints when the binding says something
/// changed, and never rebuilds for it.
///
/// ## Lifetime
///
/// The view attaches once and keeps its binding across rebuilds. It attaches
/// again only when [content], the preset's spec, [downloadContext] or the
/// scope change, giving
/// the old attach back first, so a parent that rebuilds every frame costs no
/// attach.
///
/// ## Arrival
///
/// Each stage that arrives after the view attached rises as the loading
/// style says (`MediaLoadingStyleScope.resolve`, `MediaStageStyle`): a
/// preview shows at once; a thumbnail fades in over the preview it replaces
/// (`stageFade`); content fades in over `stageFade`, or `gifFade` for a view
/// that plays, with the platform's scale-in (`contentScaleIn`). A length of
/// zero swaps at once. Each rises over the stand-in the binding kept
/// (`AssetBinding.paintStandIn`): a raster one stays opaque beneath, an
/// outline or one under content that may be transparent fades out. Without
/// a stand-in the placeholder (the view's own, or else the scope's) fades
/// out as the content rises. A stage there at the attach shows at once, so a
/// view built again over loaded content does not flicker. A raster preview
/// gets the style's wash (`previewWash`). An outline preview is filled with
/// the style's `outlineFill`, or the [placeholderTint] (else [tint]) at
/// `outlineTintOpacity`, and its shimmer (`outlineShimmer`) runs only while
/// the view is shown and the scope's clock is not paused.
///
/// ## Playback
///
/// The view shows its binding only while a [TickerMode] above it is enabled
/// and it is [inView], so a hidden route or an offstage page stops its
/// animation and lets go of what it leased for the screen (a texture, a frame
/// slot). A view that [holdsWhileTickersOff] is held instead while the
/// [TickerMode] is off: it keeps showing its frame, not playing, and keeps
/// what it leased, as a grid's cells do, so a surface kept mounted
/// while hidden shows the same frames, from the first one, when it is back.
/// An animated preset gets its own repaint boundary, because every frame
/// repaints it.
///
/// ## Texture
///
/// The view composites: a playing asset whose frames go to a platform
/// texture (`AssetPaintable.texture`) is a texture layer at the box,
/// placed as the profile's fit says and clipped to the box for a cover fit or
/// a corner radius, and is not painted. The view advances an animated
/// paintable before it reads the texture, which is what tells the paintable
/// that a surface that composites shows it.
///
/// ## Placeholder
///
/// While the binding has nothing of its own to show (it paints the scope's
/// placeholder: no stage yet, or a first frame its profile does not show
/// yet) the view paints the scope's placeholder, which every surface of the
/// scope shares whatever its content is, and which paints nothing by
/// default. A view given its own [placeholder] paints that instead, as
/// `ContentEmbed.placeholder` does: the surface knows what its
/// content is (an item, a collection's cover) and the colour its stand-in takes
/// from the theme around it, the scope knows neither. A thumbnail is the
/// binding's to paint.
///
/// A view given a [placeholderUntil] stage paints its own placeholder over
/// the binding's stand-ins (preview, thumbnail) until the content reaches
/// that stage: a surface whose own picture is sharper than any stand-in (the
/// frame a viewer opened from) keeps it until the content's frame.
///
/// ## Round
///
/// A round preset (`AssetPreset.isRound`, `AssetPresets.round`) draws its
/// stand-ins (preview, thumbnail) enlarged inside its circle by the style's
/// `roundPreviewScale`, and its status control at the round size
/// (`MediaStatusStyle.roundVideoDiameter`). An [underlay] fills the
/// picture's rounded area (the circle) under everything until the content
/// has faded in, as a round video sits on its bubble's colour.
///
/// ## Status and badge
///
/// [status] lays a status control over the content (`MediaStatusMode`): a
/// bare arc, the full control or a compact one, which download, cancel and
/// play through the binding and [onPlay]. [badge] lays the media badge
/// (duration, size) at the top-left. Both live in the view's box with their
/// own tickers; the content's paint stays repaint-only. A host replaces the
/// control with [statusBuilder], or for every view below a
/// `MediaLoadingStyleScope`.
///
/// ## Scope
///
/// [scope] if given, otherwise the closest [AssetCacheProvider]; a view with
/// neither throws a [FlutterError].
class ContentView extends StatefulWidget {
  /// Shows [content] as [preset] says.
  const ContentView({
    required this.content,
    required this.preset,
    this.tint,
    this.opacity = 1,
    this.semanticLabel,
    this.scope,
    this.status = MediaStatusMode.none,
    this.badge = false,
    this.onPlay,
    this.statusBuilder,
    this.placeholder,
    this.placeholderUntil = AssetStage.none,
    this.placeholderTint,
    this.inView = true,
    this.visibleFraction = 1,
    this.holdsWhileTickersOff = false,
    this.loadingStyle,
    this.downloadContext,
    this.requestsDownload = false,
    this.underlay,
    super.key,
  }) : assert(opacity >= 0 && opacity <= 1, 'opacity must be within 0..1'),
       assert(
         visibleFraction >= 0 && visibleFraction <= 1,
         'visibleFraction must be within 0..1',
       );

  /// Which content to show.
  final MediaKey content;

  /// The size, decode and use of the content. The view is as large as the
  /// preset's size allows its constraints.
  final AssetPreset preset;

  /// The colour a template asset (and a placeholder) is drawn in; null keeps
  /// the asset's own colours.
  final Color? tint;

  /// Opacity of the whole paint, 0 to 1.
  final double opacity;

  /// What a screen reader says for the content, for example its alternative
  /// text. Null leaves the view out of the semantics tree.
  final String? semanticLabel;

  /// The cache to attach to, instead of the one an [AssetCacheProvider]
  /// provides.
  final AssetCacheScope? scope;

  /// The status control over the content; see "Status and badge" above.
  final MediaStatusMode status;

  /// Whether the media badge (duration or "GIF", the size while it
  /// downloads) shows at the top-left.
  final bool badge;

  /// Called on a tap on play: the content shows and the [status] offers
  /// play, or it is streamable video that is not local yet.
  final VoidCallback? onPlay;

  /// Builds the status control in place of the default one, or null for the
  /// closest `MediaLoadingStyleScope`'s builder, else the default.
  final MediaStatusBuilder? statusBuilder;

  /// What the view paints before the content has a stage, and fades out
  /// under arriving content, instead of the scope's placeholder; null paints
  /// the scope's.
  final AssetPaintable? placeholder;

  /// The stage below which [placeholder] paints over the binding's
  /// stand-ins; [AssetStage.none] (the default) lets any stage of the
  /// content show.
  final AssetStage placeholderUntil;

  /// The colour [placeholder] is drawn in, or null for [tint].
  final Color? placeholderTint;

  /// Whether the view is in its viewport. False hides it as a disabled
  /// [TickerMode] does, whatever [holdsWhileTickersOff] says: a cell
  /// scrolled out of a strip.
  final bool inView;

  /// How much of the view its viewport shows, 0 to 1, passed to the binding
  /// (`AssetBinding.visibleFraction`) while it is shown. A scrolling feed
  /// sets it so a mostly hidden clip stops advancing below the profile's
  /// `AssetProfile.advanceFloor`. 0 hides the view as [inView] false does.
  final double visibleFraction;

  /// Whether a disabled [TickerMode] above holds the view rather than hiding
  /// it: it keeps its frame on screen and what it leased for it. For a
  /// surface whose tickers stop while it is still the one to come back (a
  /// surface that moves or is kept mounted while hidden).
  final bool holdsWhileTickersOff;

  /// The loading style of this view, instead of the one
  /// `MediaLoadingStyleScope.resolve` finds.
  final MediaLoadingStyle? loadingStyle;

  /// Where the surface shows the content, for the scope's auto-download
  /// policy (`AssetCacheScope.attach`): a host's tag such as
  /// [AutoDownloadContext.channels]. Null uses the policy's default. It never
  /// changes which entry the view attaches to.
  final AutoDownloadContext? downloadContext;

  /// Whether showing the view is the user's request for the content, as a
  /// page the user opened is: it downloads whatever the auto-download policy
  /// says (`AssetBinding.download`), as soon as the view attaches.
  final bool requestsDownload;

  /// A fill of the picture's rounded area (the circle of a round preset)
  /// under everything, until the content has faded in; null for none. A
  /// round video passes its bubble's colour.
  final Color? underlay;

  @override
  State<ContentView> createState() => _ContentViewState();
}

class _ContentViewState extends State<ContentView> {
  AssetBinding? _binding;
  AssetCacheScope? _attachedScope;
  MediaKey? _attachedContent;
  AssetPreset? _attachedPreset;
  AutoDownloadContext? _attachedContext;
  // Whether the tickers above are on.
  bool _tickers = true;

  // Whether the binding plays: tickers on and in view.
  bool get _shown => _tickers && widget.inView;

  // Whether the view was inside every viewport around it when it last
  // measured ([ViewportVisibility]): a cell laid out and painted outside the
  // window (a shrink-wrapped grid in a list builds and paints all of them)
  // is hidden as one scrolled out of a strip is, so only the cells on screen
  // play. A playing view measures only when something may have moved it
  // (one of the scroll positions around it, the window, its attach), in the
  // one pass after the frame; see [_ScreenPass].
  bool _onScreen = true;

  // The scroll positions around the view, innermost first, listened to while
  // the view plays.
  List<ScrollPosition> _positions = const [];

  // Re-reads the scroll positions around the view and listens to them; one
  // that does not play listens to none and counts as on screen.
  void _watchScreen() {
    final watch = widget.preset.profile.animate;
    final positions = <ScrollPosition>[];
    if (watch) {
      var scrollable = Scrollable.maybeOf(context);
      while (scrollable != null) {
        positions.add(scrollable.position);
        scrollable = scrollable.context
            .findAncestorStateOfType<ScrollableState>();
      }
      // The window's size moves every viewport: read as a dependency.
      MediaQuery.maybeSizeOf(context);
    }
    if (!_samePositions(positions)) {
      for (final position in _positions) {
        position.removeListener(_moved);
      }
      _positions = positions;
      for (final position in positions) {
        position.addListener(_moved);
      }
    }
    if (watch) {
      _ScreenPass.watch(this);
    } else {
      _ScreenPass.unwatch(this);
      _setOnScreen(true);
    }
  }

  bool _samePositions(List<ScrollPosition> positions) {
    if (positions.length != _positions.length) return false;
    for (var i = 0; i < positions.length; i++) {
      if (!identical(positions[i], _positions[i])) return false;
    }
    return true;
  }

  void _moved() => _ScreenPass.mark(this);

  // Whether the last measure found a parent that does not paint the view (a
  // zero opacity, an invisible or offstage subtree), rather than a viewport
  // that clips it out. No scroll reports such a parent showing it again,
  // but its paint does: the leaf measures again the first time it is
  // painted ([_RenderContent.onPaintedUnseen]), so a view a fade or a page
  // turning visible shows plays in the next frame, and a view that stays
  // hidden is never measured again.
  bool _unpainted = false;

  void _paintedUnseen() => _ScreenPass.mark(this);

  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is RenderBox) {
      final seen = ViewportVisibility.of(box);
      final unpainted = seen.viewportsAway == double.infinity;
      if (unpainted != _unpainted) setState(() => _unpainted = unpainted);
      _setOnScreen(seen.fraction > 0);
    }
  }

  void _setOnScreen(bool onScreen) {
    if (onScreen == _onScreen) return;
    _onScreen = onScreen;
    if (_binding case final binding?) _apply(binding);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickers = TickerMode.valuesOf(context).enabled;
    // Tickers turning on (a route that is current again) may show a view no
    // scroll moved.
    if (tickers && !_tickers && widget.preset.profile.animate) {
      _ScreenPass.mark(this);
    }
    _tickers = tickers;
    _sync();
    _watchScreen();
    _apply(_binding!);
  }

  @override
  void didUpdateWidget(ContentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.requestsDownload && !oldWidget.requestsDownload) {
      _binding?.download();
    }
    _sync();
    _apply(_binding!);
    if (widget.preset.profile.animate != oldWidget.preset.profile.animate) {
      _watchScreen();
    }
  }

  // A held binding stays visible; the hold goes first when it plays again,
  // and comes last when it stops, so it is never hidden in between.
  void _apply(AssetBinding binding) {
    final held = widget.holdsWhileTickersOff && widget.inView && !_tickers;
    if (held) {
      binding
        ..held = true
        ..visible = true;
    } else {
      binding
        ..visibleFraction = _shown && _onScreen ? widget.visibleFraction : 0
        ..held = false;
    }
  }

  @override
  void dispose() {
    _ScreenPass.unwatch(this);
    for (final position in _positions) {
      position.removeListener(_moved);
    }
    _binding?.detach();
    super.dispose();
  }

  // Attaches when nothing is attached yet or the scope, content or preset
  // changed. The profile is per attach, so a changed preset attaches again as
  // a whole; the entry itself is shared when the spec is the same.
  void _sync() {
    final scope = widget.scope ?? AssetCacheProvider.of(context);
    if (identical(scope, _attachedScope) &&
        widget.content == _attachedContent &&
        widget.preset == _attachedPreset &&
        widget.downloadContext == _attachedContext) {
      return;
    }
    // Attach first, so an entry both attaches share is never
    // left without a holder in between.
    final previous = _binding;
    _attachedScope = scope;
    _attachedContent = widget.content;
    _attachedPreset = widget.preset;
    _attachedContext = widget.downloadContext;
    _binding = scope.attach(
      widget.content,
      widget.preset.spec,
      widget.preset.profile,
      downloadContext: widget.downloadContext,
    );
    _apply(_binding!);
    if (widget.requestsDownload) _binding!.download();
    previous?.detach();
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    Widget view = _ContentLeaf(
      binding: _binding!,
      placeholder: widget.placeholder ?? _attachedScope!.placeholder,
      scopePlaceholder: _attachedScope!.placeholder,
      standsIn: widget.placeholder != null,
      placeholderTint: widget.placeholderTint,
      size: preset.size,
      tint: widget.tint,
      opacity: widget.opacity,
      placeholderUntil: widget.placeholder == null
          ? AssetStage.none
          : widget.placeholderUntil,
      ticking: _shown,
      clock: _attachedScope!.clock,
      stages: MediaLoadingStyleScope.resolve(
        context,
        style: widget.loadingStyle,
      ).stages,
      underlay: widget.underlay,
      round: preset.isRound,
      onPaintedUnseen: _unpainted && preset.profile.animate
          ? _paintedUnseen
          : null,
    );
    if (preset.profile.animate) view = RepaintBoundary(child: view);
    if (widget.status is! MediaStatusMode$None || widget.badge) {
      view = _Overlays(
        binding: _binding!,
        status: widget.status,
        badge: widget.badge,
        onPlay: widget.onPlay,
        statusBuilder: widget.statusBuilder,
        width: preset.size.width,
        round: preset.isRound,
        child: view,
      );
    }
    final label = widget.semanticLabel;
    if (label == null) return view;
    return Semantics(label: label, image: true, child: view);
  }
}

class _ContentLeaf extends LeafRenderObjectWidget {
  const _ContentLeaf({
    required this.binding,
    required this.placeholder,
    required this.scopePlaceholder,
    required this.standsIn,
    required this.placeholderTint,
    required this.size,
    required this.tint,
    required this.opacity,
    required this.placeholderUntil,
    required this.ticking,
    required this.clock,
    required this.stages,
    required this.underlay,
    required this.round,
    required this.onPaintedUnseen,
  });

  final AssetBinding binding;
  final AssetPaintable placeholder;
  final AssetPaintable scopePlaceholder;
  final bool standsIn;
  final Color? placeholderTint;
  final Size size;
  final Color? tint;
  final double opacity;
  final AssetStage placeholderUntil;
  final bool ticking;
  final PlaybackClock clock;
  final MediaStageStyle stages;
  final Color? underlay;
  final bool round;
  final VoidCallback? onPaintedUnseen;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderContent(
    binding: binding,
    placeholder: placeholder,
    scopePlaceholder: scopePlaceholder,
    standsIn: standsIn,
    placeholderTint: placeholderTint,
    preferredSize: size,
    tint: tint,
    opacity: opacity,
    placeholderUntil: placeholderUntil,
    ticking: ticking,
    clock: clock,
    stages: stages,
    underlay: underlay,
    round: round,
    onPaintedUnseen: onPaintedUnseen,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderContent renderObject) {
    renderObject
      ..binding = binding
      ..placeholder = placeholder
      ..scopePlaceholder = scopePlaceholder
      ..standsIn = standsIn
      ..placeholderTint = placeholderTint
      ..preferredSize = size
      ..tint = tint
      ..opacity = opacity
      ..placeholderUntil = placeholderUntil
      ..ticking = ticking
      ..clock = clock
      ..stages = stages
      ..underlay = underlay
      ..round = round
      ..onPaintedUnseen = onPaintedUnseen;
  }
}

class _RenderContent extends RenderBox {
  _RenderContent({
    required AssetBinding binding,
    required AssetPaintable placeholder,
    required AssetPaintable scopePlaceholder,
    required bool standsIn,
    required Color? placeholderTint,
    required Size preferredSize,
    required Color? tint,
    required double opacity,
    required AssetStage placeholderUntil,
    required bool ticking,
    required PlaybackClock clock,
    required MediaStageStyle stages,
    required Color? underlay,
    required bool round,
    required VoidCallback? onPaintedUnseen,
  }) : _binding = binding,
       _fade = AssetFade(binding),
       _placeholder = placeholder,
       _scopePlaceholder = scopePlaceholder,
       _standsIn = standsIn,
       _placeholderTint = placeholderTint,
       _preferredSize = preferredSize,
       _tint = tint,
       _opacity = opacity,
       _placeholderUntil = placeholderUntil,
       _ticking = ticking,
       _clock = clock,
       _stages = stages,
       _underlay = underlay,
       _round = round,
       _onPaintedUnseen = onPaintedUnseen,
       _armed = onPaintedUnseen != null;

  AssetBinding _binding;
  AssetFade _fade;
  // What the content fades in over when the binding kept no thumbnail.
  AssetPaintable _placeholder;
  // What the binding paints while it has nothing of its own to show.
  AssetPaintable _scopePlaceholder;
  // Whether [_placeholder] is the view's own, painted in place of the
  // scope's, in [_placeholderTint].
  bool _standsIn;
  Color? _placeholderTint;
  // Whether the paintable plays, so that it may come as a texture layer: the
  // view then needs compositing, so a clip or an opacity above it applies to
  // the layer.
  bool _playing = false;
  Size _preferredSize;
  Color? _tint;
  double _opacity;
  AssetStage _placeholderUntil;
  bool _ticking;

  // Called the first time the view is painted after its state found a
  // parent that does not paint it (_ContentViewState._unpainted).
  VoidCallback? _onPaintedUnseen;
  bool _armed;

  set onPaintedUnseen(VoidCallback? value) {
    if (identical(_onPaintedUnseen, value)) return;
    _onPaintedUnseen = value;
    _armed = value != null;
    // The paint that tells is the next one a parent makes.
    if (_armed) markNeedsPaint();
  }

  set binding(AssetBinding value) {
    if (identical(_binding, value)) return;
    if (attached) _binding.removeListener(_bindingChanged);
    _binding = value;
    _fade = AssetFade(value);
    if (attached) _binding.addListener(_bindingChanged);
    _bindingChanged();
  }

  set placeholder(AssetPaintable value) {
    if (identical(_placeholder, value)) return;
    _placeholder = value;
    markNeedsPaint();
  }

  set scopePlaceholder(AssetPaintable value) {
    if (identical(_scopePlaceholder, value)) return;
    _scopePlaceholder = value;
    markNeedsPaint();
  }

  set standsIn(bool value) {
    if (_standsIn == value) return;
    _standsIn = value;
    markNeedsPaint();
  }

  set placeholderTint(Color? value) {
    if (_placeholderTint == value) return;
    _placeholderTint = value;
    markNeedsPaint();
  }

  Color? get _placeholderColor => _standsIn ? _placeholderTint ?? _tint : _tint;

  set preferredSize(Size value) {
    if (_preferredSize == value) return;
    _preferredSize = value;
    markNeedsLayout();
  }

  set tint(Color? value) {
    if (_tint == value) return;
    _tint = value;
    markNeedsPaint();
  }

  set opacity(double value) {
    if (_opacity == value) return;
    _opacity = value;
    markNeedsPaint();
  }

  Color? _underlay;

  set underlay(Color? value) {
    if (_underlay == value) return;
    _underlay = value;
    markNeedsPaint();
  }

  // Whether the box is a circle: stand-ins are drawn enlarged inside it.
  bool _round;

  set round(bool value) {
    if (_round == value) return;
    _round = value;
    markNeedsPaint();
  }

  set placeholderUntil(AssetStage value) {
    if (_placeholderUntil == value) return;
    _placeholderUntil = value;
    markNeedsPaint();
  }

  MediaStageStyle _stages;

  // The scope's clock: a shimmer stands still while it is paused.
  PlaybackClock _clock;

  set clock(PlaybackClock value) {
    if (identical(_clock, value)) return;
    _clock = value;
    markNeedsPaint();
  }

  set stages(MediaStageStyle value) {
    if (_stages == value) return;
    _stages = value;
    markNeedsPaint();
  }

  set ticking(bool value) {
    if (_ticking == value) return;
    _ticking = value;
    // Only a shimmer reads it; a view without one must not repaint when a
    // ticker mode flips.
    if (_stages.outlineShimmer != null) markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _binding.addListener(_bindingChanged);
    _playing = _binding.paintable.isAnimated;
  }

  @override
  void detach() {
    _binding.removeListener(_bindingChanged);
    super.detach();
  }

  void _bindingChanged() {
    markNeedsPaint();
    final playing = _binding.paintable.isAnimated;
    if (playing == _playing) return;
    _playing = playing;
    markNeedsCompositingBitsUpdate();
  }

  @override
  bool get alwaysNeedsCompositing => _playing;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_preferredSize);

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_armed) {
      _armed = false;
      _onPaintedUnseen!();
    }
    final box = offset & size;
    // While the binding would paint the scope's placeholder (nothing exists
    // yet, or a first frame the profile does not show yet) the view's own
    // replaces it; nothing plays, so there is no texture to composite.
    final bare = identical(_binding.paintable, _scopePlaceholder);
    if (_underlay != null) _paintUnderlay(context.canvas, box);
    final fill = bare ? _stages.fill : null;
    if (fill != null) {
      context.canvas.drawRect(
        box,
        Paint()..color = fill.withValues(alpha: fill.a * _opacity),
      );
    }
    // A view's own placeholder that outranks the stand-in stages paints over
    // them too, until the content reaches the stage it names.
    final outranked = _binding.readiness.stage.index < _placeholderUntil.index;
    if (_standsIn && (bare || outranked)) {
      _placeholder.paint(
        context.canvas,
        box,
        AssetPaintContext(tint: _placeholderColor, opacity: _opacity),
      );
      return;
    }
    final fade = _fade.opacityAt(_frameTime, _riseLength);
    final outline = _outlineLook();
    if (fade < 1) _paintUnderContent(context.canvas, box, fade, outline);
    final opacity = _opacity * fade;
    if (AssetTextureLayer.composite(context, _binding, box, opacity: opacity)) {
      return;
    }
    final canvas = context.canvas;
    final stage = _binding.readiness.stage;
    final enlarged = _enlargesStandIn(stage);
    final scale = enlarged
        ? _stages.roundPreviewScale
        : fade < 1 && stage.index >= AssetStage.firstFrame.index
        ? 1 + _stages.contentScaleIn * (1 - Curves.easeIn.transform(fade))
        : 1.0;
    if (scale != 1) {
      canvas.save();
      if (enlarged) _clipRound(canvas, box);
      _scaleAbout(canvas, box.center, scale);
    }
    _binding.paint(
      canvas,
      box,
      tint: _tint,
      opacity: opacity,
      outline: outline,
    );
    if (scale != 1) canvas.restore();
    if (stage == AssetStage.preview && _stages.previewWash != null) {
      _paintWash(canvas, box, opacity);
    }
  }

  // Whether [stage] is a stand-in a round box draws enlarged in its circle.
  bool _enlargesStandIn(AssetStage stage) =>
      _round &&
      _stages.roundPreviewScale != 1 &&
      (stage == AssetStage.preview || stage == AssetStage.placeholder);

  void _clipRound(Canvas canvas, Rect box) =>
      canvas.clipRRect(_roundedArea(box));

  static void _scaleAbout(Canvas canvas, Offset centre, double scale) => canvas
    ..translate(centre.dx, centre.dy)
    ..scale(scale, scale)
    ..translate(-centre.dx, -centre.dy);

  // The picture's rounded area: the circle of a round box.
  RRect _roundedArea(Rect box) {
    final profile = _binding.profile;
    return RRect.fromRectAndRadius(
      profile.roundedArea(box, _binding.paintable.pictureSize),
      Radius.circular(profile.cornerRadius),
    );
  }

  // The host's fill under everything until the content has faded in: below
  // the first frame, and while the content still rises.
  void _paintUnderlay(Canvas canvas, Rect box) {
    final rising =
        _binding.readiness.stage.index < AssetStage.firstFrame.index ||
        _fade.opacityAt(_frameTime, _riseLength) < 1;
    if (!rising) return;
    final underlay = _underlay!;
    canvas.drawRRect(
      _roundedArea(box),
      Paint()..color = underlay.withValues(alpha: underlay.a * _opacity),
    );
  }

  // How long the rise from [from] to [to] fades: a preview shows at once, a
  // thumbnail fades over the preview it replaces, content over the stage
  // fade, or the loop fade for moving content a view plays.
  Duration _riseLength(AssetStage from, AssetStage to) => switch (to) {
    AssetStage.none || AssetStage.preview => Duration.zero,
    AssetStage.placeholder =>
      from == AssetStage.preview ? _stages.stageFade : Duration.zero,
    AssetStage.firstFrame ||
    AssetStage.full => _plays ? _stages.gifFade : _stages.stageFade,
  };

  bool get _plays =>
      _binding.profile.animate &&
      (_binding.paintable.isAnimated ||
          (_binding.descriptor?.animated ?? false));

  // How an outline preview is drawn, or null when the content has none: the
  // host's quiet tint at the style's opacity, else the style's fill, and the
  // shimmer's highlight while the outline shows, the view is shown and the
  // clock runs. The highlight moves with the frame time, so the next frame
  // is asked for, as for the indicator.
  OutlineLook? _outlineLook() {
    if (_binding.descriptor?.preview is! MediaPreview$Outline) return null;
    final tint = _placeholderTint ?? _tint;
    final fill = tint == null
        ? _stages.outlineFill
        : tint.withValues(alpha: tint.a * _stages.outlineTintOpacity);
    final shimmer = _stages.outlineShimmer;
    if (shimmer == null ||
        !_ticking ||
        _clock.isPaused ||
        _binding.readiness.stage != AssetStage.preview) {
      return OutlineLook(fill: fill);
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached) markNeedsPaint();
    });
    return OutlineLook(fill: fill, highlight: shimmer.phaseAt(_frameTime));
  }

  // The wash over a raster preview; an outline is drawn in its own fill.
  void _paintWash(Canvas canvas, Rect box, double opacity) {
    final wash = _stages.previewWash!;
    if (_binding.descriptor?.preview is MediaPreview$Outline) return;
    final area = _binding.profile.roundedArea(
      box,
      _binding.paintable.pictureSize,
    );
    canvas.drawRect(
      area,
      Paint()..color = wash.withValues(alpha: wash.a * opacity),
    );
  }

  static Duration get _frameTime {
    final scheduler = SchedulerBinding.instance;
    return scheduler.schedulerPhase == SchedulerPhase.idle
        ? Duration.zero
        : scheduler.currentFrameTimeStamp;
  }

  // What a stage rises over while it fades in: the stand-in the binding
  // kept (opaque, or fading out as the binding says), or the placeholder
  // fading out. The fade is a function of the frame time, so the next frame
  // is asked for, as for the indicator.
  void _paintUnderContent(
    Canvas canvas,
    Rect box,
    double fade,
    OutlineLook? outline,
  ) {
    // An outranking placeholder was on screen until now, not the stand-in.
    final ownFirst = _standsIn && _placeholderUntil != AssetStage.none;
    if (ownFirst || !_paintStandIn(canvas, box, fade, outline)) {
      _placeholder.paint(
        canvas,
        box,
        AssetPaintContext(
          tint: _placeholderColor,
          opacity: _opacity * (1 - fade),
          fit: _binding.profile.fit,
        ),
      );
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached) markNeedsPaint();
    });
  }

  // The stand-in the binding kept, under content rising at [fade]; a round
  // box draws it enlarged in its circle, as it was before the rise.
  bool _paintStandIn(
    Canvas canvas,
    Rect box,
    double fade,
    OutlineLook? outline,
  ) {
    // A kept stand-in is a preview or a thumbnail, both enlarged.
    final enlarged = _round && _stages.roundPreviewScale != 1;
    if (enlarged) {
      canvas.save();
      _clipRound(canvas, box);
      _scaleAbout(canvas, box.center, _stages.roundPreviewScale);
    }
    final painted = _binding.paintStandIn(
      canvas,
      box,
      contentOpacity: fade,
      outline: outline,
    );
    if (enlarged) canvas.restore();
    return painted;
  }
}

// --- Status and badge -------------------------------------------------------

/// The status control and the badge over a view's content, in its box.
///
/// It rebuilds only when the layout of the controls changes (streamable
/// video turns from missing to local, or back); the controls follow the
/// binding themselves and repaint.
class _Overlays extends StatefulWidget {
  const _Overlays({
    required this.binding,
    required this.status,
    required this.badge,
    required this.onPlay,
    required this.statusBuilder,
    required this.width,
    required this.round,
    required this.child,
  });

  final AssetBinding binding;
  final MediaStatusMode status;
  final bool badge;
  final VoidCallback? onPlay;
  final MediaStatusBuilder? statusBuilder;
  final double width;
  // Whether the view is a circle: its centre control is the round size.
  final bool round;
  final Widget child;

  @override
  State<_Overlays> createState() => _OverlaysState();
}

class _OverlaysState extends State<_Overlays> {
  bool _streaming = false;

  @override
  void initState() {
    super.initState();
    widget.binding.addListener(_bindingChanged);
    _streaming = _readStreaming();
  }

  @override
  void didUpdateWidget(_Overlays oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding, widget.binding)) {
      oldWidget.binding.removeListener(_bindingChanged);
      widget.binding.addListener(_bindingChanged);
    }
    _streaming = _readStreaming();
  }

  @override
  void dispose() {
    widget.binding.removeListener(_bindingChanged);
    super.dispose();
  }

  // Streamable video that is not local and shows no frame: play streams it,
  // the corner control downloads it.
  bool _readStreaming() {
    if (widget.status is! MediaStatusMode$Control) return false;
    final binding = widget.binding;
    final descriptor = binding.descriptor;
    return descriptor != null &&
        descriptor.streamable &&
        descriptor.kind == MediaKind.video &&
        binding.transfer is! AssetTransfer$None &&
        binding.readiness.stage.index < AssetStage.firstFrame.index;
  }

  void _bindingChanged() {
    final streaming = _readStreaming();
    if (streaming != _streaming) setState(() => _streaming = streaming);
  }

  Widget _control(MediaStatusControl control) {
    final builder =
        widget.statusBuilder ?? MediaLoadingStyleScope.statusBuilderOf(context);
    return builder == null ? control : builder(context, control);
  }

  @override
  Widget build(BuildContext context) {
    final style = MediaLoadingStyleScope.resolve(context);
    final binding = widget.binding;
    final corner = style.status.compactOffset;
    final centre = widget.round ? style.status.roundVideoDiameter : null;
    Widget compact() => Positioned(
      left: corner.dx,
      top: corner.dy,
      child: _control(MediaStatusControl.binding(binding, compact: true)),
    );
    final controls = <Widget>[
      ...switch (widget.status) {
        MediaStatusMode$None() => const <Widget>[],
        MediaStatusMode$Arc(:final radius) => [
          Positioned.fill(
            // The control keeps its style's size whatever the box: never
            // stretched to a large tile, free to overflow a small one.
            child: OverflowBox(
              minWidth: 0,
              minHeight: 0,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: _control(
                MediaStatusControl.binding(
                  binding,
                  arcOnly: true,
                  diameter: 2 * radius,
                ),
              ),
            ),
          ),
        ],
        MediaStatusMode$Control() when _streaming => [
          Positioned.fill(
            // The control keeps its style's size whatever the box: never
            // stretched to a large tile, free to overflow a small one.
            child: OverflowBox(
              minWidth: 0,
              minHeight: 0,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: _control(
                MediaStatusControl(
                  status: const MediaStatus.icon(MediaStatusIcon.play),
                  onTap: widget.onPlay,
                  diameter: centre,
                ),
              ),
            ),
          ),
          compact(),
        ],
        MediaStatusMode$Control(:final playAction) => [
          Positioned.fill(
            // The control keeps its style's size whatever the box: never
            // stretched to a large tile, free to overflow a small one.
            child: OverflowBox(
              minWidth: 0,
              minHeight: 0,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: _control(
                MediaStatusControl.binding(
                  binding,
                  playAction: playAction,
                  onPlay: widget.onPlay,
                  diameter: centre,
                ),
              ),
            ),
          ),
        ],
        MediaStatusMode$Compact() => [compact()],
      },
    ];
    final badge = style.badge.offset;
    return Stack(
      children: [
        widget.child,
        ...controls,
        if (widget.badge)
          Positioned(
            // Beside the corner control while it shows, as one row.
            left: _streaming
                ? corner.dx + style.status.compactDiameter + 4
                : badge.dx,
            top: badge.dy,
            child: MediaBadge.binding(binding, width: widget.width),
          ),
      ],
    );
  }
}

/// The one measuring pass of every playing [ContentView], after the frame in
/// which something may have moved one: a scroll position around it changed,
/// the window changed, it attached. A view nothing moved is not measured, so
/// a still screen of playing cells costs no ancestor walks at all.
///
/// A view can also move with no scroll (a list item inserted above it, a
/// route sliding in): every [_resweep] of frames each watched view is
/// measured once more, so such a view is right within that time. A view a
/// parent did not paint (a zero opacity, an offstage page) is measured again
/// in the frame a parent paints it, so a fade-in starts it at once.
abstract final class _ScreenPass {
  static final Set<_ContentViewState> _watched = {};
  static final Set<_ContentViewState> _dirty = {};
  static bool _scheduled = false;
  static bool _counting = false;
  static Duration? _sweptAt;

  /// How often every watched view measures again, whatever moved.
  static const Duration _resweep = Duration(seconds: 1);

  static void watch(_ContentViewState view) {
    if (_watched.add(view)) mark(view);
    if (_counting) return;
    _counting = true;
    // Runs in every frame from now on (it cannot be removed): one time
    // check, and a mark of every view once a second while any is watched.
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  }

  static void unwatch(_ContentViewState view) {
    _watched.remove(view);
    _dirty.remove(view);
  }

  static void mark(_ContentViewState view) {
    _dirty.add(view);
    if (_scheduled) return;
    _scheduled = true;
    // Never asks for a frame: it rides the one the move made.
    SchedulerBinding.instance.addPostFrameCallback(_run);
  }

  static void _onFrame(Duration now) {
    if (_watched.isEmpty) {
      _sweptAt = null;
      return;
    }
    final last = _sweptAt;
    if (last == null || now < last) {
      _sweptAt = now;
      return;
    }
    if (now - last < _resweep) return;
    _sweptAt = now;
    _watched.forEach(mark);
  }

  static void _run(Duration _) {
    _scheduled = false;
    final dirty = List.of(_dirty);
    _dirty.clear();
    for (final view in dirty) {
      view._measure();
    }
  }
}
