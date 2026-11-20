import 'package:flutter/widgets.dart';

/// What a page of a gallery pager does with the gestures the pager's one
/// gesture owner hands it: zoom, pan, taps and a held press.
///
/// A page (a photo, a video, an animation) implements it and attaches to
/// the [GalleryPageScope] above it; the pager asks the page it rests on
/// before it decides a gesture, and hands it the pans, pinches and taps.
/// Positions are local to the page, which fills the pager.
///
/// Contract the pager uses; hosts that only place pages never call it.
abstract interface class GalleryPageGestures {
  /// Whether the picture is away from its rest (zoomed or panned): a drag
  /// pans it rather than paging or dismissing.
  bool get isZoomed;

  /// Whether a pinch zooms the picture.
  bool get canZoom;

  /// How long a press is held before [holdStart]; null for no hold.
  Duration? get holdDelay;

  /// Whether a double tap at [local] does something, so a single tap there
  /// waits to tell the two apart.
  bool acceptsDoubleTap(Offset local);

  /// A touch came down: a running zoom settle or fling stops.
  void stop();

  /// Pans the zoomed picture by [delta] and returns the part of the
  /// horizontal delta it did not take because it is at its edge toward a
  /// side the pager can page to, so the pager takes it: [leftOpen] when a
  /// page lies to the left (a drag to the right past the picture's left
  /// edge hands on), [rightOpen] to the right. Toward a side with no page
  /// the picture follows past its edge, damped, and 0 is returned.
  double panBy(Offset delta, {required bool leftOpen, required bool rightOpen});

  /// The pan ended with [velocity] (logical pixels per second): the
  /// picture flings within its bounds and settles back inside them.
  void panEnd(Offset velocity);

  /// Two fingers came down with their centre at [focal].
  void pinchStart(Offset focal);

  /// The fingers are [scale] times as far apart as at the start, their
  /// centre at [focal].
  void pinchUpdate(double scale, Offset focal);

  /// The pinch ended: the zoom settles into its range.
  void pinchEnd();

  /// A single tap at [local].
  void tap(Offset local);

  /// A double tap, at the second press, at [local].
  void doubleTap(Offset local);

  /// A press held at [local] for [holdDelay]; true when the page took it,
  /// and the moves until the lift are its own ([holdMove]).
  bool holdStart(Offset local);

  /// The held press moved to [local].
  void holdMove(Offset local);

  /// The held press ended.
  void holdEnd();

  /// The pager left the page: the picture goes back to rest at once.
  void reset();
}

/// The page a [GalleryPageGestures] attaches to: one per page of a gallery
/// pager, telling the page its index.
class GalleryPageScope extends InheritedWidget {
  /// Creates the scope of the page at [index].
  const GalleryPageScope({
    required this.index,
    required this.slot,
    required super.child,
    super.key,
  });

  /// The page's index.
  final int index;

  /// Where the page's gestures attach.
  final GalleryPageSlot slot;

  /// The scope above [context], or null outside a gallery pager.
  static GalleryPageScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GalleryPageScope>();

  @override
  bool updateShouldNotify(GalleryPageScope oldWidget) =>
      index != oldWidget.index || !identical(slot, oldWidget.slot);
}

/// The place in a gallery pager a page's [GalleryPageGestures] attaches to.
final class GalleryPageSlot {
  /// Creates an empty slot.
  GalleryPageSlot();

  GalleryPageGestures? _gestures;

  /// The gestures attached, or null.
  GalleryPageGestures? get gestures => _gestures;

  /// Attaches [gestures]; the latest attached wins.
  // ignore: use_setters_to_change_properties, a pair with [detach].
  void attach(GalleryPageGestures gestures) => _gestures = gestures;

  /// Detaches [gestures] when they are the ones attached.
  void detach(GalleryPageGestures gestures) {
    if (identical(_gestures, gestures)) _gestures = null;
  }
}
