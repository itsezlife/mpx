import 'dart:typed_data';

/// The same MP4 with its `moov` box moved after the media data, as a camera
/// or an export without fast start writes it: the chunk offsets in `stco`
/// and `co64` are moved with the media data, so it plays the same.
Uint8List moovAtEnd(Uint8List mp4) {
  final boxes = _topLevel(mp4);
  final moov = boxes.firstWhere((b) => b.type == 'moov');
  final before = boxes.takeWhile((b) => b != moov).toList();
  final after = boxes.skip(before.length + 1).toList();
  if (after.every((b) => b.type != 'mdat')) {
    throw ArgumentError('the moov is already after the media data');
  }
  final moved = Uint8List.fromList(mp4.sublist(moov.start, moov.end));
  _shiftChunkOffsets(moved, 0, moved.length, -moved.length);
  return Uint8List.fromList([
    for (final b in [...before, ...after]) ...mp4.sublist(b.start, b.end),
    ...moved,
  ]);
}

/// Where [type]'s top-level box is: `(start, end)`.
(int, int) boxSpan(Uint8List mp4, String type) {
  final box = _topLevel(mp4).firstWhere((b) => b.type == type);
  return (box.start, box.end);
}

final class _Box {
  const _Box(this.type, this.start, this.end);
  final String type;
  final int start;
  final int end;
}

List<_Box> _topLevel(Uint8List bytes) => _children(bytes, 0, bytes.length);

List<_Box> _children(Uint8List bytes, int from, int to) {
  final data = ByteData.sublistView(bytes);
  final out = <_Box>[];
  var at = from;
  while (at + 8 <= to) {
    final size = data.getUint32(at);
    final type = String.fromCharCodes(bytes, at + 4, at + 8);
    if (size < 8 || at + size > to) break;
    out.add(_Box(type, at, at + size));
    at += size;
  }
  return out;
}

const _containers = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf'};

void _shiftChunkOffsets(Uint8List box, int from, int to, int by) {
  final data = ByteData.sublistView(box);
  for (final child in _children(box, from + (from == 0 ? 8 : 0), to)) {
    if (_containers.contains(child.type)) {
      _shiftChunkOffsets(box, child.start + 8, child.end, by);
    } else if (child.type == 'stco') {
      final count = data.getUint32(child.start + 12);
      for (var i = 0; i < count; i++) {
        final at = child.start + 16 + i * 4;
        data.setUint32(at, data.getUint32(at) + by);
      }
    } else if (child.type == 'co64') {
      final count = data.getUint32(child.start + 12);
      for (var i = 0; i < count; i++) {
        final at = child.start + 16 + i * 8;
        data.setUint64(at, data.getUint64(at) + by);
      }
    }
  }
}
