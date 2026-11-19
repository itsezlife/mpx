import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';
import 'package:mpx_core/mpx_core.dart';

const _mb = 1024 * 1024;

void main() {
  late Directory directory;
  late FakePreparationCodec codec;
  late FakeTranscoder transcoder;
  late MediaPreparer preparer;

  String path(String name) => '${directory.path}/$name';

  setUp(() {
    directory = Directory.systemTemp.createTempSync('mpx_prepare_test');
    File(path('silent.mp4')).writeAsBytesSync(List.filled(1234, 0));
    codec = FakePreparationCodec(
      stills: {
        path('photo.jpg'): const StillSource(
          dimensions: MediaDimensions(4032, 3024),
          byteSize: 3 * _mb,
          mimeType: 'image/jpeg',
        ),
        path('light.jpg'): const StillSource(
          dimensions: MediaDimensions(1200, 900),
          byteSize: 400000,
          mimeType: 'image/jpeg',
        ),
        path('small.png'): const StillSource(
          dimensions: MediaDimensions(800, 600),
          byteSize: 300000,
          mimeType: 'image/png',
        ),
        path('huge.jpg'): const StillSource(
          dimensions: MediaDimensions(6000, 4000),
          byteSize: 20 * _mb,
          mimeType: 'image/jpeg',
        ),
        path('anim.gif'): const StillSource(
          dimensions: MediaDimensions(480, 270),
          byteSize: 900000,
          mimeType: 'image/gif',
          animated: true,
        ),
      },
      videos: {path('clip.mp4'): const MediaDimensions(1280, 720)},
    );
    transcoder = FakeTranscoder(
      sources: {
        path('clip.mp4'): const SourceVideo(
          dimensions: MediaDimensions(1280, 720),
          duration: Duration(seconds: 5),
          codec: SourceCodec.h264,
          videoBitrate: 4000000,
        ),
        path('silent.mp4'): const SourceVideo(
          dimensions: MediaDimensions(640, 360),
          duration: Duration(seconds: 2),
          codec: SourceCodec.h264,
          videoBitrate: 900000,
          hasAudio: false,
        ),
      },
    );
    preparer = MediaPreparer(
      codec: codec,
      transcoder: transcoder,
      outputDirectory: directory.path,
    );
  });

  tearDown(() => directory.deleteSync(recursive: true));

  group('as photo', () {
    test(r'$IOS encodes 2560 px at 0.6 in high quality, thumbnail 320 at '
        '0.4', () async {
      final prepared = await preparer
          .prepare(
            PreparationInput(path('photo.jpg')),
            const PreparationIntent.photo(highQuality: true),
            PreparationPolicy.$IOS,
          )
          .result;
      expect(prepared.isOriginal, isFalse);
      expect(prepared.kind, PreparedKind.photo);
      expect(prepared.dimensions, const MediaDimensions(2560, 1920));
      expect(prepared.mimeType, 'image/jpeg');
      expect(File(prepared.path).existsSync(), isTrue);
      expect(prepared.byteSize, File(prepared.path).lengthSync());
      final encodes = codec.encodes;
      expect(
        encodes.where((e) => e.outputPath != null).single,
        isA<FakeStillEncode>()
            .having((e) => e.maxSide, 'maxSide', 2560)
            .having((e) => e.quality, 'quality', 60),
      );
      expect(
        encodes.where((e) => e.outputPath == null).single,
        isA<FakeStillEncode>()
            .having((e) => e.maxSide, 'maxSide', 320)
            .having((e) => e.quality, 'quality', 40),
      );
      expect(prepared.thumbnail, isNotEmpty);
      expect(prepared.thumbnailDimensions, const MediaDimensions(320, 240));
    });

    test(r'$Android encodes 1280 px at 80 with a progressive-free '
        'JPEG', () async {
      final prepared = await preparer
          .prepare(
            PreparationInput(path('photo.jpg')),
            const PreparationIntent.photo(),
            PreparationPolicy.$Android,
          )
          .result;
      expect(prepared.dimensions, const MediaDimensions(1280, 960));
      final encode = codec.encodes.firstWhere((e) => e.outputPath != null);
      expect(encode.quality, 80);
      expect(encode.progressive, isFalse);
    });

    test(r'$Desktop keeps a light JPEG', () async {
      final prepared = await preparer
          .prepare(
            PreparationInput(path('light.jpg')),
            const PreparationIntent.photo(),
            PreparationPolicy.$Desktop,
          )
          .result;
      expect(prepared.isOriginal, isTrue);
      expect(prepared.path, path('light.jpg'));
      expect(prepared.dimensions, const MediaDimensions(1200, 900));
      expect(codec.encodes.where((e) => e.outputPath != null), isEmpty);
      expect(prepared.thumbnail, isNotNull, reason: 'a thumbnail still');
    });

    test(r'$Web leaves a small PNG alone', () async {
      final prepared = await preparer
          .prepare(
            PreparationInput(path('small.png')),
            const PreparationIntent.photo(),
            PreparationPolicy.$Web,
          )
          .result;
      expect(prepared.isOriginal, isTrue);
      expect(prepared.mimeType, 'image/png');
    });

    test(r'$Web encodes again at 90 when the result passes 6 MB', () async {
      codec.encodedSize = (size, quality) => quality > 90 ? 7 * _mb : 5 * _mb;
      final prepared = await preparer
          .prepare(
            PreparationInput(path('huge.jpg')),
            const PreparationIntent.photo(),
            PreparationPolicy.$Web,
          )
          .result;
      final toFile = codec.encodes.where((e) => e.outputPath != null);
      expect(toFile.map((e) => e.quality), [92, 90]);
      expect(prepared.byteSize, 5 * _mb);
      expect(prepared.dimensions, const MediaDimensions(2560, 1707));
    });

    test('an animated still goes as it is', () async {
      final prepared = await preparer
          .prepare(
            PreparationInput(path('anim.gif')),
            const PreparationIntent.photo(),
            PreparationPolicy.$Android,
          )
          .result;
      expect(prepared.isOriginal, isTrue);
      expect(prepared.animated, isTrue);
    });

    test('a file that is not a still fails', () async {
      await expectLater(
        preparer
            .prepare(
              PreparationInput(path('clip.mp4')),
              const PreparationIntent.photo(),
              PreparationPolicy.$Android,
            )
            .result,
        throwsA(isA<CaptureFailed>()),
      );
    });
  });

  group('as video', () {
    test('compresses at the preset with a poster and reports '
        'progress', () async {
      final job = preparer.prepare(
        PreparationInput(path('clip.mp4')),
        const PreparationIntent.video(preset: CompressionPreset.tiny),
        PreparationPolicy.$Android,
      );
      final progress = <double>[];
      job.progress.listen(progress.add);
      final prepared = await job.result;
      expect(prepared.kind, PreparedKind.video);
      expect(prepared.isOriginal, isFalse);
      expect(prepared.dimensions, const MediaDimensions(432, 242));
      expect(prepared.duration, const Duration(seconds: 5));
      expect(prepared.hasAudio, isTrue);
      expect(prepared.animated, isFalse);
      expect(prepared.mimeType, 'video/mp4');
      expect(transcoder.requests.single.preset, CompressionPreset.tiny);
      expect(codec.posters.single, (path('clip.mp4'), 90, 55));
      expect(prepared.thumbnailDimensions, const MediaDimensions(90, 51));
      expect(progress, isNotEmpty);
      expect(progress.last, 1);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
    });

    test('without a preset the video goes as it is', () async {
      final prepared = await preparer
          .prepare(
            PreparationInput(path('silent.mp4')),
            const PreparationIntent.video(),
            PreparationPolicy.$Desktop,
          )
          .result;
      expect(prepared.isOriginal, isTrue);
      expect(prepared.path, path('silent.mp4'));
      expect(prepared.byteSize, 1234);
      expect(prepared.hasAudio, isFalse);
      expect(prepared.animated, isTrue, reason: 'a silent video loops');
      expect(transcoder.requests, isEmpty);
      expect(prepared.thumbnail, isNull, reason: 'the fake has no poster');
    });
  });

  group('as file', () {
    test('keeps the bytes and makes a thumbnail only', () async {
      final prepared = await preparer
          .prepare(
            PreparationInput(path('photo.jpg')),
            const PreparationIntent.file(),
            PreparationPolicy.$IOS,
          )
          .result;
      expect(prepared.kind, PreparedKind.file);
      expect(prepared.isOriginal, isTrue);
      expect(prepared.path, path('photo.jpg'));
      expect(prepared.dimensions, const MediaDimensions(4032, 3024));
      expect(prepared.thumbnail, isNotNull);
      expect(codec.encodes.single.outputPath, isNull);
    });

    test('a file that is no media has no thumbnail', () async {
      final prepared = await preparer
          .prepare(
            PreparationInput(path('notes.txt'), mimeType: 'text/plain'),
            const PreparationIntent.file(),
            PreparationPolicy.$Android,
          )
          .result;
      expect(prepared.isOriginal, isTrue);
      expect(prepared.thumbnail, isNull);
      expect(prepared.mimeType, 'text/plain');
    });
  });

  group('scheduling', () {
    test('prepares two items at a time', () async {
      codec.delay = const Duration(milliseconds: 20);
      final jobs = [
        for (var i = 0; i < 5; i++)
          preparer.prepare(
            PreparationInput(path('photo.jpg')),
            const PreparationIntent.photo(),
            PreparationPolicy.$Android,
          ),
      ];
      await Future.wait([for (final job in jobs) job.result]);
      expect(codec.maxConcurrent, 2);
    });

    test('a queued job cancels without starting', () async {
      codec.delay = const Duration(milliseconds: 20);
      final jobs = [
        for (var i = 0; i < 3; i++)
          preparer.prepare(
            PreparationInput(path('photo.jpg')),
            const PreparationIntent.photo(),
            PreparationPolicy.$Android,
          ),
      ];
      await jobs.last.cancel();
      await expectLater(jobs.last.result, throwsA(isA<CaptureCancelled>()));
      await Future.wait([jobs[0].result, jobs[1].result]);
      expect(codec.probes, hasLength(2));
    });

    test('a running compression cancels and leaves no file', () async {
      final slow = MediaPreparer(
        codec: codec,
        transcoder: FakeTranscoder(
          sources: transcoder.sources,
          stepDelay: const Duration(milliseconds: 20),
        ),
        outputDirectory: directory.path,
      );
      final job = slow.prepare(
        PreparationInput(path('clip.mp4')),
        const PreparationIntent.video(preset: CompressionPreset.low),
        PreparationPolicy.$Android,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await job.cancel();
      await expectLater(job.result, throwsA(isA<CaptureCancelled>()));
      await pumpEventQueue();
      expect(
        directory.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.mp4') && f.path.contains('prepared'),
        ),
        isEmpty,
      );
    });
  });
}
