import 'dart:math' as math;

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

  /// The iOS reference's chrome where it maps onto this layout: a 44 pt
  /// bar, the "N of M" capsule 24 pt tall 2 pt under it, and a strip of
  /// 15 x 30 thumbnails in a 52 pt panel whose current item grows to 75 pt
  /// with 8 pt around it.
  static const ViewerChromeMetrics ios = ViewerChromeMetrics(
    topBarHeight: 44,
    counterGap: 2,
    counterHeight: 24,
    counterPadding: 10,
    counterRadius: 12,
    captionPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    captionMaxLines: 4,
    stripHeight: 52,
    thumbSize: Size(15, 30),
    thumbTop: 11,
    thumbSpacing: 2,
    thumbRadius: 2,
    currentThumbMaxWidth: 75,
    currentThumbPadding: 8,
    menuItemHeight: 44,
    menuMinWidth: 250,
  );

  /// The desktop reference's chrome where it maps onto this layout: the
  /// header 47 px from the top, a caption box padded 11 x 6, and an 80 px
  /// strip of 56 px thumbnails whose current one grows to 160 px with 12 px
  /// around it. Values the reference names without a number (its toolkit
  /// files are absent) follow the Android ones.
  static const ViewerChromeMetrics desktop = ViewerChromeMetrics(
    topBarHeight: 47,
    counterGap: 10,
    counterHeight: 23,
    counterPadding: 9,
    counterRadius: 12,
    captionPadding: EdgeInsets.symmetric(horizontal: 11, vertical: 6),
    captionMaxLines: 5,
    stripHeight: 80,
    thumbSize: Size(56, 56),
    thumbTop: 12,
    thumbSpacing: 3,
    thumbRadius: 0,
    currentThumbMaxWidth: 160,
    currentThumbPadding: 12,
    menuItemHeight: 32,
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

/// How the picture gets from its origin to its place when the viewer opens,
/// and back when it closes.
enum ViewerOpenStyle {
  /// The whole picture scales and moves from the origin's rectangle and
  /// corners to its fitted place (the Android reference).
  morph,

  /// The picture moves and scales from the origin while the window it shows
  /// through grows from the origin's crop to the whole picture: a crop
  /// reveal (the iOS reference).
  reveal,

  /// No transition: the viewer is there at once, as an overlay over the app
  /// window (the desktop reference).
  appear,
}

/// How far a picture zooms in.
enum ViewerZoomRule {
  /// Up to `ViewerPolicy.maxZoom` times the fitted size.
  fixed,

  /// Up to `ViewerPolicy.maxZoom` times the fitted size, or the zoom that
  /// fills the viewer if that is more.
  fill,

  /// In steps of whole multiples of the picture's own pixels, up to
  /// `ViewerPolicy.maxZoom` of them, with the fitted size as one more step.
  steps,
}

/// Where a playback speed set in the viewer applies.
enum ViewerSpeedMemory {
  /// To the item it was set on, when it opens again.
  perItem,

  /// To every item of the viewer while it is open.
  shared,

  /// To every video, in every viewer, for the session.
  global,
}

/// A double tap that seeks a video: back in a zone on the left, forward in
/// a zone on the right.
@immutable
final class ViewerDoubleTapSeek {
  /// Creates the rule.
  const ViewerDoubleTapSeek({
    required this.step,
    required this.backwardBefore,
    required this.forwardFrom,
    this.minDuration = Duration.zero,
    this.forwardNeedsRoom = false,
  }) : assert(backwardBefore <= forwardFrom, 'The zones do not overlap.');

  /// How far one double tap seeks.
  final Duration step;

  /// A tap left of this fraction of the width seeks back.
  final double backwardBefore;

  /// A tap from this fraction of the width on seeks forward.
  final double forwardFrom;

  /// Shorter videos do not seek on double tap; it zooms instead.
  final Duration minDuration;

  /// Whether a forward seek needs a whole [step] left before the end.
  final bool forwardNeedsRoom;

  /// The signed seek a double tap at [x] in a viewer [width] wide makes on a
  /// video [duration] long at [position]; null when it does not seek.
  Duration? seekAt(
    double x,
    double width, {
    required Duration? duration,
    required Duration position,
  }) {
    if (duration == null || duration <= minDuration || width <= 0) {
      return null;
    }
    final at = x / width;
    if (at < backwardBefore) return -step;
    if (at >= forwardFrom) {
      if (forwardNeedsRoom && duration - position < step) return null;
      return step;
    }
    return null;
  }
}

/// A press held on a playing video that plays it faster until release.
@immutable
final class ViewerHoldSpeed {
  /// Creates the rule: [rate] when given, else the current speed plus
  /// [step], at most [maxRate].
  const ViewerHoldSpeed({
    required this.delay,
    this.rate,
    this.step = 1,
    this.maxRate = 4,
    this.zoneFrom = 0,
  });

  /// How long the press is held before the speed changes.
  final Duration delay;

  /// The speed while held; null for the current speed plus [step].
  final double? rate;

  /// How much faster than the current speed, when [rate] is null.
  final double step;

  /// The fastest a held press plays.
  final double maxRate;

  /// The press counts from this fraction of the width on (the right part of
  /// the screen).
  final double zoneFrom;

  /// The speed while held, from the [current] one.
  double heldRate(double current) => math.min(maxRate, rate ?? current + step);
}

/// The playback speeds the viewer offers and where a choice applies.
@immutable
final class ViewerSpeedRule {
  /// Creates the rule.
  const ViewerSpeedRule({
    required this.min,
    required this.max,
    required this.presets,
    required this.memory,
  });

  /// The slowest speed.
  final double min;

  /// The fastest speed.
  final double max;

  /// The speeds offered as one tap each.
  final List<double> presets;

  /// Where a chosen speed applies.
  final ViewerSpeedMemory memory;

  /// [speed] clamped to the range and rounded to a tenth, as a slider sets
  /// it.
  double settle(double speed) =>
      (speed.clamp(min, max) * 10).roundToDouble() / 10;
}

/// Where the player starts as the viewer opens on a video.
enum ViewerVideoStart {
  /// Where the origin's own loop of the video is: the video goes on.
  origin,

  /// At the beginning.
  beginning,
}

/// What the origin's own loop of a video does as the viewer closes. While
/// the player plays the item the loop stands still on its frame, whichever.
enum ViewerOriginReturn {
  /// It goes to where the player stood and plays on from there, showing the
  /// player's last picture until its own frame there is drawn.
  atPlayer,

  /// It plays on from the frame it stood on.
  whereItPaused,
}

/// The video rules of a viewer policy: controls, seek, speed and loop.
@immutable
final class ViewerVideoRules {
  /// Creates the rules.
  const ViewerVideoRules({
    required this.controlsVisibleOnOpen,
    required this.autoHide,
    required this.speed,
    required this.loops,
    this.doubleTapSeek,
    this.doubleTapFullscreen = false,
    this.hold,
    this.seekPreviewBox,
    this.start = ViewerVideoStart.origin,
    this.originReturn = ViewerOriginReturn.atPlayer,
  });

  /// Where the player starts as the viewer opens on a video.
  final ViewerVideoStart start;

  /// What the origin's own loop of the video does as the viewer closes.
  final ViewerOriginReturn originReturn;

  /// Whether the controls show when a video opens.
  final bool controlsVisibleOnOpen;

  /// How long the controls stay over a playing video before they hide.
  final Duration autoHide;

  /// The speeds offered and where a choice applies.
  final ViewerSpeedRule speed;

  /// Whether a video of [duration] (null while unknown) loops; [hasAudio]
  /// says whether it has sound.
  final bool Function(Duration? duration, {required bool hasAudio}) loops;

  /// The double-tap seek; null when a double tap does not seek.
  final ViewerDoubleTapSeek? doubleTapSeek;

  /// Whether a double tap on a video toggles fullscreen.
  final bool doubleTapFullscreen;

  /// The held-press speed-up; null for none.
  final ViewerHoldSpeed? hold;

  /// The box a seek preview frame is fitted into while the seek bar is
  /// dragged; null for no preview.
  final Size? seekPreviewBox;

  /// Mobile references loop a video up to this long.
  static const Duration shortVideo = Duration(seconds: 30);

  /// Loops a video of at most [shortVideo].
  static bool loopShort(Duration? duration, {required bool hasAudio}) =>
      duration != null && duration <= shortVideo;

  /// Loops a video without sound.
  static bool loopSilent(Duration? duration, {required bool hasAudio}) =>
      !hasAudio;
}

/// A critically damped spring as a curve: it starts fast and settles
/// without overshoot, the shape of the iOS reference's springs with no
/// bounce. [sharpness] is how quickly it settles within the duration.
final class ViewerSpringCurve extends Curve {
  /// Creates the curve.
  const ViewerSpringCurve({this.sharpness = 8});

  /// How quickly the spring settles; higher is sharper.
  final double sharpness;

  @override
  double transformInternal(double t) {
    double spring(double t) =>
        1 - (1 + sharpness * t) * math.exp(-sharpness * t);
    // Normalised so the curve ends exactly at 1.
    return spring(t) / spring(1);
  }
}

/// The gesture, transition and timing rules of the fullscreen viewer, as pure
/// values: no platform reads. One viewer structure runs any policy, so a host
/// may pick the feel of one platform on another.
///
/// Lengths are logical pixels; fractions are of the viewer's size.
@immutable
final class ViewerPolicy {
  /// Creates a policy. Hosts usually take a reference one ([$Android],
  /// [$IOS], [$Desktop]) and adjust it.
  const ViewerPolicy({
    required this.openStyle,
    required this.openDuration,
    required this.openCurve,
    required this.closeDuration,
    required this.backdropScale,
    required this.dismissDrag,
    required this.dismissSlop,
    required this.dismissFraction,
    required this.dismissDownOnly,
    required this.backgroundOpacityFloor,
    required this.backgroundFadeWidthFraction,
    required this.settleDuration,
    required this.settleCurve,
    required this.slideOffDuration,
    required this.plainCloseScale,
    required this.zoomRule,
    required this.doubleTapZoom,
    required this.minZoom,
    required this.maxZoom,
    required this.overPanDamping,
    required this.pageGap,
    required this.controlsVisibleOnOpen,
    required this.controlsDuration,
    required this.controlsHideDuration,
    required this.controlsSlide,
    required this.video,
    required this.chrome,
    this.backgroundFadeDuration,
    this.dismissVelocity,
    this.backgroundFadeDistance,
    this.backgroundClickCloses = false,
    this.doubleTapEdgeInset = 0,
    this.desktopInput = false,
  });

  /// The reference policy of [platform]: [$IOS] on iOS, [$Desktop] on
  /// macOS, Windows and Linux, [$Android] elsewhere.
  static ViewerPolicy forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS => $IOS,
        TargetPlatform.macOS ||
        TargetPlatform.windows ||
        TargetPlatform.linux => $Desktop,
        TargetPlatform.android || TargetPlatform.fuchsia => $Android,
      };

  /// The Android reference: the picture morphs from its origin in 200 ms
  /// while the surface behind grows to 1.1; a drag down past a sixth of
  /// the height closes it, with no velocity term; double tap zooms to 3x
  /// around the tap, a pinch stays within 1x to 3x. Video: controls on
  /// open, hidden after 3 s; double tap seeks 10 s in the outer thirds of
  /// a video over 15 s; speed 0.2x to 3x, remembered per item; videos up to
  /// 30 s loop; a 150 px seek preview.
  static const ViewerPolicy $Android = ViewerPolicy(
    openStyle: ViewerOpenStyle.morph,
    openDuration: Duration(milliseconds: 200),
    // The reference sets no interpolator, so the platform's default
    // accelerate-then-decelerate applies.
    openCurve: Curves.easeInOut,
    closeDuration: Duration(milliseconds: 200),
    backdropScale: 0.1,
    dismissDrag: true,
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
    zoomRule: ViewerZoomRule.fixed,
    doubleTapZoom: 3,
    minZoom: 1,
    maxZoom: 3,
    overPanDamping: 1 / 3,
    pageGap: 15,
    controlsVisibleOnOpen: true,
    controlsDuration: Duration(milliseconds: 200),
    controlsHideDuration: Duration(milliseconds: 200),
    controlsSlide: 24,
    video: ViewerVideoRules(
      controlsVisibleOnOpen: true,
      autoHide: Duration(milliseconds: 3000),
      speed: ViewerSpeedRule(
        min: 0.2,
        max: 3,
        presets: [0.2, 0.5, 1, 1.5, 2],
        memory: ViewerSpeedMemory.perItem,
      ),
      loops: ViewerVideoRules.loopShort,
      doubleTapSeek: ViewerDoubleTapSeek(
        step: Duration(seconds: 10),
        backwardBefore: 1 / 3,
        forwardFrom: 2 / 3,
        minDuration: Duration(seconds: 15),
        forwardNeedsRoom: true,
      ),
      seekPreviewBox: Size.square(150),
    ),
    chrome: ViewerChromeMetrics.android,
  );

  /// The iOS reference: the picture is revealed from its origin's crop on a
  /// 0.25 s spring while the background fades in over 0.15 s; a drag either
  /// way closes it past a twelfth of the height or faster than 1 pt/ms,
  /// with the background gone after 80 pt; zoom reaches 3x or the zoom that
  /// fills the screen, double tap goes all the way. Video: controls hidden
  /// on open and after 4 s; double tap seeks 15 s, back left of 0.3 of the
  /// width; speed 0.2x to 2.5x shared by the items; a held press on the
  /// right 60% plays 1x faster; videos up to 30 s loop; a 160 x 90 seek
  /// preview.
  static const ViewerPolicy $IOS = ViewerPolicy(
    openStyle: ViewerOpenStyle.reveal,
    openDuration: Duration(milliseconds: 250),
    openCurve: ViewerSpringCurve(),
    closeDuration: Duration(milliseconds: 250),
    backgroundFadeDuration: Duration(milliseconds: 150),
    // The surface behind slides as a pushed screen there; it is not scaled.
    backdropScale: 0,
    dismissDrag: true,
    // The pan locks once it moved 2 pt, twice as vertical as horizontal.
    dismissSlop: 2,
    dismissFraction: 1 / 12,
    dismissDownOnly: false,
    // 1 pt/ms.
    dismissVelocity: 1000,
    backgroundOpacityFloor: 0,
    backgroundFadeWidthFraction: 1 / 4,
    backgroundFadeDistance: 80,
    settleDuration: Duration(milliseconds: 250),
    settleCurve: ViewerSpringCurve(),
    // Without an origin the picture leaves over 0.25 s.
    slideOffDuration: Duration(milliseconds: 250),
    plainCloseScale: 1,
    zoomRule: ViewerZoomRule.fill,
    // Null: a double tap zooms to the largest zoom.
    doubleTapZoom: null,
    minZoom: 1,
    maxZoom: 3,
    // The platform scroll view's rubber-band constant.
    overPanDamping: 0.55,
    // 20 pt on each side of a page.
    pageGap: 40,
    controlsVisibleOnOpen: true,
    controlsDuration: Duration(milliseconds: 200),
    controlsHideDuration: Duration(milliseconds: 200),
    controlsSlide: 44,
    // Double tap is off within 44 pt of the edges.
    doubleTapEdgeInset: 44,
    video: ViewerVideoRules(
      controlsVisibleOnOpen: false,
      autoHide: Duration(seconds: 4),
      speed: ViewerSpeedRule(
        min: 0.2,
        max: 2.5,
        presets: [0.5, 1, 1.5, 2],
        memory: ViewerSpeedMemory.shared,
      ),
      loops: ViewerVideoRules.loopShort,
      doubleTapSeek: ViewerDoubleTapSeek(
        step: Duration(seconds: 15),
        backwardBefore: 0.3,
        forwardFrom: 0.3,
      ),
      hold: ViewerHoldSpeed(
        delay: Duration(milliseconds: 300),
        step: 1,
        maxRate: 4,
        zoneFrom: 0.4,
      ),
      seekPreviewBox: Size(160, 90),
    ),
    chrome: ViewerChromeMetrics.ios,
  );

  /// The desktop reference, as an overlay over the app window: no open
  /// transition; a click on the background closes; zoom goes in steps of
  /// the picture's own pixels up to 8x, with the fitted size between;
  /// keyboard and wheel work. Video: controls on open, hidden after 1.1 s
  /// of no movement and faded out over 0.6 s; double click toggles
  /// fullscreen; speed 0.5x to 2.5x for the session; a press held 200 ms
  /// plays at 2x; silent videos loop; no seek preview.
  static const ViewerPolicy $Desktop = ViewerPolicy(
    openStyle: ViewerOpenStyle.appear,
    openDuration: Duration.zero,
    openCurve: Curves.linear,
    closeDuration: Duration.zero,
    backdropScale: 0,
    dismissDrag: false,
    dismissSlop: 30,
    dismissFraction: 1 / 6,
    dismissDownOnly: true,
    backgroundOpacityFloor: 1,
    backgroundFadeWidthFraction: 1 / 4,
    backgroundClickCloses: true,
    // Zoom steps animate linearly over the toolkit's widget fade, whose
    // value the reference does not ship; 200 ms like its other fades.
    settleDuration: Duration(milliseconds: 200),
    settleCurve: Curves.linear,
    slideOffDuration: Duration.zero,
    plainCloseScale: 1,
    zoomRule: ViewerZoomRule.steps,
    // Null with steps: a double click on a photo does nothing.
    doubleTapZoom: null,
    minZoom: 1,
    maxZoom: 8,
    overPanDamping: 0,
    pageGap: 0,
    controlsVisibleOnOpen: true,
    controlsDuration: Duration(milliseconds: 200),
    controlsHideDuration: Duration(milliseconds: 600),
    controlsSlide: 0,
    desktopInput: true,
    video: ViewerVideoRules(
      controlsVisibleOnOpen: true,
      autoHide: Duration(milliseconds: 1100),
      speed: ViewerSpeedRule(
        min: 0.5,
        max: 2.5,
        presets: [0.8, 1, 1.2, 1.5, 1.7, 2, 2.2],
        memory: ViewerSpeedMemory.global,
      ),
      loops: ViewerVideoRules.loopSilent,
      start: ViewerVideoStart.beginning,
      originReturn: ViewerOriginReturn.whereItPaused,
      doubleTapFullscreen: true,
      hold: ViewerHoldSpeed(delay: Duration(milliseconds: 200), rate: 2),
    ),
    chrome: ViewerChromeMetrics.desktop,
  );

  /// How the picture gets from its origin to its place and back.
  final ViewerOpenStyle openStyle;

  /// How long the picture takes from its origin to full size.
  final Duration openDuration;

  /// The curve of the open and close transitions.
  final Curve openCurve;

  /// How long the picture takes back to its origin.
  final Duration closeDuration;

  /// How long the background takes to fade in, when it does not follow the
  /// open transition; null to follow it.
  final Duration? backgroundFadeDuration;

  /// How much larger the surface behind is drawn while the viewer is open:
  /// it grows from 1 to 1 + this as the viewer opens, and shrinks back to 1
  /// as a dismiss drag pulls the picture half the height away
  /// (`MediaViewer.onBackdropScale`). 0 for no scaling.
  final double backdropScale;

  /// Whether a vertical drag dismisses at all.
  final bool dismissDrag;

  /// How far a vertical drag travels before it becomes a dismiss drag; it
  /// also has to be at least twice as vertical as horizontal.
  final double dismissSlop;

  /// The fraction of the height a dismiss drag must pass on release to close
  /// the viewer.
  final double dismissFraction;

  /// Whether only a downward drag dismisses; an upward one springs back.
  final bool dismissDownOnly;

  /// A release faster than this, in pixels per second along the drag's
  /// direction, closes whatever the distance; null for no velocity term.
  final double? dismissVelocity;

  /// The background's opacity never drops below this during a dismiss drag.
  final double backgroundOpacityFloor;

  /// The drag distance, as a fraction of the width, over which the
  /// background fades from opaque to [backgroundOpacityFloor].
  final double backgroundFadeWidthFraction;

  /// The drag distance over which the background fades, when it is a fixed
  /// length rather than [backgroundFadeWidthFraction].
  final double? backgroundFadeDistance;

  /// Whether a click on the background around the picture closes the
  /// viewer.
  final bool backgroundClickCloses;

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

  /// How far a picture zooms in.
  final ViewerZoomRule zoomRule;

  /// The zoom a double tap goes to, around the tap point; null for the
  /// largest zoom, or, with [ViewerZoomRule.steps], for none.
  final double? doubleTapZoom;

  /// The smallest zoom a pinch settles at.
  final double minZoom;

  /// The largest zoom: times the fitted size, or times the picture's own
  /// pixels with [ViewerZoomRule.steps].
  final double maxZoom;

  /// How much of a pan past the picture's edge is followed.
  final double overPanDamping;

  /// A double tap this close to an edge does nothing.
  final double doubleTapEdgeInset;

  /// The gap between two pages.
  final double pageGap;

  /// Whether the bars show when the viewer opens on a photo.
  final bool controlsVisibleOnOpen;

  /// How long the bars take to show.
  final Duration controlsDuration;

  /// How long the bars take to hide.
  final Duration controlsHideDuration;

  /// How far the bars slide as they hide: the top bar up, the bottom down.
  final double controlsSlide;

  /// Whether the keyboard and the mouse wheel drive the viewer: Esc closes,
  /// arrows and the wheel page, Ctrl with + - 0 or the wheel zooms, and the
  /// playback keys work.
  final bool desktopInput;

  /// The video rules.
  final ViewerVideoRules video;

  /// The layout of the bars, counter, caption and strip.
  final ViewerChromeMetrics chrome;

  /// Whether a drag of [dx], [dy] from its start has become a dismiss drag.
  bool startsDismiss(double dx, double dy) {
    if (!dismissDrag) return false;
    if (dismissDownOnly ? dy < dismissSlop : dy.abs() < dismissSlop) {
      return false;
    }
    return dy.abs() / 2 > dx.abs();
  }

  /// Whether a dismiss drag released at [offset] (positive down) with
  /// [velocity] (pixels per second, positive down) closes a viewer [height]
  /// tall.
  bool dismisses(double offset, double height, {double velocity = 0}) {
    final past = dismissDownOnly ? offset : offset.abs();
    if (past > height * dismissFraction) return true;
    final fast = dismissVelocity;
    if (fast == null) return false;
    final speed = dismissDownOnly ? velocity : velocity.abs();
    return speed > fast;
  }

  /// The background's opacity while the picture is dragged [offset] away in
  /// a viewer [width] wide.
  double backgroundOpacityAt(double offset, double width) {
    final span = backgroundFadeDistance ?? width * backgroundFadeWidthFraction;
    if (span <= 0) return 1;
    final faded = 1 - math.min(offset.abs(), span) / span;
    return math.max(faded, backgroundOpacityFloor);
  }

  /// The largest zoom of a picture drawn [fitted] in a viewer of [viewport],
  /// whose own pixels are [pixels] (null when unknown).
  double maxZoomFor(Size fitted, Size viewport, {Size? pixels}) {
    if (fitted.isEmpty) return maxZoom;
    return switch (zoomRule) {
      ViewerZoomRule.fixed => maxZoom,
      ViewerZoomRule.fill => math.max(
        maxZoom,
        math.max(
          viewport.width / fitted.width,
          viewport.height / fitted.height,
        ),
      ),
      ViewerZoomRule.steps => math.max(
        minZoom,
        maxZoom * _pixelScale(fitted, pixels),
      ),
    };
  }

  /// The zoom a double tap on a photo goes to, or null when it does not
  /// zoom.
  double? doubleTapZoomFor(Size fitted, Size viewport, {Size? pixels}) =>
      switch ((doubleTapZoom, zoomRule)) {
        (final zoom?, _) => zoom,
        (null, ViewerZoomRule.steps) => null,
        (null, _) => maxZoomFor(fitted, viewport, pixels: pixels),
      };

  /// The next zoom step from [zoom], in or out, for [ViewerZoomRule.steps]:
  /// whole multiples of the picture's own pixels, with the fitted size (1)
  /// between them. Null when there is none further that way.
  double? stepZoom(
    double zoom,
    Size fitted,
    Size viewport, {
    required bool zoomIn,
    Size? pixels,
  }) {
    final scale = _pixelScale(fitted, pixels);
    final max = maxZoomFor(fitted, viewport, pixels: pixels);
    final steps = <double>{
      minZoom,
      for (var level = 1; level <= maxZoom; level++)
        if (level * scale > minZoom && level * scale <= max) level * scale,
    }.toList()..sort();
    // A hair of tolerance so a zoom that sits on a step moves past it.
    const tolerance = 1e-6;
    if (zoomIn) {
      for (final step in steps) {
        if (step > zoom + tolerance) return step;
      }
    } else {
      for (final step in steps.reversed) {
        if (step < zoom - tolerance) return step;
      }
    }
    return null;
  }

  // How many fitted-size units one of the picture's own pixels is.
  static double _pixelScale(Size fitted, Size? pixels) {
    if (pixels == null || pixels.isEmpty || fitted.isEmpty) return 1;
    return pixels.width / fitted.width;
  }

  /// The zoom a pinch released at [zoom] settles at, below [max] (the
  /// policy's [maxZoom] when null).
  double settleZoom(double zoom, {double? max}) =>
      zoom.clamp(minZoom, max ?? maxZoom).toDouble();
}
