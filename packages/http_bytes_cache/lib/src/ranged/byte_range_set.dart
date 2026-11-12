import 'package:meta/meta.dart';

/// The bytes of a ranged resource that are present: sorted, disjoint,
/// half-open spans `[start, end)`.
///
/// Immutable. [add] merges overlapping and touching spans, so two sets with
/// the same bytes are equal whatever order the bytes landed in.
@immutable
final class ByteRangeSet {
  const ByteRangeSet._(this._flat);

  /// No bytes.
  static const ByteRangeSet empty = ByteRangeSet._([]);

  /// Reads the `[s0, e0, s1, e1, …]` form [toFlatList] writes.
  ///
  /// Throws [FormatException] for an odd count, an empty or reversed span,
  /// or spans out of order or touching (a stored set is always merged).
  factory ByteRangeSet.fromFlatList(List<int> flat) {
    if (flat.length.isOdd) {
      throw const FormatException('range set: odd number of bounds');
    }
    for (var i = 0; i < flat.length; i += 2) {
      final start = flat[i];
      final end = flat[i + 1];
      final previousEnd = i == 0 ? -1 : flat[i - 1];
      if (start < 0 || end <= start || start <= previousEnd) {
        throw const FormatException('range set: spans out of order');
      }
    }
    return ByteRangeSet._(List<int>.unmodifiable(flat));
  }

  /// Bounds as `[s0, e0, s1, e1, …]`.
  final List<int> _flat;

  /// The spans as `(start, end)` records, in order.
  List<(int, int)> get spans => [
    for (var i = 0; i < _flat.length; i += 2) (_flat[i], _flat[i + 1]),
  ];

  /// Whether no byte is present.
  bool get isEmpty => _flat.isEmpty;

  /// Bytes present.
  int get coveredBytes {
    var sum = 0;
    for (var i = 0; i < _flat.length; i += 2) {
      sum += _flat[i + 1] - _flat[i];
    }
    return sum;
  }

  /// This set plus `[start, end)`.
  ByteRangeSet add(int start, int end) {
    assert(start >= 0 && end >= start, 'invalid span [$start, $end)');
    if (end == start) return this;
    final out = <int>[];
    var newStart = start;
    var newEnd = end;
    var placed = false;
    for (var i = 0; i < _flat.length; i += 2) {
      final s = _flat[i];
      final e = _flat[i + 1];
      if (e < newStart) {
        out.addAll([s, e]);
      } else if (s > newEnd) {
        if (!placed) {
          out.addAll([newStart, newEnd]);
          placed = true;
        }
        out.addAll([s, e]);
      } else {
        // Overlapping or touching: absorb into the new span.
        if (s < newStart) newStart = s;
        if (e > newEnd) newEnd = e;
      }
    }
    if (!placed) out.addAll([newStart, newEnd]);
    return ByteRangeSet._(List<int>.unmodifiable(out));
  }

  /// Whether every byte of `[start, end)` is present.
  bool covers(int start, int end) => firstGap(start, end) == null;

  /// The first missing span inside `[start, end)`, or null when none is.
  (int, int)? firstGap(int start, int end) {
    var cursor = start;
    for (var i = 0; i < _flat.length && cursor < end; i += 2) {
      final s = _flat[i];
      final e = _flat[i + 1];
      if (e <= cursor) continue;
      if (s > cursor) return (cursor, s < end ? s : end);
      cursor = e;
    }
    return cursor < end ? (cursor, end) : null;
  }

  /// End of the present bytes that run unbroken from [offset]; [offset]
  /// itself when the byte at [offset] is missing.
  int contiguousFrom(int offset) {
    for (var i = 0; i < _flat.length; i += 2) {
      if (_flat[i] <= offset && offset < _flat[i + 1]) return _flat[i + 1];
    }
    return offset;
  }

  /// Start of the first present span at or after [offset], or null.
  int? nextPresentFrom(int offset) {
    for (var i = 0; i < _flat.length; i += 2) {
      if (_flat[i + 1] > offset) return _flat[i] > offset ? _flat[i] : offset;
    }
    return null;
  }

  /// `[s0, e0, s1, e1, …]`, the index's wire form.
  List<int> toFlatList() => _flat;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ByteRangeSet || other._flat.length != _flat.length) {
      return false;
    }
    for (var i = 0; i < _flat.length; i++) {
      if (other._flat[i] != _flat[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_flat);

  @override
  String toString() => 'ByteRangeSet($spans)';
}
