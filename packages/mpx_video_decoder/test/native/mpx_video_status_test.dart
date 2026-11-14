import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_video_decoder/src/binding/ffi/mpx_video_symbols.dart';

/// The numbers in `mpx_video.h` and in `MpxVideoStatus` are written twice
/// by hand; this reads the header so they cannot drift apart.
void main() {
  final header = File('native/include/mpx_video.h').readAsStringSync();

  int headerValue(String name) {
    final match = RegExp('MPX_VIDEO_$name\\s*=\\s*(-?\\d+)').firstMatch(header);
    if (match == null) fail('mpx_video.h has no MPX_VIDEO_$name');
    return int.parse(match.group(1)!);
  }

  test('MpxVideoStatus carries the header numbers', () {
    expect(MpxVideoStatus.endOfStream, headerValue('END_OF_STREAM'));
    expect(MpxVideoStatus.ok, headerValue('OK'));
    expect(MpxVideoStatus.invalidArgument, headerValue('INVALID_ARGUMENT'));
    expect(MpxVideoStatus.tooLarge, headerValue('TOO_LARGE'));
    expect(MpxVideoStatus.malformed, headerValue('MALFORMED'));
    expect(MpxVideoStatus.limitExceeded, headerValue('LIMIT_EXCEEDED'));
    expect(MpxVideoStatus.unsupported, headerValue('UNSUPPORTED'));
    expect(MpxVideoStatus.internal, headerValue('INTERNAL'));
    expect(MpxVideoStatus.badSize, headerValue('BAD_SIZE'));
    expect(MpxVideoStatus.decodeFailed, headerValue('DECODE_FAILED'));
    expect(MpxVideoStatus.sourceFailed, headerValue('SOURCE_FAILED'));
  });

  test('the header lists no status the binding lacks', () {
    final statusEnum = RegExp(
      r'enum \{\s*MPX_VIDEO_END_OF_STREAM.*?\};',
      dotAll: true,
    ).firstMatch(header)!.group(0)!;
    final names = RegExp(r'MPX_VIDEO_([A-Z_]+)\s*=').allMatches(statusEnum);

    expect(names, hasLength(11));
  });

  test('the ABI version is the one the binding expects', () {
    expect(MpxVideoAbi.expectedVersion, headerValue('ABI_VERSION'));
    expect(MpxVideoAbi.readerVersion, headerValue('READER_ABI_VERSION'));
  });
}
