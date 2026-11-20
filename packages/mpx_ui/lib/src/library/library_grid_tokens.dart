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
    this.text = const TextStyle(color: Color(0xFFFFFFFF), fontSize: 15),
    this.title = const TextStyle(
      color: Color(0xFFFFFFFF),
      fontSize: 17,
      fontWeight: FontWeight.w600,
    ),
    this.secondaryText = const TextStyle(
      color: Color(0xFF9E9E9E),
      fontSize: 13,
    ),
    this.accent = const Color(0xFF3390EC),
    this.bannerFill = const Color(0xFF1F1F1F),
    this.menuFill = const Color(0xFF2A2A2A),
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

  /// [checkNumber] for [order]: at its size up to two digits, stepped down
  /// to 10/14 of it at three and 8/14 at four or more, so the number fits
  /// its circle.
  TextStyle orderNumber(int order) {
    final digits = '$order'.length;
    if (digits <= 2) return checkNumber;
    final size = checkNumber.fontSize ?? 13;
    return checkNumber.copyWith(fontSize: size * (digits == 3 ? 10 : 8) / 14);
  }

  /// Badge text and icons.
  final Color badgeForeground;

  /// The pill behind a badge (Android).
  final Color badgeFill;

  /// The shade under a badge (iOS).
  final Color shade;

  /// The camera slot behind the host's preview.
  final Color cameraSlotBackground;

  /// Body text of states, banners and menus.
  final TextStyle text;

  /// Titles of states and of the album switcher.
  final TextStyle title;

  /// Secondary text (counts, explanations).
  final TextStyle secondaryText;

  /// Buttons and actions.
  final Color accent;

  /// Behind a banner over the grid.
  final Color bannerFill;

  /// Behind the album menu.
  final Color menuFill;
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
    this.back,
    this.camera,
    this.dateOf,
    this.highQuality,
  });

  /// A photo cell's kind.
  final String photo;

  /// A video cell's kind.
  final String video;

  /// The cell's open action.
  final String open;

  /// The check's action.
  final String select;

  /// The picker-mode viewer's back button; no label when null.
  final String? back;

  /// The badge of an animated picture.
  final String gif;

  /// The badge of a checked photo sent in high quality ("HD"); no badge
  /// when null.
  final String? highQuality;

  /// The camera slot's button, for screen readers.
  final String? camera;

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

/// The host's words for the library picker's states, banners and album
/// switcher.
@immutable
final class LibraryPickerLabels {
  /// Creates labels.
  const LibraryPickerLabels({
    required this.allMedia,
    required this.allPhotos,
    required this.allVideos,
    required this.cameraAlbum,
    required this.favourites,
    required this.empty,
    required this.deniedTitle,
    required this.deniedText,
    required this.allowAccess,
    required this.openSettings,
    required this.camera,
    required this.restricted,
    required this.limitedText,
    required this.manage,
    required this.selectMore,
    required this.changeSettings,
    required this.partialText,
    required this.cameraDeniedText,
  });

  /// The all-media album's name (Android's All media, iOS's Recents).
  final String allMedia;

  /// Android's All photos.
  final String allPhotos;

  /// Android's All videos.
  final String allVideos;

  /// The camera folder.
  final String cameraAlbum;

  /// The favourites album.
  final String favourites;

  /// An album with nothing in it.
  final String empty;

  /// The denied state's title.
  final String deniedTitle;

  /// The denied state's explanation.
  final String deniedText;

  /// The button that asks for access again (Android).
  final String allowAccess;

  /// The button that opens the system settings.
  final String openSettings;

  /// The button or tile that opens the camera.
  final String camera;

  /// The restricted state's text.
  final String restricted;

  /// The limited-access banner (iOS).
  final String limitedText;

  /// The limited-access banner's action (iOS).
  final String manage;

  /// The manage menu's "select more" (iOS).
  final String selectMore;

  /// The manage menu's "change settings" (iOS).
  final String changeSettings;

  /// The partial-access banner (Android 14).
  final String partialText;

  /// The camera-denied banner (iOS).
  final String cameraDeniedText;

  /// The name shown for [album]: the host's words for the built-in albums,
  /// the platform's title for the others.
  String titleOf(LibraryAlbum album) => switch (album.kind) {
    LibraryAlbumKind.allMedia => allMedia,
    LibraryAlbumKind.allPhotos => allPhotos,
    LibraryAlbumKind.allVideos => allVideos,
    LibraryAlbumKind.camera => album.title.isEmpty ? cameraAlbum : album.title,
    LibraryAlbumKind.favourites => favourites,
    LibraryAlbumKind.system || LibraryAlbumKind.user => album.title,
  };
}
