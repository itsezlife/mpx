import 'dart:convert';
import 'dart:typed_data';

/// What [JournalFrames.decode] read from a blob.
typedef FramesRead = ({
  /// The payloads of the whole frames, in order, each decoded from JSON;
  /// null for a whole frame whose bytes are not JSON.
  List<Object?> payloads,

  /// The bytes after the last whole frame, dropped.
  int tornBytes,
});

/// The byte format of everything the package keeps in a `JournalStore`: a
/// sequence of frames, each a little-endian 32-bit payload length, a 32-bit
/// FNV-1a checksum of the payload, then the payload, UTF-8 JSON.
///
/// The checksum, not only the length, decides where a log ends: a kill
/// mid-write can leave a header whose length runs past the end, but also,
/// on some file systems, a frame whose bytes are zeros. Everything from the
/// first frame that fails either check is the torn tail.
///
/// Internal to the package: the journal and the reuse table frame their
/// own entries with it.
abstract final class JournalFrames {
  static const int _header = 8;

  /// [payloads] as frames, one after another.
  static Uint8List encode(Iterable<Object?> payloads) {
    final out = BytesBuilder(copy: false);
    for (final payload in payloads) {
      final bytes = utf8.encode(jsonEncode(payload));
      final header = ByteData(_header)
        ..setUint32(0, bytes.length, Endian.little)
        ..setUint32(4, _fnv1a(bytes), Endian.little);
      out
        ..add(header.buffer.asUint8List())
        ..add(bytes);
    }
    return out.takeBytes();
  }

  /// The payloads in [bytes], up to the first frame that is not whole.
  static FramesRead decode(Uint8List bytes) {
    final payloads = <Object?>[];
    final view = ByteData.sublistView(bytes);
    var offset = 0;
    while (offset + _header <= bytes.length) {
      final length = view.getUint32(offset, Endian.little);
      final checksum = view.getUint32(offset + 4, Endian.little);
      final start = offset + _header;
      if (length > bytes.length - start) break;
      final payload = Uint8List.sublistView(bytes, start, start + length);
      if (_fnv1a(payload) != checksum) break;
      offset = start + length;
      payloads.add(_tryJson(payload));
    }
    return (payloads: payloads, tornBytes: bytes.length - offset);
  }

  static Object? _tryJson(Uint8List payload) {
    try {
      return jsonDecode(utf8.decode(payload));
    } on FormatException {
      // A whole frame that is not JSON reads as nothing; its reader skips it.
      return null;
    }
  }

  static int _fnv1a(List<int> bytes) {
    var hash = 0x811c9dc5;
    for (final byte in bytes) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}
