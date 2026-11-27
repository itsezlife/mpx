import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _photo = StillSource(
  dimensions: MediaDimensions(4032, 3024),
  byteSize: 3 * 1024 * 1024,
  mimeType: 'image/jpeg',
);
const _clip = SourceVideo(
  dimensions: MediaDimensions(1280, 720),
  duration: Duration(seconds: 5),
  codec: SourceCodec.h264,
  videoBitrate: 4000000,
);

/// A codec and a transcoder that hold every call until the test lets it go,
/// counting what is in flight.
final class _Gate implements PreparationCodec, Transcoder {
  _Gate(this.directory);

  final Directory directory;
  final List<Completer<void>> _waiting = [];
  int stillsInFlight = 0;
  int videosInFlight = 0;
  int peakVideos = 0;
  int peakStills = 0;
  int started = 0;

  Future<void> _hold() {
    final gate = Completer<void>();
    _waiting.add(gate);
    return gate.future;
  }

  /// Lets every call held so far go, and waits for the next ones to hold.
  Future<void> release() async {
    final batch = [..._waiting];
    _waiting.clear();
    for (final gate in batch) {
      gate.complete();
    }
    await pump();
  }

  Future<void> pump() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<StillSource> probeStill(String path) async {
    started++;
    stillsInFlight++;
    if (stillsInFlight > peakStills) peakStills = stillsInFlight;
    await _hold();
    stillsInFlight--;
    return _photo;
  }

  @override
  Future<EncodedStill> encodeStill(
    String path, {
    required int maxSide,
    required int quality,
    bool progressive = false,
    String? outputPath,
  }) async {
    if (outputPath != null) File(outputPath).writeAsBytesSync([1, 2, 3]);
    return EncodedStill(
      dimensions: const MediaDimensions(10, 10),
      byteSize: 3,
      bytes: outputPath == null ? Uint8List.fromList([9, 9]) : null,
    );
  }

  @override
  Future<EncodedStill> videoThumbnail(String path, ThumbnailSpec spec) async =>
      EncodedStill(
        dimensions: const MediaDimensions(10, 10),
        byteSize: 2,
        bytes: Uint8List.fromList([9, 9]),
      );

  @override
  Future<SourceVideo> probe(String path) async {
    started++;
    videosInFlight++;
    if (videosInFlight > peakVideos) peakVideos = videosInFlight;
    await _hold();
    return _clip;
  }

  @override
  CaptureJob compress(TranscodeRequest request) {
    final job = CaptureJob(onCancel: () async {});
    File(request.outputPath).writeAsBytesSync([1, 2, 3]);
    videosInFlight--;
    job.complete(
      CaptureOutput(
        path: request.outputPath,
        size: 3,
        duration: _clip.duration,
        dimensions: const MediaDimensions(640, 360),
        headerRewritten: false,
        reencoded: true,
      ),
    );
    return job;
  }
}

void main() {
  late Directory directory;

  setUp(() => directory = Directory.systemTemp.createTempSync('mpx_prep'));
  tearDown(() => directory.deleteSync(recursive: true));

  CaptureMediaPreparation over(
    _Gate gate, {
    PreparationPolicy policy = PreparationPolicy.$IOS,
  }) => CaptureMediaPreparation(
    preparer: MediaPreparer(
      codec: gate,
      transcoder: gate,
      outputDirectory: directory.path,
    ),
    policy: policy,
  );

  const video = PreparationIntent.video(preset: CompressionPreset.low);
  const photo = PreparationIntent.photo();

  group('limits', () {
    test('the default video limit is 1 and the general limit 2', () {
      for (final policy in [
        PreparationPolicy.$Android,
        PreparationPolicy.$IOS,
        PreparationPolicy.$Desktop,
        PreparationPolicy.$Web,
      ]) {
        expect(policy.videoConcurrency, 1);
        expect(policy.concurrency, 2);
      }
    });

    test('two videos prepare one after the other', () async {
      final gate = _Gate(directory);
      final preparation = over(gate);
      final first = preparation.prepare(
        const PreparationInput('/a.mp4'),
        video,
      );
      final second = preparation.prepare(
        const PreparationInput('/b.mp4'),
        video,
      );
      await gate.pump();

      expect(gate.videosInFlight, 1);
      expect(gate.started, 1);

      await gate.release();
      await first.result;
      await gate.pump();
      expect(gate.started, 2);
      await gate.release();
      await second.result;
      expect(gate.peakVideos, 1);
    });

    test('a still and a video run side by side', () async {
      final gate = _Gate(directory);
      final preparation = over(gate);
      preparation.prepare(const PreparationInput('/a.mp4'), video);
      preparation.prepare(const PreparationInput('/a.jpg'), photo);
      await gate.pump();

      expect(gate.videosInFlight, 1);
      expect(gate.stillsInFlight, 1);
    });

    test(
      'a still waits behind no video that waits for the video slot',
      () async {
        final gate = _Gate(directory);
        final preparation = over(gate);
        preparation.prepare(const PreparationInput('/a.mp4'), video);
        preparation.prepare(const PreparationInput('/b.mp4'), video);
        preparation.prepare(const PreparationInput('/a.jpg'), photo);
        await gate.pump();

        expect(gate.videosInFlight, 1);
        expect(gate.stillsInFlight, 1);
      },
    );

    test('three stills run two at a time', () async {
      final gate = _Gate(directory);
      final preparation = over(gate);
      for (final name in ['a', 'b', 'c']) {
        preparation.prepare(PreparationInput('/$name.jpg'), photo);
      }
      await gate.pump();
      expect(gate.stillsInFlight, 2);

      await gate.release();
      await gate.release();
      expect(gate.peakStills, 2);
      expect(gate.started, 3);
    });

    test('a host override of the video limit to 2 runs two at once', () async {
      final gate = _Gate(directory);
      final preparation = over(
        gate,
        policy: const PreparationPolicy(
          stills: StillRule.alwaysEncode(
            side: 1280,
            highQualitySide: 2560,
            quality: 60,
            highQualityQuality: 60,
          ),
          thumbnail: ThumbnailSpec(side: 320, quality: 40),
          video: VideoRule.none(),
          videoConcurrency: 2,
        ),
      );
      preparation.prepare(const PreparationInput('/a.mp4'), video);
      preparation.prepare(const PreparationInput('/b.mp4'), video);
      await gate.pump();

      expect(gate.videosInFlight, 2);
    });

    test('a cancelled running video frees its slot', () async {
      final gate = _Gate(directory);
      final preparation = over(gate);
      final first = preparation.prepare(
        const PreparationInput('/a.mp4'),
        video,
      );
      preparation.prepare(const PreparationInput('/b.mp4'), video);
      await gate.pump();

      await first.cancel();
      await gate.release();
      await gate.pump();

      expect(gate.started, 2);
    });
  });

  group('the thumbnail file', () {
    test('is written beside the outputs and named by the item', () async {
      final gate = _Gate(directory);
      final handle = over(
        gate,
      ).prepare(const PreparationInput('/a.mp4'), video);
      await gate.pump();
      await gate.release();
      final media = await handle.result;

      expect(media.thumbnailPath, isNotNull);
      expect(File(media.thumbnailPath!).readAsBytesSync(), [9, 9]);
      expect(File(media.thumbnailPath!).parent.path, directory.path);
    });

    test('is deleted with a cancelled item', () async {
      final gate = _Gate(directory);
      final handle = over(
        gate,
      ).prepare(const PreparationInput('/a.mp4'), video);
      await gate.pump();
      await handle.cancel();
      await gate.release();
      await gate.pump();

      expect(directory.listSync(), isEmpty);
    });
  });

  group('diagnostics', () {
    test('a queued video says it waits for the video slot', () async {
      final recording = RecordingDiagnostics.install();
      final gate = _Gate(directory);
      final preparation = over(gate);
      preparation.prepare(const PreparationInput('/a.mp4'), video);
      preparation.prepare(const PreparationInput('/b.mp4'), video);
      preparation.prepare(const PreparationInput('/a.jpg'), photo);

      final queued = recording.whereOp(PreparationOp.queued);
      expect(queued.map((event) => event.fields['waitingForVideoSlot']), [
        false,
        true,
        null,
      ]);
      expect(queued.map((event) => event.fields['kind']), [
        'video',
        'video',
        'photo',
      ]);
    });

    test('an item reports started, progress and finished', () async {
      final recording = RecordingDiagnostics.install();
      final gate = _Gate(directory);
      final handle = over(
        gate,
      ).prepare(const PreparationInput('/a.mp4'), video);
      await gate.pump();
      await gate.release();
      await handle.result;

      expect(recording.events.map((event) => event.op), [
        PreparationOp.queued,
        PreparationOp.started,
        PreparationOp.progress,
        PreparationOp.progress,
        PreparationOp.finished,
      ]);
      expect(
        recording.whereOp(PreparationOp.finished).single.fields,
        containsPair('bytes', 3),
      );
      expect(recording.errors, isEmpty);
    });

    test('a failure reports a code and no path', () async {
      final recording = RecordingDiagnostics.install();
      final codec = FakePreparationCodec();
      final handle = CaptureMediaPreparation(
        preparer: MediaPreparer(
          codec: codec,
          transcoder: FakeTranscoder(),
          outputDirectory: directory.path,
        ),
        policy: PreparationPolicy.$IOS,
      ).prepare(const PreparationInput('/secret/name.jpg'), photo);

      await expectLater(handle.result, throwsA(isA<PreparationFailed>()));

      final failed = recording.whereOp(PreparationOp.failed).single;
      expect(failed.level, MpxEventLevel.error);
      expect(failed.fields['code'], 'unreadable');
      expect('${failed.fields}', isNot(contains('secret')));
      expect(recording.errors, hasLength(1));
    });

    test('a cancel reports cancelled, not failed', () async {
      final recording = RecordingDiagnostics.install();
      final gate = _Gate(directory);
      final handle = over(
        gate,
      ).prepare(const PreparationInput('/a.mp4'), video);
      await handle.cancel();
      await gate.release();
      await gate.pump();

      expect(recording.whereOp(PreparationOp.cancelled), hasLength(1));
      expect(recording.whereOp(PreparationOp.failed), isEmpty);
    });
  });
}
