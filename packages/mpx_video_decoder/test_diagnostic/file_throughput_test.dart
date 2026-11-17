// Diagnostic, not in unit_test.dart. Frames per second one decode worker
// sustains on real files read in place, at the size a list tile asks for:
//
//   MPX_VIDEO_FILES=/path/a.mp4:/path/b.webm \
//     flutter test test_diagnostic/file_throughput_test.dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_video_decoder/src/binding/binding.dart';

void main() {
  final files = (Platform.environment['MPX_VIDEO_FILES'] ?? '')
      .split(':')
      .where((f) => f.isNotEmpty)
      .toList();
  test(
    'file throughput',
    skip: files.isEmpty ? 'set MPX_VIDEO_FILES' : null,
    () {
      final binding = NativeVideoBinding.probe();
      for (final file in files) {
        const width = 512;
        const height = 288;
        final opened =
            binding.open(VideoSource.file(file), width: width, height: height)
                as VideoOpened;
        final target = calloc<Uint8>(width * height * 4);
        final clock = Stopwatch()..start();
        var frames = 0;
        var first = 0;
        final pts = <int>[];
        while (clock.elapsedMilliseconds < 3000) {
          final result = binding.nextFrame(
            opened.handle,
            target: target,
            strideBytes: width * 4,
          );
          if (result.status != VideoFrameStatus.frame) break;
          if (frames == 0) first = clock.elapsedMicroseconds;
          if (frames < 8 || frames % 100 == 0) pts.add(result.ptsMs);
          frames++;
        }
        final seconds = clock.elapsedMicroseconds / 1e6;
        // ignore: avoid_print
        print(
          '${file.split('/').last} ${opened.info.width}x${opened.info.height} '
          '${opened.info.frameRate} fps source: first frame '
          '${(first / 1000).toStringAsFixed(1)} ms, '
          '${(frames / seconds).toStringAsFixed(1)} fps decoded at '
          '${width}x$height; pts $pts',
        );
        calloc.free(target);
        binding.dispose(opened.handle);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
