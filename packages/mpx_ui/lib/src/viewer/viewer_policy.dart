import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/src/gallery/gallery_page_transition.dart';
import 'package:mpx_ui/src/gallery/gallery_pager_physics.dart';
import 'package:mpx_ui/src/gallery/gallery_tap_recognizer.dart';

/// The layout of the viewer's chrome on one platform: bars, the "N of M"
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

  /// The Android chrome: a 56 px action bar, the counter pill 10
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

  /// The iOS chrome where it maps onto this layout: a 44 pt
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

  /// The desktop chrome where it maps onto this layout: the
  /// header 47 px from the top, a caption box padded 11 x 6, and an 80 px
  /// strip of 56 px thumbnails whose current one grows to 160 px with 12 px
  /// around it. Values given without a number (the toolkit
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

  /// These metrics with the given fields changed.
  ///
  /// A field passed as null keeps its value: a nullable field cannot be
  /// cleared here, only set.
  ViewerChromeMetrics copyWith({
    double? topBarHeight,
    double? counterGap,
    double? counterHeight,
    double? counterPadding,
    double? counterRadius,
    EdgeInsets? captionPadding,
    int? captionMaxLines,
    double? stripHeight,
    Size? thumbSize,
    double? thumbTop,
    double? thumbSpacing,
    double? thumbRadius,
    double? currentThumbMaxWidth,
    double? currentThumbPadding,
    double? menuItemHeight,
    double? menuMinWidth,
  }) => ViewerChromeMetrics(
    topBarHeight: topBarHeight ?? this.topBarHeight,
    counterGap: counterGap ?? this.counterGap,
    counterHeight: counterHeight ?? this.counterHeight,
    counterPadding: counterPadding ?? this.counterPadding,
    counterRadius: counterRadius ?? this.counterRadius,
    captionPadding: captionPadding ?? this.captionPadding,
    captionMaxLines: captionMaxLines ?? this.captionMaxLines,
    stripHeight: stripHeight ?? this.stripHeight,
    thumbSize: thumbSize ?? this.thumbSize,
    thumbTop: thumbTop ?? this.thumbTop,
    thumbSpacing: thumbSpacing ?? this.thumbSpacing,
    thumbRadius: thumbRadius ?? this.thumbRadius,
    currentThumbMaxWidth: currentThumbMaxWidth ?? this.currentThumbMaxWidth,
    currentThumbPadding: currentThumbPadding ?? this.currentThumbPadding,
    menuItemHeight: menuItemHeight ?? this.menuItemHeight,
    menuMinWidth: menuMinWidth ?? this.menuMinWidth,
  );
}

/// How the picture gets from its origin to its place when the viewer opens,
/// and back when it closes.
enum ViewerOpenStyle {
  /// The whole picture scales and moves from the origin's rectangle and
  /// corners to its fitted place (the Android policy).
  morph,

  /// The picture moves and scales from the origin while the window it shows
  /// through grows from the origin's crop to the whole picture: a crop
  /// reveal (the iOS policy).
  reveal,

  /// No transition: the viewer is there at once, as an overlay over the app
  /// window (the desktop policy).
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

/// Where a pinch zooms around.
enum ViewerZoomFocal {
  /// The point between the fingers when the pinch started; the fingers
  /// moving together do not pan (the Android policy).
  fixed,

  /// The point between the fingers as they move: the picture stays under
  /// them and two fingers pan it (the iOS policy).
  follows,
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

  /// This rule with the given fields changed.
  ///
  /// A field passed as null keeps its value: a nullable field cannot be
  /// cleared here, only set.
  ViewerDoubleTapSeek copyWith({
    Duration? step,
    double? backwardBefore,
    double? forwardFrom,
    Duration? minDuration,
    bool? forwardNeedsRoom,
  }) => ViewerDoubleTapSeek(
    step: step ?? this.step,
    backwardBefore: backwardBefore ?? this.backwardBefore,
    forwardFrom: forwardFrom ?? this.forwardFrom,
    minDuration: minDuration ?? this.minDuration,
    forwardNeedsRoom: forwardNeedsRoom ?? this.forwardNeedsRoom,
  );
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
    this.minDuration = Duration.zero,
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

  /// Shorter videos do not speed up on a held press.
  final Duration minDuration;

  /// The speed while held, from the [current] one.
  double heldRate(double current) => math.min(maxRate, rate ?? current + step);

  /// This rule with the given fields changed.
  ///
  /// A field passed as null keeps its value: a nullable field cannot be
  /// cleared here, only set.
  ViewerHoldSpeed copyWith({
    Duration? delay,
    double? rate,
    double? step,
    double? maxRate,
    double? zoneFrom,
    Duration? minDuration,
  }) => ViewerHoldSpeed(
    delay: delay ?? this.delay,
    rate: rate ?? this.rate,
    step: step ?? this.step,
    maxRate: maxRate ?? this.maxRate,
    zoneFrom: zoneFrom ?? this.zoneFrom,
    minDuration: minDuration ?? this.minDuration,
  );
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
    this.cycle = const [1, 1.5, 2],
  });

  /// The slowest speed.
  final double min;

  /// The fastest speed.
  final double max;

  /// The speeds the settings list, one tap each.
  final List<double> presets;

  /// The speeds the button beside the seek bar goes through, one tap each,
  /// back to the first after the last; 1x, 1.5x, 2x by default. A speed
  /// chosen from the settings that is not among them goes back to the first.
  final List<double> cycle;

  /// Where a chosen speed applies.
  final ViewerSpeedMemory memory;

  /// [speed] clamped to the range and rounded to a tenth, as a slider sets
  /// it.
  double settle(double speed) =>
      (speed.clamp(min, max) * 10).roundToDouble() / 10;

  /// This rule with the given fields changed.
  ///
  /// A field passed as null keeps its value: a nullable field cannot be
  /// cleared here, only set.
  ViewerSpeedRule copyWith({
    double? min,
    double? max,
    List<double>? presets,
    ViewerSpeedMemory? memory,
    List<double>? cycle,
  }) => ViewerSpeedRule(
    min: min ?? this.min,
    max: max ?? this.max,
    presets: presets ?? this.presets,
    memory: memory ?? this.memory,
    cycle: cycle ?? this.cycle,
  );
}

/// Where the player starts as the viewer opens on a video with sound, when
/// the host gives no start of its own (`MediaViewer.videoStartOf`).
enum ViewerVideoStart {
  /// At the beginning.
  beginning,

  /// Where the origin's own loop of the video is: the video goes on from
  /// the frame the origin showed.
  origin,
}

/// What the origin's own loop of a video with sound does as the viewer
/// closes. While the player plays the item the loop stands still on its
/// frame, whichever this is.
enum ViewerOriginReturn {
  /// It goes to where the player stood and plays on from there, showing the
  /// player's last picture until its own frame there is drawn.
  atPlayer,

  /// It plays again from its first frame.
  restart,

  /// It plays on from the frame it stood on.
  whereItPaused,
}

/// What the viewer shows when a video it shows cannot be played.
enum ViewerVideoFailure {
  /// Nothing: the page keeps its picture and its play button, which tries
  /// again. A picker's: its viewer offers no other app to open
  /// the file in, so its error says nothing.
  silent,

  /// An alert offering to open the file in another app (Open, Cancel), where
  /// the host can (`MediaViewer.onOpenElsewhere`); a card where it cannot.
  /// A chat's.
  alert,

  /// A card over the picture saying the video could not be played, with
  /// Retry.
  card,
}

/// What an animation (an animated image, a vector animation, a silent loop)
/// does as the viewer opens on it from an origin that plays it.
enum ViewerLoopOpen {
  /// The page draws the origin's own playback and it goes on: one playback
  /// in two places, the same frame in both.
  continues,

  /// The page draws the origin's own playback, which starts again from its
  /// first frame as the viewer opens and as it closes.
  restart,

  /// The page plays a playback of its own, from its first frame; the
  /// origin's goes on by itself.
  own,
}

/// How a photo page shows its download.
enum ViewerPhotoProgress {
  /// A spinner turning without progress, no icon.
  spinner,

  /// An arc of the bytes received.
  arc,
}

/// How a viewer page shows its content loading: the status control of the
/// page shown, the buffering spinner of its player, and the player's fade
/// in over the page's picture.
@immutable
final class ViewerLoadingRules {
  /// Creates the rules.
  const ViewerLoadingRules({
    required this.status,
    required this.photoProgress,
    required this.bufferingFade,
    required this.playerFadeIn,
    required this.playerFadeInHandedOver,
    this.photoProgressDelay = Duration.zero,
    this.hideStatusUntilCentral = true,
    this.bufferingDelay = const Duration(milliseconds: 500),
  });

  /// The look and motion of the page's status control and spinner.
  final MediaStatusStyle status;

  /// How a photo that downloads shows it.
  final ViewerPhotoProgress photoProgress;

  /// How long a photo has loaded before its progress shows: a photo that
  /// arrives sooner never shows one.
  final Duration photoProgressDelay;

  /// Whether only the page shown has a status control; its neighbours show
  /// their picture alone.
  final bool hideStatusUntilCentral;

  /// How long a player buffers (or prepares without a first frame) before
  /// the spinner shows: a shorter spell shows none.
  final Duration bufferingDelay;

  /// How long the spinner takes to fade in once it shows. It goes at once
  /// when playback resumes.
  final Duration bufferingFade;

  /// How long the player takes to fade in over the page's picture.
  final Duration playerFadeIn;

  /// [playerFadeIn] for a player that had its first frame when the page
  /// took it (handed over from another surface, or kept warm).
  final Duration playerFadeInHandedOver;

  /// The Android defaults: a 64 dp control, a spinner for photos, the
  /// spinner after 500 ms fading in over 200 ms, the player fading in over
  /// 200 ms (100 ms handed over).
  static const ViewerLoadingRules $Android = ViewerLoadingRules(
    status: MediaStatusStyle(
      diameter: 64,
      compactDiameter: 24,
      roundVideoDiameter: 44,
      compactOffset: Offset(8, 8),
      discColor: Color(0x66000000),
      arcColor: Color(0xFFFFFFFF),
      iconColor: Color(0xFFFFFFFF),
      arcStroke: 3,
      minArcStroke: 2,
      arcInset: 4,
      minSweepDegrees: 4,
      spinPeriod: Duration(milliseconds: 3000),
      spinStartDegrees: 112,
      smoothing: MediaArcSmoothing.eased(
        duration: Duration(milliseconds: 300),
        // A decelerate interpolator of factor 1.5: 1 - (1 - t)^3.
        curve: Curves.easeOutCubic,
        forwardOnly: true,
      ),
      spinner: MediaSpinnerStyle(
        turn: Duration(milliseconds: 2000),
        minSweepDegrees: 4,
        maxSweepDegrees: 270,
        sweepPeriod: Duration(milliseconds: 1000),
        motion: MediaSpinnerMotion.chase,
      ),
      appearance: MediaStatusAppearance.scale,
      appearDuration: Duration(milliseconds: 200),
      disappearDuration: Duration(milliseconds: 200),
      // The page's control crossfades its icons.
      iconMorph: MediaIconMorph.scaleFade,
      morphDuration: Duration(milliseconds: 200),
      playPauseDuration: Duration(milliseconds: 200),
      downloadCancelDuration: Duration(milliseconds: 200),
      iconSize: 0.3,
      iconStroke: 3,
    ),
    // The photo's radial is the empty disc with an arc of the bytes, its progress
    // following the file's while it loads.
    photoProgress: ViewerPhotoProgress.arc,
    bufferingFade: Duration(milliseconds: 200),
    playerFadeIn: Duration(milliseconds: 200),
    playerFadeInHandedOver: Duration(milliseconds: 100),
  );

  /// The iOS defaults: a 50 pt control on black at 0.5, an arc for
  /// photos, the spinner after 500 ms fading in over 200 ms, the player
  /// fading in over 100 ms.
  static const ViewerLoadingRules $IOS = ViewerLoadingRules(
    status: MediaStatusStyle(
      diameter: 50,
      compactDiameter: 32,
      roundVideoDiameter: 54,
      compactOffset: Offset(6, 6),
      discColor: Color.from(alpha: 0.5, red: 0, green: 0, blue: 0),
      arcColor: Color(0xFFFFFFFF),
      iconColor: Color(0xFFFFFFFF),
      arcStroke: 2.25,
      minArcStroke: 1.6,
      arcInset: 2.5,
      minSweepDegrees: 0.027 * 360,
      spinPeriod: Duration(milliseconds: 1500),
      spinStartDegrees: -90,
      smoothing: MediaArcSmoothing.eased(
        duration: Duration(milliseconds: 200),
        extraDuration: Duration(milliseconds: 450),
        extraAbove: 0.25,
      ),
      spinner: MediaSpinnerStyle(
        turn: Duration(milliseconds: 1250),
        minSweepDegrees: 90,
        maxSweepDegrees: 90,
        sweepPeriod: Duration(milliseconds: 2500),
      ),
      appearance: MediaStatusAppearance.discScaleFade,
      appearDuration: Duration(milliseconds: 200),
      disappearDuration: Duration(milliseconds: 200),
      iconMorph: MediaIconMorph.scaleFade,
      morphDuration: Duration(milliseconds: 200),
      playPauseDuration: Duration(milliseconds: 200),
      downloadCancelDuration: Duration(milliseconds: 200),
      iconSize: 0.28,
      iconStroke: 2,
    ),
    photoProgress: ViewerPhotoProgress.arc,
    bufferingFade: Duration(milliseconds: 200),
    playerFadeIn: Duration(milliseconds: 100),
    playerFadeInHandedOver: Duration(milliseconds: 100),
  );

  /// The desktop defaults: a 50 px control on `#00000056`, an arc for
  /// photos once one has loaded for 350 ms, the spinner after 500 ms fading
  /// in over 500 ms, the player shown at once.
  static const ViewerLoadingRules $Desktop = ViewerLoadingRules(
    status: MediaStatusStyle(
      diameter: 50,
      compactDiameter: 44,
      roundVideoDiameter: 44,
      compactOffset: Offset(4, 4),
      discColor: Color(0x56000000),
      arcColor: Color(0xFFFFFFFF),
      iconColor: Color(0xFFFFFFFF),
      arcStroke: 3,
      minArcStroke: 3,
      arcInset: 3,
      minSweepDegrees: 1,
      spinPeriod: Duration(milliseconds: 3000),
      spinStartDegrees: -90,
      smoothing: MediaArcSmoothing.asymptotic(Duration(milliseconds: 350)),
      spinner: MediaSpinnerStyle(
        turn: Duration(milliseconds: 1000),
        minSweepDegrees: 0.0625 * 360,
        maxSweepDegrees: 0.75 * 360,
        sweepPeriod: Duration(milliseconds: 3000),
      ),
      appearance: MediaStatusAppearance.fade,
      appearDuration: Duration(milliseconds: 350),
      disappearDuration: Duration(milliseconds: 350),
      iconMorph: MediaIconMorph.scaleFade,
      morphDuration: Duration(milliseconds: 200),
      playPauseDuration: Duration(milliseconds: 200),
      downloadCancelDuration: Duration(milliseconds: 200),
      iconSize: 0.3,
      iconStroke: 2,
    ),
    photoProgress: ViewerPhotoProgress.arc,
    photoProgressDelay: Duration(milliseconds: 350),
    bufferingFade: Duration(milliseconds: 500),
    playerFadeIn: Duration.zero,
    playerFadeInHandedOver: Duration.zero,
  );

  /// How long a player takes to fade in; [handedOver] when it had its first
  /// frame as the page took it.
  Duration playerFadeInFor({required bool handedOver}) =>
      handedOver ? playerFadeInHandedOver : playerFadeIn;

  /// These rules with the given fields changed.
  ViewerLoadingRules copyWith({
    MediaStatusStyle? status,
    ViewerPhotoProgress? photoProgress,
    Duration? photoProgressDelay,
    bool? hideStatusUntilCentral,
    Duration? bufferingDelay,
    Duration? bufferingFade,
    Duration? playerFadeIn,
    Duration? playerFadeInHandedOver,
  }) => ViewerLoadingRules(
    status: status ?? this.status,
    photoProgress: photoProgress ?? this.photoProgress,
    photoProgressDelay: photoProgressDelay ?? this.photoProgressDelay,
    hideStatusUntilCentral:
        hideStatusUntilCentral ?? this.hideStatusUntilCentral,
    bufferingDelay: bufferingDelay ?? this.bufferingDelay,
    bufferingFade: bufferingFade ?? this.bufferingFade,
    playerFadeIn: playerFadeIn ?? this.playerFadeIn,
    playerFadeInHandedOver:
        playerFadeInHandedOver ?? this.playerFadeInHandedOver,
  );
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
    this.autoHides = true,
    this.centreWhilePlaying = true,
    this.restarts = false,
    this.autoplay = true,
    this.failure = ViewerVideoFailure.alert,
    this.doubleTapSeek,
    this.doubleTapFullscreen = false,
    this.doubleTapZooms = true,
    this.clickPlays = false,
    this.hold,
    this.seekPreviewBox,
    this.start = ViewerVideoStart.beginning,
    this.originReturn = ViewerOriginReturn.atPlayer,
    this.loopOpen = ViewerLoopOpen.continues,
    this.prepareNeighbours = true,
  });

  /// Where the player starts as the viewer opens on a video with sound.
  final ViewerVideoStart start;

  /// What the origin's own loop of a video with sound does as the viewer
  /// closes.
  final ViewerOriginReturn originReturn;

  /// What an animation does as the viewer opens on it.
  final ViewerLoopOpen loopOpen;

  /// Whether the video items next to the one shown are prepared, paused,
  /// while the viewer is open: up to the pool's prepared budget, the next
  /// first, once the item shown has its first frame (or is no video). Paging
  /// to one then shows its first frame at once.
  final bool prepareNeighbours;

  /// Whether the controls show when a video opens.
  final bool controlsVisibleOnOpen;

  /// How long the controls stay over a playing video before they hide.
  final Duration autoHide;

  /// Whether the controls hide by themselves over a playing video
  /// ([autoHide]); a picker-mode viewer's never do, they go only on a tap
  /// or with the close.
  final bool autoHides;

  /// Whether the centre play / pause button shows over a playing video (as
  /// a pause); without it the centre is empty while the video plays and
  /// shows play when it pauses, as a picker-mode viewer draws it.
  final bool centreWhilePlaying;

  /// Whether a video plays from its beginning each time the viewer comes
  /// to it (paged back to, or opened again), wherever its player was left;
  /// otherwise a player still warm goes on from where it was. A picker's
  /// viewer restarts: its videos keep no position.
  final bool restarts;

  /// Whether a video starts playing by itself when its page shows; off, it
  /// waits paused at its start, the play button shown, as a picker-mode
  /// viewer's do.
  final bool autoplay;

  /// What a video that cannot be played shows.
  final ViewerVideoFailure failure;

  /// The speeds offered and where a choice applies.
  final ViewerSpeedRule speed;

  /// Whether a video of [duration] (null while unknown) loops; [hasAudio]
  /// says whether it has sound.
  final bool Function(Duration? duration, {required bool hasAudio}) loops;

  /// The double-tap seek; null when a double tap does not seek.
  final ViewerDoubleTapSeek? doubleTapSeek;

  /// Whether a double tap on a video toggles fullscreen.
  final bool doubleTapFullscreen;

  /// Whether a double tap the seek and the fullscreen rules leave zooms the
  /// video's picture like a photo's.
  final bool doubleTapZooms;

  /// Whether a click on the video plays or pauses it, rather than showing
  /// or hiding the controls.
  final bool clickPlays;

  /// The held-press speed-up; null for none.
  final ViewerHoldSpeed? hold;

  /// The box a seek preview frame is fitted into while the seek bar is
  /// dragged; null for no preview.
  final Size? seekPreviewBox;

  /// Mobile viewers loop a video up to this long.
  static const Duration shortVideo = Duration(seconds: 30);

  /// Loops a video of at most [shortVideo].
  static bool loopShort(Duration? duration, {required bool hasAudio}) =>
      duration != null && duration <= shortVideo;

  /// Loops a video without sound.
  static bool loopSilent(Duration? duration, {required bool hasAudio}) =>
      !hasAudio;

  /// Loops no video: each stops at its end, back at its start, paused (a
  /// picker-mode viewer's).
  static bool loopNever(Duration? duration, {required bool hasAudio}) => false;

  /// These rules with the given fields changed.
  ///
  /// A field passed as null keeps its value: a nullable field cannot be
  /// cleared here, only set.
  ViewerVideoRules copyWith({
    ViewerVideoStart? start,
    ViewerOriginReturn? originReturn,
    ViewerLoopOpen? loopOpen,
    bool? controlsVisibleOnOpen,
    Duration? autoHide,
    bool? autoHides,
    bool? centreWhilePlaying,
    bool? restarts,
    bool? autoplay,
    ViewerVideoFailure? failure,
    ViewerSpeedRule? speed,
    bool Function(Duration? duration, {required bool hasAudio})? loops,
    ViewerDoubleTapSeek? doubleTapSeek,
    bool? doubleTapFullscreen,
    bool? doubleTapZooms,
    bool? clickPlays,
    ViewerHoldSpeed? hold,
    Size? seekPreviewBox,
    bool? prepareNeighbours,
  }) => ViewerVideoRules(
    start: start ?? this.start,
    originReturn: originReturn ?? this.originReturn,
    loopOpen: loopOpen ?? this.loopOpen,
    controlsVisibleOnOpen: controlsVisibleOnOpen ?? this.controlsVisibleOnOpen,
    autoHide: autoHide ?? this.autoHide,
    autoHides: autoHides ?? this.autoHides,
    centreWhilePlaying: centreWhilePlaying ?? this.centreWhilePlaying,
    restarts: restarts ?? this.restarts,
    autoplay: autoplay ?? this.autoplay,
    failure: failure ?? this.failure,
    speed: speed ?? this.speed,
    loops: loops ?? this.loops,
    doubleTapSeek: doubleTapSeek ?? this.doubleTapSeek,
    doubleTapFullscreen: doubleTapFullscreen ?? this.doubleTapFullscreen,
    doubleTapZooms: doubleTapZooms ?? this.doubleTapZooms,
    clickPlays: clickPlays ?? this.clickPlays,
    hold: hold ?? this.hold,
    seekPreviewBox: seekPreviewBox ?? this.seekPreviewBox,
    prepareNeighbours: prepareNeighbours ?? this.prepareNeighbours,
  );
}

/// A critically damped spring as a curve: it starts fast and settles
/// without overshoot, the shape of the iOS springs with no
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
  /// Creates a policy. Hosts usually take a platform one ([$Android],
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
    required this.pager,
    required this.transition,
    required this.taps,
    this.dismissRatio = 2,
    this.zoomFocal = ViewerZoomFocal.fixed,
    this.zoomFling = true,
    this.zoomBounce = false,
    this.loading = ViewerLoadingRules.$Android,
    this.backgroundFadeDuration,
    this.dismissVelocity,
    this.backgroundFadeDistance,
    this.backgroundClickCloses = false,
    this.controlsReturnOnSpringBack = false,
    this.pictureClickCloses = false,
    this.doubleTapEdgeInset = 0,
    this.desktopInput = false,
    this.plainCloseSlides = false,
  });

  /// The default policy of [platform]: [$IOS] on iOS, [$Desktop] on
  /// macOS, Windows and Linux, [$Android] elsewhere.
  static ViewerPolicy forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS => $IOS,
        TargetPlatform.macOS ||
        TargetPlatform.windows ||
        TargetPlatform.linux => $Desktop,
        TargetPlatform.android || TargetPlatform.fuchsia => $Android,
      };

  /// The Android defaults: the picture morphs from its origin in 200 ms
  /// while the surface behind grows to 1.1; a drag either way past a sixth
  /// of the height closes it, with no velocity term; double tap zooms to 3x
  /// around the tap, a pinch zooms around where it started and settles
  /// within 1x to 3x on release. Pages lie stacked: the next one under the
  /// picture, the previous one sliding over it. Video: controls on open,
  /// hidden after 3 s; double tap seeks 10 s in the outer thirds of a video
  /// over 15 s; a press held 300 ms on the right two thirds of a video of
  /// 8 s or more plays it at 2x; speed 0.2x to 3x, remembered per item;
  /// videos up to 30 s loop; a 150 px seek preview.
  static const ViewerPolicy $Android = ViewerPolicy(
    openStyle: ViewerOpenStyle.morph,
    openDuration: Duration(milliseconds: 200),
    // No interpolator is set, so the platform's default
    // accelerate-then-decelerate applies.
    openCurve: Curves.easeInOut,
    closeDuration: Duration(milliseconds: 200),
    backdropScale: 0.1,
    dismissDrag: true,
    dismissSlop: 30,
    dismissFraction: 1 / 6,
    dismissDownOnly: false,
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
        presets: [0.25, 0.5, 1, 1.5, 2],
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
      hold: ViewerHoldSpeed(
        delay: Duration(milliseconds: 300),
        rate: 2,
        zoneFrom: 1 / 3,
        minDuration: Duration(seconds: 8),
      ),
      seekPreviewBox: Size.square(150),
    ),
    chrome: ViewerChromeMetrics.android,
    pager: GalleryPagerPhysics.$Android,
    transition: GalleryPageTransition.stack(),
    taps: GalleryTapRules.$Android,
  );

  /// The iOS defaults: the picture is revealed from its origin's crop on a
  /// 0.25 s spring while the background fades in over 0.15 s; a drag either
  /// way closes it past a quarter of the height or faster than 1 pt/ms,
  /// with the background gone after 80 pt; zoom reaches 3x or the zoom that
  /// fills the screen, double tap goes all the way, a pinch follows the
  /// fingers and bounces past its limits. Pages lie side by side 40 pt
  /// apart, their pictures lagging a little. Video: controls hidden
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
    // The platform's pan slop, the vertical axis winning.
    dismissSlop: 10,
    dismissRatio: 1,
    // A twelfth of a scroll content three heights tall.
    dismissFraction: 1 / 4,
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
      originReturn: ViewerOriginReturn.restart,
      loopOpen: ViewerLoopOpen.restart,
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
      doubleTapZooms: false,
      seekPreviewBox: Size(160, 90),
    ),
    chrome: ViewerChromeMetrics.ios,
    loading: ViewerLoadingRules.$IOS,
    pager: GalleryPagerPhysics.$IOS,
    transition: GalleryPageTransition.strip(parallax: 0.16),
    taps: GalleryTapRules.$IOS,
    zoomFocal: ViewerZoomFocal.follows,
    zoomBounce: true,
  );

  /// The desktop defaults, as an overlay over the app window: no open
  /// transition; items switch at once (keys, the wheel, a press on a side
  /// strip); a click anywhere off the controls closes; zoom goes in steps of
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
    pictureClickCloses: true,
    // Zoom steps animate linearly over the toolkit's widget fade, whose
    // value is not shipped; 200 ms like the other fades.
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

      doubleTapFullscreen: true,
      doubleTapZooms: false,
      clickPlays: true,
      hold: ViewerHoldSpeed(delay: Duration(milliseconds: 200), rate: 2),
    ),
    chrome: ViewerChromeMetrics.desktop,
    loading: ViewerLoadingRules.$Desktop,
    pager: GalleryPagerPhysics.$Desktop,
    transition: GalleryPageTransition.instant(),
    taps: GalleryTapRules.$Desktop,
    // A mouse drag pans an oversized picture, clamped, with no inertia.
    zoomFling: false,
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
  /// also has to be more than [dismissRatio] times as vertical as
  /// horizontal. Tested before the page drag.
  final double dismissSlop;

  /// How many times as vertical as horizontal a drag is to dismiss.
  final double dismissRatio;

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

  /// Whether the controls, hidden as a dismiss drag starts, come back when
  /// the drag springs back without closing (a picker-mode viewer, whose tap
  /// does not toggle them); otherwise they stay hidden until a tap.
  final bool controlsReturnOnSpringBack;

  /// Whether a click on a photo or an animation closes the viewer too,
  /// rather than showing or hiding the chrome.
  final bool pictureClickCloses;

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

  /// Whether a close without an origin and without a drag slides the
  /// picture off downwards by the height, fading (over [slideOffDuration]),
  /// instead of shrinking to [plainCloseScale]: a viewer over a camera,
  /// whose pictures have no place to return to.
  final bool plainCloseSlides;

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

  /// Where a pinch zooms around.
  final ViewerZoomFocal zoomFocal;

  /// Whether a pan of a zoomed picture flings on within its bounds.
  final bool zoomFling;

  /// Whether a pinch past the zoom limits follows the fingers, damped, and
  /// bounces back; else it follows freely and snaps into range on release.
  final bool zoomBounce;

  /// The paging rules: when a drag pages, release, settle, ends, side taps.
  final GalleryPagerPhysics pager;

  /// How pages are drawn while the pager moves between them.
  final GalleryPageTransition transition;

  /// The tap timings: the double-tap wait and the slops.
  final GalleryTapRules taps;

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

  /// How pages show their content loading: the status control, the
  /// buffering spinner and the player's fade in.
  final ViewerLoadingRules loading;

  /// When a drag becomes a dismiss drag, along the vertical axis; null when
  /// no drag dismisses.
  GalleryClaim? get dismissClaim => dismissDrag
      ? GalleryClaim.dominant(slop: dismissSlop, ratio: dismissRatio)
      : null;

  /// Whether a drag of [dx], [dy] from its start has become a dismiss drag.
  bool startsDismiss(double dx, double dy) {
    final claim = dismissClaim;
    if (claim == null || (dismissDownOnly && dy < 0)) return false;
    return claim.claims(dy, dx);
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

  /// This policy with the given fields changed, so a host adjusts a
  /// platform's default policy in one place and keeps the rest of it.
  ///
  /// A field passed as null keeps its value: a nullable field cannot be
  /// cleared here, only set.
  ViewerPolicy copyWith({
    ViewerOpenStyle? openStyle,
    Duration? openDuration,
    Curve? openCurve,
    Duration? closeDuration,
    Duration? backgroundFadeDuration,
    double? backdropScale,
    bool? dismissDrag,
    double? dismissSlop,
    double? dismissRatio,
    double? dismissFraction,
    bool? dismissDownOnly,
    double? dismissVelocity,
    double? backgroundOpacityFloor,
    double? backgroundFadeWidthFraction,
    double? backgroundFadeDistance,
    bool? backgroundClickCloses,
    bool? controlsReturnOnSpringBack,
    bool? pictureClickCloses,
    Duration? settleDuration,
    Curve? settleCurve,
    Duration? slideOffDuration,
    double? plainCloseScale,
    bool? plainCloseSlides,
    ViewerZoomRule? zoomRule,
    double? doubleTapZoom,
    double? minZoom,
    double? maxZoom,
    double? overPanDamping,
    ViewerZoomFocal? zoomFocal,
    bool? zoomFling,
    bool? zoomBounce,
    GalleryPagerPhysics? pager,
    GalleryPageTransition? transition,
    GalleryTapRules? taps,
    double? doubleTapEdgeInset,
    double? pageGap,
    bool? controlsVisibleOnOpen,
    Duration? controlsDuration,
    Duration? controlsHideDuration,
    double? controlsSlide,
    bool? desktopInput,
    ViewerVideoRules? video,
    ViewerChromeMetrics? chrome,
    ViewerLoadingRules? loading,
  }) => ViewerPolicy(
    openStyle: openStyle ?? this.openStyle,
    openDuration: openDuration ?? this.openDuration,
    openCurve: openCurve ?? this.openCurve,
    closeDuration: closeDuration ?? this.closeDuration,
    backgroundFadeDuration:
        backgroundFadeDuration ?? this.backgroundFadeDuration,
    backdropScale: backdropScale ?? this.backdropScale,
    dismissDrag: dismissDrag ?? this.dismissDrag,
    dismissSlop: dismissSlop ?? this.dismissSlop,
    dismissRatio: dismissRatio ?? this.dismissRatio,
    dismissFraction: dismissFraction ?? this.dismissFraction,
    dismissDownOnly: dismissDownOnly ?? this.dismissDownOnly,
    dismissVelocity: dismissVelocity ?? this.dismissVelocity,
    backgroundOpacityFloor:
        backgroundOpacityFloor ?? this.backgroundOpacityFloor,
    backgroundFadeWidthFraction:
        backgroundFadeWidthFraction ?? this.backgroundFadeWidthFraction,
    backgroundFadeDistance:
        backgroundFadeDistance ?? this.backgroundFadeDistance,
    backgroundClickCloses: backgroundClickCloses ?? this.backgroundClickCloses,
    controlsReturnOnSpringBack:
        controlsReturnOnSpringBack ?? this.controlsReturnOnSpringBack,
    pictureClickCloses: pictureClickCloses ?? this.pictureClickCloses,
    settleDuration: settleDuration ?? this.settleDuration,
    settleCurve: settleCurve ?? this.settleCurve,
    slideOffDuration: slideOffDuration ?? this.slideOffDuration,
    plainCloseScale: plainCloseScale ?? this.plainCloseScale,
    plainCloseSlides: plainCloseSlides ?? this.plainCloseSlides,
    zoomRule: zoomRule ?? this.zoomRule,
    doubleTapZoom: doubleTapZoom ?? this.doubleTapZoom,
    minZoom: minZoom ?? this.minZoom,
    maxZoom: maxZoom ?? this.maxZoom,
    overPanDamping: overPanDamping ?? this.overPanDamping,
    zoomFocal: zoomFocal ?? this.zoomFocal,
    zoomFling: zoomFling ?? this.zoomFling,
    zoomBounce: zoomBounce ?? this.zoomBounce,
    pager: pager ?? this.pager,
    transition: transition ?? this.transition,
    taps: taps ?? this.taps,
    doubleTapEdgeInset: doubleTapEdgeInset ?? this.doubleTapEdgeInset,
    pageGap: pageGap ?? this.pageGap,
    controlsVisibleOnOpen: controlsVisibleOnOpen ?? this.controlsVisibleOnOpen,
    controlsDuration: controlsDuration ?? this.controlsDuration,
    controlsHideDuration: controlsHideDuration ?? this.controlsHideDuration,
    controlsSlide: controlsSlide ?? this.controlsSlide,
    desktopInput: desktopInput ?? this.desktopInput,
    video: video ?? this.video,
    chrome: chrome ?? this.chrome,
    loading: loading ?? this.loading,
  );
}
