import 'dart:math' as math;

import 'package:flutter/rendering.dart';

/// The fixed-extent layout of the library grid: square cells of [extent],
/// [gap] apart in [columns] columns, and, with [cameraSlot], child 0 the
/// camera slot one column wide and two rows tall at the leading top, the
/// assets flowing around it.
///
/// Cells never measure: every position follows from the index, so the grid
/// scrolls a library of any size without laying out what it skips.
final class LibraryGridDelegate extends SliverGridDelegate {
  /// Creates the delegate.
  const LibraryGridDelegate({
    required this.columns,
    required this.extent,
    required this.gap,
    required this.cameraSlot,
  }) : assert(columns >= 2 || !cameraSlot, 'A camera slot needs 2 columns.');

  /// Columns.
  final int columns;

  /// A cell's side.
  final double extent;

  /// The space between cells.
  final double gap;

  /// Whether child 0 is the camera slot.
  final bool cameraSlot;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) =>
      LibraryGridLayout(
        columns: columns,
        extent: extent,
        gap: gap,
        cameraSlot: cameraSlot,
        reverseCrossAxis: axisDirectionIsReversed(
          constraints.crossAxisDirection,
        ),
        crossAxisExtent: constraints.crossAxisExtent,
      );

  @override
  bool shouldRelayout(LibraryGridDelegate oldDelegate) =>
      oldDelegate.columns != columns ||
      oldDelegate.extent != extent ||
      oldDelegate.gap != gap ||
      oldDelegate.cameraSlot != cameraSlot;
}

/// The layout [LibraryGridDelegate] makes; see there.
final class LibraryGridLayout extends SliverGridLayout {
  /// Creates the layout.
  const LibraryGridLayout({
    required this.columns,
    required this.extent,
    required this.gap,
    required this.cameraSlot,
    required this.reverseCrossAxis,
    required this.crossAxisExtent,
  });

  /// Columns.
  final int columns;

  /// A cell's side.
  final double extent;

  /// The space between cells.
  final double gap;

  /// Whether child 0 is the camera slot.
  final bool cameraSlot;

  /// Whether columns run from the trailing edge (right to left).
  final bool reverseCrossAxis;

  /// The grid's width.
  final double crossAxisExtent;

  double get _stride => extent + gap;

  // Assets beside the camera slot, in its two rows.
  int get _besideCamera => cameraSlot ? 2 * (columns - 1) : 0;

  /// The row and column of child [index].
  (int, int) cellOf(int index) {
    if (cameraSlot && index == 0) return (0, 0);
    final asset = cameraSlot ? index - 1 : index;
    if (asset < _besideCamera) {
      return (asset ~/ (columns - 1), 1 + asset % (columns - 1));
    }
    final rest = asset - _besideCamera;
    return ((cameraSlot ? 2 : 0) + rest ~/ columns, rest % columns);
  }

  int _firstOfRow(int row) {
    if (!cameraSlot) return row * columns;
    if (row < 2) return 0;
    return 1 + _besideCamera + (row - 2) * columns;
  }

  int _lastOfRow(int row) {
    if (!cameraSlot) return (row + 1) * columns - 1;
    if (row < 2) return (row + 1) * (columns - 1);
    return _besideCamera + (row - 1) * columns;
  }

  int _rowAt(double scrollOffset) =>
      _stride <= 0 ? 0 : math.max(0, (scrollOffset / _stride).floor());

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) =>
      _firstOfRow(_rowAt(scrollOffset));

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) =>
      _lastOfRow(_rowAt(scrollOffset));

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    final (row, column) = cellOf(index);
    final camera = cameraSlot && index == 0;
    final start = column * _stride;
    return SliverGridGeometry(
      scrollOffset: row * _stride,
      crossAxisOffset: reverseCrossAxis
          ? crossAxisExtent - start - extent
          : start,
      mainAxisExtent: camera ? 2 * extent + gap : extent,
      crossAxisExtent: extent,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) {
    if (childCount <= 0) return 0;
    final assets = childCount - (cameraSlot ? 1 : 0);
    final int rows;
    if (cameraSlot) {
      rows = assets <= _besideCamera
          ? 2
          : 2 + ((assets - _besideCamera) / columns).ceil();
    } else {
      rows = (assets / columns).ceil();
    }
    return math.max(0, rows * _stride - gap);
  }
}
