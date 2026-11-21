import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// How a swipe across the grid selects cells.
enum SwipeSelectRule {
  /// A long press on a cell, then a drag over the others.
  longPressDrag,

  /// A horizontal pan that starts past [LibraryGridPolicy.swipeStartInset]
  /// from the leading edge and fails when it moves more than
  /// [LibraryGridPolicy.swipeVerticalSlop] vertically before
  /// [LibraryGridPolicy.swipeHorizontalSlop] horizontally. Scrolling is off
  /// while it runs.
  horizontalPan,
}

/// Where the library grid puts the camera slot.
enum CameraSlotPlacement {
  /// In the all-media album, whatever the column count.
  allMediaAlbum,

  /// In the all-media album at three columns only.
  allMediaAlbumAtThreeColumns,
}

/// The per-platform values of the library grid: columns, gaps, corners, the
/// check, the selection motion, badges, swipe select and the camera slot.
///
/// | | [$Android] | [$IOS] |
/// | --- | --- | --- |
/// | Columns | 3 portrait, 4 landscape or tablet | 3 portrait, 5 landscape |
/// | Gap | 2 dp, and 2 dp padding | 1 pt, cells `floor((w - (n - 1)) / n)` |
/// | First-row outer corners | 16 dp | none |
/// | Check | 24 in a 26 frame, 42 hit | 29, slop 8 |
/// | Selected image | scales to 0.787 over 200 ms | stays; the check springs over 0.5 s |
/// | Duration | bottom-left, bold 12 | bottom-right, semibold 11 over a shade |
/// | Swipe select | long press, then drag | horizontal pan from x > 44 |
/// | Camera slot | all-media album | all-media album at 3 columns |
/// | Changes while the viewer is open | deferred | applied |
@immutable
final class LibraryGridPolicy {
  /// Creates a policy.
  const LibraryGridPolicy({
    required this.portraitColumns,
    required this.landscapeColumns,
    required this.gap,
    required this.padding,
    required this.floorCells,
    required this.firstRowCornerRadius,
    required this.checkSize,
    required this.checkFrame,
    required this.checkHitSize,
    required this.selectedImageScale,
    required this.selectionDuration,
    required this.checkSpring,
    required this.durationAlignment,
    required this.durationFontWeight,
    required this.durationFontSize,
    required this.durationShade,
    required this.subtypeIcons,
    required this.swipeRule,
    required this.cameraPlacement,
    required this.defersChangesWhileViewerOpen,
    required this.errorHaptic,
    required this.keepsDeniedCameraSlot,
    required this.viewerCheckSize,
    this.selectedStripHeight = 103,
    this.viewerInfoLine = true,
    this.disabledOpacity = 0.3,
    this.swipeStartInset = 44,
    this.swipeVerticalSlop = 5,
    this.swipeHorizontalSlop = 8,
    this.autoScrollEdge = 60,
    this.tabletShortestSide = 600,
    this.gifBadge = true,
    this.liveCornerMark = false,
    this.videoPlayMark = false,
    this.viewerTapSelects = true,
    this.captureViewerEvery,
  });

  /// Android's values.
  static const LibraryGridPolicy $Android = LibraryGridPolicy(
    portraitColumns: 3,
    landscapeColumns: 4,
    gap: 2,
    padding: 2,
    floorCells: false,
    firstRowCornerRadius: 16,
    checkSize: 24,
    checkFrame: 26,
    checkHitSize: 42,
    selectedImageScale: 0.787,
    selectionDuration: Duration(milliseconds: 200),
    checkSpring: Duration.zero,
    durationAlignment: AlignmentDirectional.bottomStart,
    durationFontWeight: FontWeight.bold,
    durationFontSize: 12,
    durationShade: false,
    subtypeIcons: false,
    gifBadge: false,
    liveCornerMark: true,
    videoPlayMark: true,
    swipeRule: SwipeSelectRule.longPressDrag,
    cameraPlacement: CameraSlotPlacement.allMediaAlbum,
    defersChangesWhileViewerOpen: true,
    errorHaptic: false,
    keepsDeniedCameraSlot: true,
    viewerCheckSize: 34,
  );

  /// iOS's values.
  static const LibraryGridPolicy $IOS = LibraryGridPolicy(
    portraitColumns: 3,
    landscapeColumns: 5,
    gap: 1,
    padding: 0,
    floorCells: true,
    firstRowCornerRadius: 0,
    checkSize: 29,
    checkFrame: 29,
    checkHitSize: 29 + 2 * 8,
    selectedImageScale: 1,
    selectionDuration: Duration(milliseconds: 200),
    checkSpring: Duration(milliseconds: 500),
    durationAlignment: AlignmentDirectional.bottomEnd,
    durationFontWeight: FontWeight.w600,
    durationFontSize: 11,
    durationShade: true,
    subtypeIcons: true,
    swipeRule: SwipeSelectRule.horizontalPan,
    cameraPlacement: CameraSlotPlacement.allMediaAlbumAtThreeColumns,
    defersChangesWhileViewerOpen: false,
    errorHaptic: true,
    keepsDeniedCameraSlot: false,
    viewerCheckSize: 29,
    viewerInfoLine: false,
    captureViewerEvery: 10,
  );

  /// [$IOS] on iOS and macOS, [$Android] elsewhere.
  static LibraryGridPolicy forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS || TargetPlatform.macOS => $IOS,
        _ => $Android,
      };

  /// Columns in portrait.
  final int portraitColumns;

  /// Columns in landscape, and on a tablet ([$Android]).
  final int landscapeColumns;

  /// The space between cells, in logical pixels.
  final double gap;

  /// The space around the grid, in logical pixels.
  final double padding;

  /// Whether cell sides are floored to whole pixels (the remainder left at
  /// the trailing edge).
  final bool floorCells;

  /// The radius of the first row's outer corners.
  final double firstRowCornerRadius;

  /// The check's diameter.
  final double checkSize;

  /// The frame the check sits in (its ring's outer size).
  final double checkFrame;

  /// The check's hit square.
  final double checkHitSize;

  /// The scale of a selected cell's image.
  final double selectedImageScale;

  /// How long the image's scale takes.
  final Duration selectionDuration;

  /// How long the check's spring takes; zero for none.
  final Duration checkSpring;

  /// Where a video's duration sits.
  final AlignmentDirectional durationAlignment;

  /// The duration's weight.
  final FontWeight durationFontWeight;

  /// The duration's size.
  final double durationFontSize;

  /// Whether a shade lies under the duration.
  final bool durationShade;

  /// Whether cells mark live, slow-motion and time-lapse items.
  final bool subtypeIcons;

  /// How a swipe selects.
  final SwipeSelectRule swipeRule;

  /// Where the camera slot goes.
  final CameraSlotPlacement cameraPlacement;

  /// Whether library changes wait while the picker-mode viewer is open.
  final bool defersChangesWhileViewerOpen;

  /// Whether a refused toggle plays the error haptic.
  final bool errorHaptic;

  /// The check of the picker-mode viewer.
  final double viewerCheckSize;

  /// The height of the picker-mode viewer's strip of selected items.
  final double selectedStripHeight;

  /// Whether the picker-mode viewer's top bar shows an info line under its
  /// title (a video's size, duration and bytes): `$Android` does, `$IOS`
  /// shows no such line.
  final bool viewerInfoLine;

  /// Whether the camera slot stays when camera access is denied (its
  /// builder is told); otherwise it goes and a banner says why.
  final bool keepsDeniedCameraSlot;

  /// The opacity of a cell the selection's gate refuses.
  final double disabledOpacity;

  /// How far from the leading edge a [SwipeSelectRule.horizontalPan] must
  /// start.
  final double swipeStartInset;

  /// The vertical movement that fails a [SwipeSelectRule.horizontalPan]
  /// before it is accepted.
  final double swipeVerticalSlop;

  /// The horizontal movement that accepts a [SwipeSelectRule.horizontalPan].
  final double swipeHorizontalSlop;

  /// How close to the top or bottom edge a swipe auto-scrolls.
  final double autoScrollEdge;

  /// Whether an animated picture says GIF in its badge (`$IOS`); `$Android`
  /// shows it as a photo.
  final bool gifBadge;

  /// Whether a live photo has its mark at the top start, 8 px in, 22 x 18
  /// (`$Android`); `$IOS` shows it among the subtype icons.
  final bool liveCornerMark;

  /// Whether a video's badge leads with a play mark (`$Android`).
  final bool videoPlayMark;

  /// Whether a single tap on a photo in the picker-mode viewer toggles its
  /// selection; a tap on a video plays or pauses it either way, and the
  /// chrome stays.
  final bool viewerTapSelects;

  /// Besides the first capture, every how many captures the viewer opens on
  /// the newest (the 10th, 20th, … on iOS); null for the first only.
  final int? captureViewerEvery;

  /// Whether the [count]th capture opens the viewer.
  bool opensViewerOnCapture(int count) {
    if (count == 1) return true;
    final every = captureViewerEvery;
    return every != null && count > 0 && count % every == 0;
  }

  /// The shortest side from which a screen counts as a tablet.
  final double tabletShortestSide;

  /// The column count for a grid of [size] on a screen of [screen].
  int columnsFor(Size size, {Size? screen}) {
    final landscape = size.width > size.height;
    final tablet =
        identical(this, $Android) &&
        (screen ?? size).shortestSide >= tabletShortestSide;
    return landscape || tablet ? landscapeColumns : portraitColumns;
  }

  /// The side of a cell in a grid [width] wide with [columns] columns.
  double cellExtent(double width, int columns) {
    final free = width - 2 * padding - gap * (columns - 1);
    final side = free / columns;
    return math.max(0, floorCells ? side.floorToDouble() : side);
  }

  /// Whether the camera slot shows at [columns] columns in an album that
  /// [isAllMedia] or not.
  bool showsCameraSlot({required bool isAllMedia, required int columns}) =>
      isAllMedia &&
      switch (cameraPlacement) {
        CameraSlotPlacement.allMediaAlbum => true,
        CameraSlotPlacement.allMediaAlbumAtThreeColumns => columns == 3,
      };
}
