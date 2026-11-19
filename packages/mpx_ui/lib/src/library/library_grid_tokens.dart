import 'package:flutter/widgets.dart';
import 'package:mpx_library/mpx_library.dart';

/// The colours and text styles of the library grid, from the host (as the
/// viewer takes `ViewerTokens`).
@immutable
final class LibraryGridTokens {
  /// Creates tokens.
  const LibraryGridTokens({
    this.background = const Color(0xFF000000),
    this.cellPlaceholder = const Color(0xFF1C1C1C),
    this.checkFill = const Color(0xFF3390EC),
    this.checkRing = const Color(0xFFFFFFFF),
    this.checkIdleFill = const Color(0x33000000),
    this.checkNumber = const TextStyle(
      color: Color(0xFFFFFFFF),
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    this.badgeForeground = const Color(0xFFFFFFFF),
    this.badgeFill = const Color(0x66000000),
    this.shade = const Color(0x99000000),
    this.cameraSlotBackground = const Color(0xFF000000),
  });

  /// Behind the cells.
  final Color background;

  /// A cell before its thumbnail.
  final Color cellPlaceholder;

  /// The check of a selected cell.
  final Color checkFill;

  /// The check's ring.
  final Color checkRing;

  /// The inside of an unselected check.
  final Color checkIdleFill;

  /// The order number in a check.
  final TextStyle checkNumber;

  /// Badge text and icons.
  final Color badgeForeground;

  /// The pill behind a badge (Android).
  final Color badgeFill;

  /// The shade under a badge (iOS).
  final Color shade;

  /// The camera slot behind the host's preview.
  final Color cameraSlotBackground;
}

/// The host's words for the library grid, read by screen readers and shown
/// on badges.
@immutable
final class LibraryGridLabels {
  /// Creates labels.
  const LibraryGridLabels({
    required this.photo,
    required this.video,
    required this.open,
    required this.select,
    required this.gif,
    this.dateOf,
  });

  /// A photo cell's kind.
  final String photo;

  /// A video cell's kind.
  final String video;

  /// The cell's open action.
  final String open;

  /// The check's action.
  final String select;

  /// The badge of an animated picture.
  final String gif;

  /// The words for an asset's date, or null to leave it out.
  final String Function(DateTime date)? dateOf;

  /// What a screen reader says for [asset].
  String describe(LibraryAsset asset) {
    final parts = <String>[
      if (asset.kind == LibraryAssetKind.video) video else photo,
      if (asset.duration case final duration?) formatDuration(duration),
      if ((asset.created, dateOf) case (final date?, final words?)) words(date),
    ];
    return parts.join(', ');
  }

  /// `m:ss`, or `h:mm:ss` from an hour.
  static String formatDuration(Duration duration) {
    final seconds = duration.inSeconds;
    final h = seconds ~/ 3600;
    final m = (seconds ~/ 60) % 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }
}
