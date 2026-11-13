import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/origin_bridge.dart';

/// Collects the [ViewerOrigin]s below it and answers for them as the
/// viewer's [OriginBridge]: where each thumbnail sits (its rectangle,
/// corners and the clip of the scrollables around it), its current frame,
/// hiding it while the viewer covers it, scrolling it into view before the
/// viewer closes on it, and handing a video's position back.
///
/// Origins register by gallery index or by `MediaKey`; a key resolves
/// through the gallery the viewer pages ([bridgeFor]), or [source] when the
/// scope serves one gallery. `MediaViewer.show` finds the closest scope when
/// the host passes no bridge.
///
/// An item whose origin is not built (a lazy list scrolled far away) is
/// brought into view by [onReveal], when the host gives one; without an
/// origin on screen the viewer closes without the morph.
class ViewerOriginScope extends StatefulWidget {
  /// Collects the origins in [child].
  const ViewerOriginScope({
    required this.child,
    this.source,
    this.onReveal,
    super.key,
  });

  /// The gallery the origins registered by key belong to, when the scope
  /// serves one; `MediaViewer.show` passes its own otherwise.
  final GallerySource? source;

  /// Scrolls the host's surface to the item at a gallery index whose origin
  /// is not built; completes when it is.
  final Future<void> Function(int index)? onReveal;

  /// The surface.
  final Widget child;

  /// The closest scope above [context], or null.
  static ViewerOriginScopeState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<ViewerOriginScopeState>();

  /// The closest scope above [context].
  ///
  /// Throws a [FlutterError] when there is none.
  static ViewerOriginScopeState of(BuildContext context) {
    final scope = maybeOf(context);
    if (scope != null) return scope;
    throw FlutterError.fromParts([
      ErrorSummary('No ViewerOriginScope found above this widget.'),
      ErrorHint('Wrap the surface with the thumbnails in ViewerOriginScope.'),
    ]);
  }

  @override
  State<ViewerOriginScope> createState() => ViewerOriginScopeState();
}

/// The state of a [ViewerOriginScope]: the bridge to the origins below it.
class ViewerOriginScopeState extends State<ViewerOriginScope>
    implements OriginBridge {
  final List<_ViewerOriginState> _origins = [];
  final Set<int> _hidden = {};
  // The picture each hidden origin showed as it was hidden (a hidden origin
  // paints nothing to read), by the gallery it was hidden for: two galleries
  // over one scope share indexes, not items. Freed when the origin shows
  // again; callers only ever get clones.
  final Map<(GallerySource?, int), ui.Image> _frames = {};

  /// The bridge for a viewer paging [source]: origins registered by key are
  /// found through [source]'s items.
  OriginBridge bridgeFor(GallerySource source) => _SourcedBridge(this, source);

  @override
  void dispose() {
    _dropFrames();
    super.dispose();
  }

  void _dropFrames() {
    for (final frame in _frames.values) {
      frame.dispose();
    }
    _frames.clear();
  }

  void _add(_ViewerOriginState origin) => _origins.add(origin);

  void _remove(_ViewerOriginState origin) => _origins.remove(origin);

  // The origins of [index]: registered by it, or by the key of its item.
  Iterable<_ViewerOriginState> _of(int index, GallerySource? source) sync* {
    final key = (source ?? widget.source)?.itemAt(index)?.key;
    for (final origin in _origins) {
      if (origin.widget.index == index ||
          (key != null && origin.widget.media == key)) {
        yield origin;
      }
    }
  }

  bool _isHidden(_ViewerOriginState origin, GallerySource? source) {
    final index = origin.widget.index;
    if (index != null && _hidden.contains(index)) return true;
    final media = origin.widget.media;
    if (media == null) return false;
    final items = source ?? widget.source;
    return _hidden.any((hidden) => items?.itemAt(hidden)?.key == media);
  }

  GalleryOrigin? _originOf(int index, GallerySource? source) {
    for (final origin in _of(index, source)) {
      final place = origin._place();
      if (place == null) continue;
      return GalleryOrigin(
        rect: place.rect,
        radius: origin.widget.borderRadius,
        clip: place.clip,
        position: origin.widget.position?.call(),
        fit: origin.widget.fit,
      );
    }
    return null;
  }

  ui.Image? _frameOf(int index, GallerySource? source) {
    final kept = _frames[(source, index)];
    if (kept != null) return kept.clone();
    if (_hidden.contains(index)) return null;
    return _capture(index, source);
  }

  ui.Image? _capture(int index, GallerySource? source) {
    for (final origin in _of(index, source)) {
      if (origin._place() == null) continue;
      return origin._captureFrame();
    }
    return null;
  }

  Future<void> _reveal(int index, GallerySource? source) async {
    final origins = _of(index, source).toList();
    if (origins.isEmpty) {
      final reveal = widget.onReveal;
      if (reveal == null) return;
      await reveal(index);
    } else {
      final origin = origins.first;
      if (!origin.mounted || origin._showsWhole()) return;
      unawaited(
        Scrollable.ensureVisible(
          origin.context,
          alignment: 0.5,
          duration: Duration.zero,
        ),
      );
    }
    // The origin is read after the frame that lays it out.
    await SchedulerBinding.instance.endOfFrame;
  }

  void _setHidden(int index, GallerySource? source, {required bool hidden}) {
    if (hidden) {
      // Read before the origin turns transparent: it still shows the picture.
      final key = (source, index);
      if (!_frames.containsKey(key)) {
        final frame = _capture(index, source);
        if (frame != null) _frames[key] = frame;
      }
      _hidden.add(index);
    } else {
      _hidden.remove(index);
      _frames.remove((source, index))?.dispose();
    }
    for (final origin in _of(index, source)) {
      origin._hiddenChanged(source);
    }
  }

  void _handBack(int index, GallerySource? source, Duration position) {
    for (final origin in _of(index, source)) {
      origin.widget.onHandBack?.call(position);
    }
  }

  @override
  GalleryOrigin? originOf(int index) => _originOf(index, null);

  @override
  ui.Image? frameOf(int index) => _frameOf(index, null);

  @override
  Future<void> reveal(int index) => _reveal(index, null);

  @override
  void setHidden(int index, {required bool hidden}) =>
      _setHidden(index, null, hidden: hidden);

  @override
  void handBack(int index, Duration position) =>
      _handBack(index, null, position);

  @override
  Widget build(BuildContext context) => widget.child;
}

final class _SourcedBridge implements OriginBridge {
  _SourcedBridge(this._scope, this._source);

  final ViewerOriginScopeState _scope;
  final GallerySource _source;

  @override
  GalleryOrigin? originOf(int index) => _scope._originOf(index, _source);

  @override
  ui.Image? frameOf(int index) => _scope._frameOf(index, _source);

  @override
  Future<void> reveal(int index) => _scope._reveal(index, _source);

  @override
  void setHidden(int index, {required bool hidden}) =>
      _scope._setHidden(index, _source, hidden: hidden);

  @override
  void handBack(int index, Duration position) =>
      _scope._handBack(index, _source, position);
}

/// Marks a thumbnail the viewer opens from and closes to: in any
/// scrollable, grid or bubble under a [ViewerOriginScope].
///
/// It registers by gallery [index] or by [media]. While the viewer covers
/// it, it is hidden (still laid out). Its place is read when the viewer
/// asks: its rectangle on screen, [borderRadius], and the clip of every
/// scrollable around it; one scrolled out of every viewport has no place,
/// and the viewer closes without the morph. With [captureFrame] the viewer
/// starts from the picture it shows now.
class ViewerOrigin extends StatefulWidget {
  /// Marks [child] as the origin of [index] or of [media].
  const ViewerOrigin({
    required this.child,
    this.index,
    this.media,
    this.borderRadius = BorderRadius.zero,
    this.captureFrame = true,
    this.position,
    this.onHandBack,
    this.fit = BoxFit.cover,
    super.key,
  }) : assert(
         index != null || media != null,
         'An origin registers by gallery index or by media key.',
       );

  /// The item's gallery index.
  final int? index;

  /// The item's media, for a surface that does not know gallery indexes.
  final MediaKey? media;

  /// The corners of the picture as the thumbnail shows it: with [fit]
  /// contain, the corners of the picture fitted in the thumbnail's box, not
  /// of the box ([GalleryOrigin.radius]). Declare what the thumbnail
  /// draws: the morph starts and ends on these corners.
  final BorderRadius borderRadius;

  /// How the thumbnail fits its picture into its box: covering it, cropped,
  /// or whole inside it ([GalleryOrigin.fit]).
  final BoxFit fit;

  /// Whether the viewer gets the thumbnail's current picture to start from.
  final bool captureFrame;

  /// Where the thumbnail's own playback is (a looping clip), read as the
  /// viewer opens ([GalleryOrigin.position]): a video continues from there
  /// under a policy that starts at the origin.
  final Duration Function()? position;

  /// Told where the viewer's player stood as it closed on this item, so the
  /// thumbnail's loop continues from there.
  final ValueChanged<Duration>? onHandBack;

  /// The thumbnail.
  final Widget child;

  @override
  State<ViewerOrigin> createState() => _ViewerOriginState();
}

/// A thumbnail's place on screen and the clip around it, in global
/// coordinates.
typedef _Place = ({Rect rect, Rect? clip});

class _ViewerOriginState extends State<ViewerOrigin> {
  ViewerOriginScopeState? _scope;
  // The outer box is the place (it stays painted by its parents while the
  // origin is hidden); the boundary inside is what a frame is read from.
  final GlobalKey _outer = GlobalKey();
  final GlobalKey _boundary = GlobalKey();
  bool _hidden = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = ViewerOriginScope.maybeOf(context);
    if (!identical(scope, _scope)) {
      _scope?._remove(this);
      _scope = scope?.._add(this);
      _hidden = scope?._isHidden(this, null) ?? false;
    }
  }

  @override
  void dispose() {
    _scope?._remove(this);
    super.dispose();
  }

  void _hiddenChanged(GallerySource? source) {
    final hidden = _scope?._isHidden(this, source) ?? false;
    if (hidden != _hidden && mounted) setState(() => _hidden = hidden);
  }

  RenderRepaintBoundary? get _frameBox {
    final box = _boundary.currentContext?.findRenderObject();
    if (box is! RenderRepaintBoundary || !box.attached || !box.hasSize) {
      return null;
    }
    return box;
  }

  // The rectangle on screen and the clip of every viewport around it, or
  // null when no part shows or a parent does not paint it.
  _Place? _place() {
    final box = _outer.currentContext?.findRenderObject();
    if (box is! RenderBox) return null;
    final seen = ViewportVisibility.of(box);
    return seen.shows ? (rect: seen.rect, clip: seen.clip) : null;
  }

  bool _showsWhole() {
    final box = _outer.currentContext?.findRenderObject();
    return box is RenderBox && ViewportVisibility.of(box).showsWhole;
  }

  ui.Image? _captureFrame() {
    final box = _frameBox;
    if (!widget.captureFrame || box == null || _hidden) return null;
    // A boundary not painted yet has no layer to read; the flag exists only
    // in debug builds, where the capture would assert.
    if (kDebugMode && box.debugNeedsPaint) return null;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return box.toImageSync(pixelRatio: dpr);
  }

  @override
  Widget build(BuildContext context) => Opacity(
    key: _outer,
    opacity: _hidden ? 0 : 1,
    child: RepaintBoundary(key: _boundary, child: widget.child),
  );
}
