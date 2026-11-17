import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// The colours and type of the viewer, supplied by the host from its own
/// theme: the package carries no palette of its own.
///
/// The defaults are the Android reference's values, for a host without a
/// theme of its own.
@immutable
final class ViewerTokens {
  /// Creates tokens.
  const ViewerTokens({
    this.background = const Color(0xFF000000),
    this.barFill = const Color(0x7F000000),
    this.foreground = const Color(0xFFFFFFFF),
    this.title = const TextStyle(
      color: Color(0xFFFFFFFF),
      fontSize: 20,
      fontWeight: FontWeight.bold,
    ),
    this.subtitle = const TextStyle(color: Color(0xFFFFFFFF), fontSize: 14),
    this.counter = const TextStyle(
      color: Color(0xFFFFFFFF),
      fontSize: 14,
      fontWeight: FontWeight.bold,
    ),
    this.caption = const TextStyle(color: Color(0xFFFFFFFF), fontSize: 16),
    this.link = const Color(0xFF79C4FC),
    this.menuBackground = const Color(0xFF222222),
    this.menuForeground = const Color(0xFFFAFAFA),
    this.menuDivider = const Color(0xFF181818),
    this.placeholder = const Color(0xFF1C1C1C),
  });

  /// Behind the picture, at full opacity once open.
  final Color background;

  /// The fill of the top and bottom bars, the counter pill and the caption
  /// scrim.
  final Color barFill;

  /// Icons and controls over the bars.
  final Color foreground;

  /// The title in the top bar (the author, or the kind of media).
  final TextStyle title;

  /// The line under the title (the date).
  final TextStyle subtitle;

  /// The "N of M" counter.
  final TextStyle counter;

  /// The caption.
  final TextStyle caption;

  /// Links in the caption.
  final Color link;

  /// The overflow menu's background.
  final Color menuBackground;

  /// The overflow menu's text and icons.
  final Color menuForeground;

  /// The gap between groups of the overflow menu.
  final Color menuDivider;

  /// What a thumbnail-strip cell of an item not loaded yet shows. A page of
  /// such an item shows nothing on the black page.
  final Color placeholder;
}
