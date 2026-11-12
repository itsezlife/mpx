import 'package:meta/meta.dart';

/// Bytes `[start, end)` of a representation; a null [end] runs to its end.
///
/// Half-open, like the store's range sets: a range of length `n` at `s` is
/// `ByteRange(s, s + n)`. [header] converts to the inclusive wire form.
@immutable
final class ByteRange {
  /// Bytes from [start] up to, not including, [end].
  const ByteRange(this.start, [this.end])
    : assert(start >= 0, 'start must be >= 0'),
      assert(end == null || end > start, 'end must be after start');

  /// First byte.
  final int start;

  /// One past the last byte, or null for "to the end".
  final int? end;

  /// Byte count, or null when open.
  int? get length => switch (end) {
    final e? => e - start,
    null => null,
  };

  /// The `Range` request header value (`bytes=0-99`, `bytes=100-`).
  String get header =>
      'bytes=$start-${switch (end) {
        final e? => e - 1,
        null => '',
      }}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ByteRange($start, $end)';
}

/// A parsed satisfied `Content-Range` (`bytes 0-99/1000`), half-open.
@immutable
final class ContentRange {
  /// Bytes `[start, end)` of a representation [totalLength] long (null when
  /// the server sent `*`).
  const ContentRange(this.start, this.end, [this.totalLength]);

  /// First byte in the body.
  final int start;

  /// One past the last byte in the body.
  final int end;

  /// Length of the whole representation, when the server knew it.
  final int? totalLength;

  static final RegExp _satisfied = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
    caseSensitive: false,
  );

  static final RegExp _unsatisfied = RegExp(
    r'^bytes\s+\*/(\d+)$',
    caseSensitive: false,
  );

  /// Parses a satisfied range; null for the unsatisfied form, another unit,
  /// or a malformed value (multipart answers are never asked for).
  static ContentRange? parse(String? header) {
    final match = _satisfied.firstMatch(header?.trim() ?? '');
    if (match == null) return null;
    final start = int.parse(match.group(1)!);
    final last = int.parse(match.group(2)!);
    final total = int.tryParse(match.group(3)!);
    if (last < start || (total != null && last >= total)) return null;
    return ContentRange(start, last + 1, total);
  }

  /// The length from an unsatisfied `bytes */1000`, as a `416` carries it.
  static int? unsatisfiedLength(String? header) =>
      switch (_unsatisfied.firstMatch(header?.trim() ?? '')) {
        final match? => int.parse(match.group(1)!),
        null => null,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContentRange &&
          other.start == start &&
          other.end == end &&
          other.totalLength == totalLength;

  @override
  int get hashCode => Object.hash(start, end, totalLength);

  @override
  String toString() => 'ContentRange($start, $end, $totalLength)';
}
