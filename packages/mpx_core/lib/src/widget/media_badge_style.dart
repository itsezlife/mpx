import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

/// The unit names and labels of a media badge. English by default; a host
/// passes its own.
@immutable
final class MediaBadgeStrings {
  /// Creates the strings.
  const MediaBadgeStrings({
    this.bytes = 'B',
    this.kilobytes = 'KB',
    this.megabytes = 'MB',
    this.gigabytes = 'GB',
    this.gif = 'GIF',
  });

  /// The unit of bytes.
  final String bytes;

  /// The unit of kilobytes (1024 bytes).
  final String kilobytes;

  /// The unit of megabytes (1024 kilobytes).
  final String megabytes;

  /// The unit of gigabytes (1024 megabytes).
  final String gigabytes;

  /// The label of an animated image, in place of a duration.
  final String gif;

  @override
  bool operator ==(Object other) =>
      other is MediaBadgeStrings &&
      other.bytes == bytes &&
      other.kilobytes == kilobytes &&
      other.megabytes == megabytes &&
      other.gigabytes == gigabytes &&
      other.gif == gif;

  @override
  int get hashCode => Object.hash(bytes, kilobytes, megabytes, gigabytes, gif);
}

/// How a pair of sizes ("received / total") is written.
enum MediaSizePairForm {
  /// Each size with its unit: "1.2 MB / 4.5 MB".
  eachUnit,

  /// One unit, the total's, after both: "1.2 / 4.5 MB".
  sharedUnit,

  /// Megabytes in tenths whatever the size: "0.1 / 4.5 MB".
  tenthsOfMegabyte,
}

/// How a media badge writes sizes and times.
@immutable
final class MediaSizeFormat {
  /// Creates a format.
  const MediaSizeFormat({required this.pair, this.narrowBelow = 0});

  /// Android: "1.2 MB / 4.5 MB", "NN%" below 120 px wide.
  static const MediaSizeFormat $Android = MediaSizeFormat(
    pair: MediaSizePairForm.eachUnit,
    narrowBelow: 120,
  );

  /// iOS: "1.2 / 4.5 MB", "NN%" below 120 pt wide.
  static const MediaSizeFormat $IOS = MediaSizeFormat(
    pair: MediaSizePairForm.sharedUnit,
    narrowBelow: 120,
  );

  /// Desktop: "1.2 / 4.5 MB" in tenths of a megabyte; no
  /// narrow form.
  static const MediaSizeFormat $Desktop = MediaSizeFormat(
    pair: MediaSizePairForm.tenthsOfMegabyte,
  );

  /// How a pair of sizes is written.
  final MediaSizePairForm pair;

  /// A badge over media narrower than this writes a download as "NN%".
  final double narrowBelow;

  static const int _kb = 1024;
  static const int _mb = 1024 * 1024;
  static const int _gb = 1024 * 1024 * 1024;

  /// [bytes] with its unit: "830 B", "12.5 KB", "4.5 MB", "1.2 GB".
  String size(
    int bytes, [
    MediaBadgeStrings strings = const MediaBadgeStrings(),
  ]) {
    final (value, unit) = _scaled(bytes, _unitOf(bytes), strings);
    return '$value $unit';
  }

  /// [received] of [total] as [pair] writes it; [received] alone with its
  /// unit when [total] is unknown.
  String progress(
    int received,
    int? total, [
    MediaBadgeStrings strings = const MediaBadgeStrings(),
  ]) {
    if (total == null || total <= 0) {
      return pair == MediaSizePairForm.tenthsOfMegabyte
          ? '${_tenths(received)} ${strings.megabytes}'
          : size(received, strings);
    }
    switch (pair) {
      case MediaSizePairForm.eachUnit:
        return '${size(received, strings)} / ${size(total, strings)}';
      case MediaSizePairForm.sharedUnit:
        final unit = _unitOf(total);
        final (done, _) = _scaled(received, unit, strings);
        final (all, name) = _scaled(total, unit, strings);
        return '$done / $all $name';
      case MediaSizePairForm.tenthsOfMegabyte:
        return '${_tenths(received)} / ${_tenths(total)} '
            '${strings.megabytes}';
    }
  }

  /// The share of [total] received, as "NN%".
  String percent(int received, int total) {
    final share = total <= 0 ? 0 : (100 * received / total).floor();
    return '${share.clamp(0, 100)}%';
  }

  /// [duration] as "m:ss", or "h:mm:ss" from an hour on.
  static String duration(Duration duration) {
    final seconds = duration.isNegative ? 0 : duration.inSeconds;
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
    return '$m:$s';
  }

  static int _unitOf(int bytes) => bytes < _kb
      ? 1
      : bytes < _mb
      ? _kb
      : bytes < _gb
      ? _mb
      : _gb;

  static (String, String) _scaled(
    int bytes,
    int unit,
    MediaBadgeStrings strings,
  ) => switch (unit) {
    1 => ('$bytes', strings.bytes),
    _kb => ((bytes / _kb).toStringAsFixed(1), strings.kilobytes),
    _mb => ((bytes / _mb).toStringAsFixed(1), strings.megabytes),
    _ => ((bytes / _gb).toStringAsFixed(1), strings.gigabytes),
  };

  static String _tenths(int bytes) => (bytes / _mb).toStringAsFixed(1);

  @override
  bool operator ==(Object other) =>
      other is MediaSizeFormat &&
      other.pair == pair &&
      other.narrowBelow == narrowBelow;

  @override
  int get hashCode => Object.hash(pair, narrowBelow);
}

/// The look of a media badge (`MediaBadge`): a small label at the top-left
/// of media with its duration (or "GIF") and, while it downloads, the bytes.
///
/// [$Android], [$IOS] and [$Desktop] are each platform's look; a host
/// sets its theme's text style and colours with [copyWith] through
/// `MediaLoadingStyleScope`.
@immutable
final class MediaBadgeStyle {
  /// Creates a style.
  const MediaBadgeStyle({
    required this.offset,
    required this.background,
    required this.radius,
    required this.padding,
    required this.textStyle,
    required this.fade,
    required this.resize,
    required this.sizeFormat,
  });

  /// Where the badge sits from the top-left corner of the media.
  final Offset offset;

  /// The badge's fill.
  final Color background;

  /// The badge's corner radius.
  final double radius;

  /// Space around the text.
  final EdgeInsets padding;

  /// The text.
  final TextStyle textStyle;

  /// How long the badge takes to come and go.
  final Duration fade;

  /// How long the badge takes to grow to two rows and back.
  final Duration resize;

  /// How sizes and the narrow form are written.
  final MediaSizeFormat sizeFormat;

  /// Android: white 12 on `0x66000000`, radius 8, at (4, 4);
  /// the second row grows in over 200 ms.
  static const MediaBadgeStyle $Android = MediaBadgeStyle(
    offset: Offset(4, 4),
    background: Color(0x66000000),
    radius: 8,
    padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
    textStyle: TextStyle(color: Color(0xFFFFFFFF), fontSize: 12, height: 1.25),
    fade: Duration(milliseconds: 200),
    resize: Duration(milliseconds: 200),
    sizeFormat: MediaSizeFormat.$Android,
  );

  /// iOS: white 11 with monospaced digits on black at 0.3, a
  /// capsule of radius 9, at (6, 6); 0.2 s fades.
  static const MediaBadgeStyle $IOS = MediaBadgeStyle(
    offset: Offset(6, 6),
    background: Color.from(alpha: 0.3, red: 0, green: 0, blue: 0),
    radius: 9,
    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    textStyle: TextStyle(
      color: Color(0xFFFFFFFF),
      fontSize: 11,
      height: 1.27,
      fontFeatures: [FontFeature.tabularFigures()],
    ),
    fade: Duration(milliseconds: 200),
    resize: Duration(milliseconds: 200),
    sizeFormat: MediaSizeFormat.$IOS,
  );

  /// Desktop: white 13 on `#00000054`, at (4, 4), padded
  /// (8, 2).
  static const MediaBadgeStyle $Desktop = MediaBadgeStyle(
    offset: Offset(4, 4),
    background: Color(0x54000000),
    radius: 9,
    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    textStyle: TextStyle(color: Color(0xFFFFFFFF), fontSize: 13, height: 1.2),
    fade: Duration(milliseconds: 200),
    resize: Duration(milliseconds: 200),
    sizeFormat: MediaSizeFormat.$Desktop,
  );

  /// This style with the given fields replaced.
  MediaBadgeStyle copyWith({
    Offset? offset,
    Color? background,
    double? radius,
    EdgeInsets? padding,
    TextStyle? textStyle,
    Duration? fade,
    Duration? resize,
    MediaSizeFormat? sizeFormat,
  }) => MediaBadgeStyle(
    offset: offset ?? this.offset,
    background: background ?? this.background,
    radius: radius ?? this.radius,
    padding: padding ?? this.padding,
    textStyle: textStyle ?? this.textStyle,
    fade: fade ?? this.fade,
    resize: resize ?? this.resize,
    sizeFormat: sizeFormat ?? this.sizeFormat,
  );

  @override
  bool operator ==(Object other) =>
      other is MediaBadgeStyle &&
      other.offset == offset &&
      other.background == background &&
      other.radius == radius &&
      other.padding == padding &&
      other.textStyle == textStyle &&
      other.fade == fade &&
      other.resize == resize &&
      other.sizeFormat == sizeFormat;

  @override
  int get hashCode => Object.hash(
    offset,
    background,
    radius,
    padding,
    textStyle,
    fade,
    resize,
    sizeFormat,
  );
}
