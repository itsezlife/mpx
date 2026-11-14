import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_example/lab/corpus.dart';
import 'package:mpx_example/lab/lab_coverage.dart';
import 'package:mpx_example/lab/stress_feed.dart';
import 'package:mpx_video_decoder/mpx_video_decoder.dart';
import 'package:mpx_video_decoder/testing.dart';

void main() {
  const info = VideoInfo(
    width: 8,
    height: 8,
    duration: Duration(milliseconds: 300),
    frameRate: 10,
    hasAlpha: false,
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'counts the items with a picture and the frames decoded per kind',
    () async {
      final items = StressItems(
        count: 4,
        sources: const [
          CorpusEntry(file: 'loop.webm', kind: CorpusKind.loop),
          CorpusEntry(file: 'still.png', kind: CorpusKind.still),
        ],
        kinds: CorpusKind.values.toSet(),
        distinct: true,
      );
      final scope = AssetCacheScope(
        producer: FakeAssetProducer(),
        clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
      );
      addTearDown(scope.dispose);
      LabCoverage.watch(scope, items);
      final loop = items.keyAt(0);
      final binding = FakeVideoBinding()
        ..acceptSource(
          VideoSource.file('/cache/${loop.encoded}'),
          info,
          frameCount: 3,
        );
      final engine = LabCoverage.count(InProcessVideoEngine(binding));
      addTearDown(engine.dispose);

      LabCoverage.start();
      final clip =
          (await engine.open(
                    VideoSource.file('/cache/${loop.encoded}'),
                    width: 8,
                    height: 8,
                  )
                  as VideoClipOpened)
              .clip;
      final pixels = Uint8List(clip.frameBytes);
      for (var i = 0; i < 5; i++) {
        await engine.nextFrame(clip, destination: pixels);
      }

      final line = LabCoverage.stop();

      expect(line, startsWith('coverage content=0/4 '));
      expect(line, contains('content.loop=0/2'));
      expect(line, contains('content.still=0/2'));
      expect(line, contains('videoFrames=3 videoFrames.loop=3'));
    },
  );
}
