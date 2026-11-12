import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// The layout of the viewer's chrome in one reference: bars, the "N of M"
/// counter, the caption and the thumbnail strip. Logical pixels.
@immutable
final class ViewerChromeMetrics {
  /// Creates metrics.
  const ViewerChromeMetrics({
    required this.topBarHeight,
    required this.counterGap,
    required this.counterHeight,
    required this.counterPadding,
    required this.counterRadius,
    required this.captionPadding,
    required this.captionMaxLines,
    required this.stripHeight,
    required this.thumbSize,
    required this.thumbTop,
    required this.thumbSpacing,
    required this.thumbRadius,
    required this.currentThumbMaxWidth,
    required this.currentThumbPadding,
    required this.menuItemHeight,
    required this.menuMinWidth,
  });

  /// The Android reference's chrome: a 56 px action bar, the counter pill 10
  /// px under it, a caption that shows up to five lines before it scrolls,
  /// and a 68 px strip of 42 x 56 thumbnails.
  static const ViewerChromeMetrics android = ViewerChromeMetrics(
    topBarHeight: 56,
    counterGap: 10,
    counterHeight: 23,
    counterPadding: 9,
    counterRadius: 12,
    captionPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    captionMaxLines: 5,
    stripHeight: 68,
    thumbSize: Size(42, 56),
    thumbTop: 10,
    thumbSpacing: 1,
    thumbRadius: 2,
    currentThumbMaxWidth: 84,
    currentThumbPadding: 8,
    menuItemHeight: 48,
    menuMinWidth: 196,
  );

  /// The top bar's height under the status bar.
  final double topBarHeight;

  /// The space between the top bar and the counter pill.
  final double counterGap;

  /// The counter pill's height.
  final double counterHeight;

  /// The counter pill's horizontal padding.
  final double counterPadding;

  /// The counter pill's corner radius.
  final double counterRadius;

  /// The padding around the caption.
  final EdgeInsets captionPadding;

  /// How many caption lines show before the caption scrolls.
  final int captionMaxLines;

  /// The thumbnail strip's height.
  final double stripHeight;

  /// A thumbnail's size.
  final Size thumbSize;

  /// A thumbnail's distance from the top of the strip.
  final double thumbTop;

  /// The space between thumbnails.
  final double thumbSpacing;

  /// A thumbnail's corner radius.
  final double thumbRadius;

  /// The widest the current thumbnail grows, by its aspect ratio.
  final double currentThumbMaxWidth;

  /// The space on each side of the current thumbnail.
  final double currentThumbPadding;

  /// The height of one item of the overflow menu.
  final double menuItemHeight;

  /// The overflow menu's narrowest width.
  final double menuMinWidth;
}

/// The gesture, transition and timing rules of the fullscreen viewer, as pure
/// values: no platform reads. One viewer structure runs any policy, so a host
/// may pick the feel of one platform on another.
///
/// Lengths are logical pixels; fractions are of the viewer's size.
@immutable
final class ViewerPolicy {
  /// Creates a policy. Hosts usually take a reference one, such as
  /// [$Android], and adjust it.
  const ViewerPolicy({
    required this.openDuration,
    required this.openCurve,
    required this.closeDuration,
    required this.backdropScale,
    required this.dismissSlop,
    required this.dismissFraction,
    required this.dismissDownOnly,
    required this.backgroundOpacityFloor,
    required this.backgroundFadeWidthFraction,
    required this.settleDuration,
    required this.settleCurve,
    required this.slideOffDuration,
    required this.plainCloseScale,
    required this.doubleTapZoom,
    required this.minZoom,
    required this.maxZoom,
    required this.overPanDamping,
    required this.pageGap,
    required this.controlsVisibleOnOpen,
    required this.controlsDuration,
    required this.controlsSlide,
    required this.videoAutoHide,
    required this.chrome,
  });

  /// The Android reference: the picture morphs from its origin in 200 ms
  /// while the surface behind grows to 1.1; a drag down past a sixth of
  /// the height closes it, with no velocity term; double tap zooms to 3x
  /// around the tap, a pinch stays within 1x to 3x.
  static const ViewerPolicy $Android = ViewerPolicy(
    openDuration: Duration(milliseconds: 200),
    // The reference sets no interpolator, so the platform's default
    // accelerate-then-decelerate applies.
    openCurve: Curves.easeInOut,
    closeDuration: Duration(milliseconds: 200),
    backdropScale: 0.1,
    dismissSlop: 30,
    dismissFraction: 1 / 6,
    dismissDownOnly: true,
    backgroundOpacityFloor: 127 / 255,
    backgroundFadeWidthFraction: 1 / 4,
    settleDuration: Duration(milliseconds: 250),
    // A decelerate interpolator of factor 1.5: 1 - (1 - t)^3.
    settleCurve: Curves.easeOutCubic,
    slideOffDuration: Duration(milliseconds: 200),
    plainCloseScale: 0.9,
    doubleTapZoom: 3,
    minZoom: 1,
    maxZoom: 3,
    overPanDamping: 1 / 3,
    pageGap: 15,
    controlsVisibleOnOpen: true,
    controlsDuration: Duration(milliseconds: 200),
    controlsSlide: 24,
    videoAutoHide: Duration(milliseconds: 3000),
    chrome: ViewerChromeMetrics.android,
  );

  /// How long the picture morphs from its origin to full size.
  final Duration openDuration;

  /// The curve of the open and close morphs.
  final Curve openCurve;

  /// How long the picture morphs back to its origin.
  final Duration closeDuration;

  /// How much larger the surface behind is drawn while the viewer is open:
  /// it grows from 1 to 1 + this as the viewer opens, and shrinks back to 1
  /// as a dismiss drag pulls the picture half the height away
  /// (`MediaViewer.onBackdropScale`).
  final double backdropScale;

  /// How far a vertical drag travels before it becomes a dismiss drag; it
  /// also has to be at least twice as vertical as horizontal.
  final double dismissSlop;

  /// The fraction of the height a dismiss drag must pass on release to close
  /// the viewer.
  final double dismissFraction;

  /// Whether only a downward drag dismisses; an upward one springs back.
  final bool dismissDownOnly;

  /// The background's opacity never drops below this during a dismiss drag.
  final double backgroundOpacityFloor;

  /// The drag distance, as a fraction of the width, over which the
  /// background fades from opaque to [backgroundOpacityFloor].
  final double backgroundFadeWidthFraction;

  /// How long a picture takes to spring back from a drag, and to snap its
  /// zoom into range.
  final Duration settleDuration;

  /// The curve of the spring back and of the zoom snap.
  final Curve settleCurve;

  /// How long the picture slides off when its origin is gone.
  final Duration slideOffDuration;

  /// The scale the viewer shrinks to while it fades out, when it closes
  /// without a drag and without an origin.
  final double plainCloseScale;

  /// The zoom a double tap goes to, around the tap point.
  final double doubleTapZoom;

  /// The smallest zoom a pinch settles at.
  final double minZoom;

  /// The largest zoom a pinch settles at.
  final double maxZoom;

  /// How much of a pan past the picture's edge is followed.
  final double overPanDamping;

  /// The gap between two pages.
  final double pageGap;

  /// Whether the bars show when the viewer opens.
  final bool controlsVisibleOnOpen;

  /// How long the bars take to show or hide.
  final Duration controlsDuration;

  /// How far the bars slide as they hide: the top bar up, the bottom down.
  final double controlsSlide;

  /// How long the bars stay over a playing video before they hide.
  final Duration videoAutoHide;

  /// The layout of the bars, counter, caption and strip.
  final ViewerChromeMetrics chrome;

  /// Whether a drag of [dx], [dy] from its start has become a dismiss drag.
  bool startsDismiss(double dx, double dy) {
    if (dismissDownOnly ? dy < dismissSlop : dy.abs() < dismissSlop) {
      return false;
    }
    return dy.abs() / 2 > dx.abs();
  }

  /// Whether a dismiss drag released at [offset] (positive down) closes a
  /// viewer [height] tall. The reference has no velocity term.
  bool dismisses(double offset, double height) {
    final past = dismissDownOnly ? offset : offset.abs();
    return past > height * dismissFraction;
  }

  /// The background's opacity while the picture is dragged [offset] away in
  /// a viewer [width] wide.
  double backgroundOpacityAt(double offset, double width) {
    final span = width * backgroundFadeWidthFraction;
    if (span <= 0) return 1;
    final faded = 1 - (offset.abs() < span ? offset.abs() : span) / span;
    return faded < backgroundOpacityFloor ? backgroundOpacityFloor : faded;
  }

  /// The zoom a pinch released at [zoom] settles at.
  double settleZoom(double zoom) => zoom < minZoom
      ? minZoom
      : zoom > maxZoom
      ? maxZoom
      : zoom;
}
