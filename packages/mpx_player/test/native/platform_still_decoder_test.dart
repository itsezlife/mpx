import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart' show DecoderContract, DecoderHarness;
import 'package:mpx_player/native.dart';
import 'package:mpx_player/src/native/player_messages.g.dart';
import 'package:mpx_player/testing.dart';

const _clip = MediaDescriptor(
  key: MediaKey.remote('clip'),
  kind: MediaKind.video,
  animated: true,
);

const _spec = AssetSpec(pixelWidth: 120, pixelHeight: 80);

/// Everything a decode reported.
final class _Report implements AssetProgress {
  final List<({AssetStage stage, AssetPaintable paintable, int bytes})>
  advances = [];
  final List<Object> failures = [];
  final List<AssetFailureKind> kinds = [];

  @override
  void advance(
    AssetStage stage,
    AssetPaintable paintable, {
    required int bytes,
    AssetTier tier = AssetTier.still,
  }) => advances.add((stage: stage, paintable: paintable, bytes: bytes));

  @override
  void fail(
    Object error, [
    StackTrace? stackTrace,
    AssetFailureKind kind = AssetFailureKind.transient,
  ]) {
    failures.add(error);
    kinds.add(kind);
  }

  @override
  void bestReached() {}

  @override
  void cancelled() {}

  @override
  void describe(MediaDescriptor descriptor) {}

  @override
  void waiting() {}

  @override
  void transfer(int received, int? total) {}

  @override
  void awaitingUser() {}
}

/// Content that counts its releases.
final class _Released {
  int count = 0;

  FetchedContent ranged(String key) =>
      FetchedContent.ranged(readerApi: 42, key: key, onRelease: () => count++);

  FetchedContent file(String path) =>
      FetchedContent.file(path, onRelease: () => count++);
}

DecodeRequest _request(
  FetchedContent content, {
  FetchPart part = FetchPart.content,
}) =>
    DecodeRequest(descriptor: _clip, spec: _spec, part: part, content: content);

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakePlatformStillBackend backend;
  late PlatformStillDecoder decoder;
  late _Released released;

  setUp(() {
    backend = FakePlatformStillBackend();
    decoder = PlatformStillDecoder.over(backend);
    released = _Released();
  });

  test('draws the first frame of a ranged resource through the reader, '
      'within the spec, as the final still', () async {
    final report = _Report();

    decoder.decode(_request(released.ranged('clip-key')), report);
    await _until(() => report.advances.isNotEmpty);

    final asked = backend.requests.single;
    expect(
      asked.source,
      const PlatformStillSource.ranged(readerApi: 42, key: 'clip-key'),
    );
    expect((asked.maxWidth, asked.maxHeight), (120, 80));
    final advance = report.advances.single;
    expect(advance.stage, AssetStage.firstFrame);
    expect(advance.bytes, 120 * 80 * 4);
    expect(advance.paintable.pictureSize, const Size(120, 80));
    expect(advance.paintable.isAnimated, isFalse);
    expect(released.count, 1);
    expect(report.failures, isEmpty);
  });

  test('reads a file in place', () async {
    final report = _Report();

    decoder.decode(_request(released.file('/cache/clip.mp4')), report);
    await _until(() => report.advances.isNotEmpty);

    expect(
      backend.requests.single.source,
      const PlatformStillSource.file('/cache/clip.mp4'),
    );
    expect(released.count, 1);
  });

  test('never takes content in memory: no file is loaded whole', () async {
    final report = _Report();

    decoder.decode(
      _request(FetchedContent.bytes(Uint8List.fromList([1, 2, 3]))),
      report,
    );
    await _until(() => report.failures.isNotEmpty);

    expect(backend.requests, isEmpty);
    expect(report.kinds.single, AssetFailureKind.permanent);
  });

  test('draws no thumbnail: it is a fallback for content', () async {
    final report = _Report();

    decoder.decode(
      _request(released.file('/cache/thumb.jpg'), part: FetchPart.thumbnail),
      report,
    );
    await _until(() => report.failures.isNotEmpty);

    expect(backend.requests, isEmpty);
    expect(report.failures, hasLength(1));
    expect(released.count, 1);
  });

  test('a video the platform cannot draw either fails as unsupported, for '
      'good', () async {
    backend.unreadable.add('broken');
    final report = _Report();

    decoder.decode(_request(released.ranged('broken')), report);
    await _until(() => report.failures.isNotEmpty);

    expect(report.failures.single, isA<DecodeFailure>());
    expect(report.kinds.single, AssetFailureKind.permanent);
    expect(report.advances, isEmpty);
    expect(released.count, 1);
  });

  test('a cancel wakes the platform\'s reads and reports nothing; the '
      'content is given back once the platform lets go of it', () async {
    backend.hold = true;
    final report = _Report();

    final task = decoder.decode(_request(released.ranged('slow')), report);
    await _until(() => backend.requests.isNotEmpty);
    task.cancel();

    expect(backend.cancelled, [backend.requests.single]);
    expect(released.count, 0, reason: 'the platform may still be reading');

    backend.answerHeld();
    await _until(() => released.count == 1);

    expect(released.count, 1);
    expect(report.advances, isEmpty);
    expect(report.failures, isEmpty);
  });

  DecoderContract.run(
    () => DecoderHarness(
      decoder: PlatformStillDecoder.over(
        FakePlatformStillBackend()..unreadable.add('broken'),
      ),
      valid: (part, spec) => DecodeRequest(
        descriptor: _clip,
        spec: spec,
        part: part,
        content: const FetchedContent.ranged(readerApi: 42, key: 'clip'),
      ),
      invalid: () => const DecodeRequest(
        descriptor: _clip,
        spec: _spec,
        part: FetchPart.content,
        content: FetchedContent.ranged(readerApi: 42, key: 'broken'),
      ),
    ),
    stillsOnly: true,
  );

  group('over the platform channel', () {
    const prefix = 'dev.flutter.pigeon.mpx_player.PlayerStillHostApi';
    const codec = PlayerStillHostApi.pigeonChannelCodec;
    final extracts = <int>[];
    final cancels = <int>[];
    final answers = <Completer<ByteData?>>[];

    setUp(() {
      final messenger =
          TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
      extracts.clear();
      cancels.clear();
      answers.clear();
      messenger
        ..setMockMessageHandler('$prefix.extractStill', (message) {
          final args = codec.decodeMessage(message)! as List<Object?>;
          extracts.add((args.single! as NativeStillRequest).requestId);
          final answer = Completer<ByteData?>();
          answers.add(answer);
          return answer.future;
        })
        ..setMockMessageHandler('$prefix.cancelStill', (message) async {
          final args = codec.decodeMessage(message)! as List<Object?>;
          cancels.add(args.single! as int);
          return codec.encodeMessage(<Object?>[null]);
        });
      addTearDown(
        () => messenger
          ..setMockMessageHandler('$prefix.extractStill', null)
          ..setMockMessageHandler('$prefix.cancelStill', null),
      );
    });

    test('two decoders never name their requests alike, so a cancel of one '
        'wakes only its own', () async {
      final first = PlatformStillDecoder();
      final second = PlatformStillDecoder();
      final firstReport = _Report();
      final secondReport = _Report();

      final task = first.decode(_request(released.ranged('a')), firstReport);
      second.decode(_request(released.ranged('b')), secondReport);
      await _until(() => extracts.length == 2);
      task.cancel();
      await _until(() => cancels.isNotEmpty);

      expect(extracts.toSet(), hasLength(2));
      expect(cancels, [extracts.first]);

      for (final answer in answers) {
        answer.complete(codec.encodeMessage(<Object?>[null]));
      }
      await _until(() => released.count == 2);
      expect(released.count, 2);
    });
  });
}
