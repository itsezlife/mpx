import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_svg/mpx_svg.dart';

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

/// A [width] x [height] document: blue on the left half, red on the right.
Uint8List _halves(num width, num height) => _utf8(
  '<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height" '
  'viewBox="0 0 $width $height"> '
  '<rect width="${width / 2}" height="$height" fill="#0000ff"/> '
  '<rect x="${width / 2}" width="${width / 2}" height="$height" '
  'fill="#ff0000"/></svg>',
);

const MediaKey _key = MediaKey.remote('drawing');

DecodeRequest _request(
  FetchedContent content, {
  AssetSpec spec = const AssetSpec(pixelWidth: 64, pixelHeight: 64),
  FetchPart part = FetchPart.content,
  MediaKey key = _key,
}) => DecodeRequest(
  descriptor: MediaDescriptor(key: key, kind: MediaKind.vectorImage),
  spec: spec,
  part: part,
  content: content,
);

/// What one decode reported.
final class _Progress implements AssetProgress {
  final List<(AssetStage, AssetPaintable, int)> advances = [];
  Object? error;
  AssetFailureKind? failure;
  final Completer<void> _done = Completer();

  Future<void> get done => _done.future.timeout(const Duration(seconds: 10));

  @override
  void advance(
    AssetStage stage,
    AssetPaintable paintable, {
    required int bytes,
    AssetTier tier = AssetTier.still,
  }) {
    expect(tier, AssetTier.still);
    advances.add((stage, paintable, bytes));
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void fail(
    Object error, [
    StackTrace? stackTrace,
    AssetFailureKind kind = AssetFailureKind.transient,
  ]) {
    this.error = error;
    failure = kind;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void describe(MediaDescriptor descriptor) {}
  @override
  void waiting() {}
  @override
  void transfer(int received, int? total) {}
  @override
  void awaitingUser() {}
  @override
  void cancelled() {}
  @override
  void bestReached() {}
}

Future<_Progress> _decode(SvgDecoder decoder, DecodeRequest request) async {
  final progress = _Progress();
  decoder.decode(request, progress);
  await progress.done;
  return progress;
}

/// The RGBA of [paintable] drawn into a [width] x [height] image.
Future<ByteData> _pixels(
  AssetPaintable paintable,
  int width,
  int height, {
  ui.Color? tint,
  AssetFit fit = AssetFit.contain,
}) async {
  final recorder = ui.PictureRecorder();
  paintable.paint(
    ui.Canvas(recorder),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    AssetPaintContext(tint: tint, fit: fit),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = (await image.toByteData())!;
  image.dispose();
  return data;
}

(int, int, int, int) _rgbaAt(ByteData pixels, int width, int x, int y) {
  final at = (y * width + x) * 4;
  return (
    pixels.getUint8(at),
    pixels.getUint8(at + 1),
    pixels.getUint8(at + 2),
    pixels.getUint8(at + 3),
  );
}

void main() {
  DecoderContract.run(
    () => DecoderHarness(
      decoder: SvgDecoder(),
      valid: (part, spec) => _request(
        FetchedContent.bytes(_halves(10, 10)),
        part: part,
        spec: spec,
      ),
      invalid: () => _request(FetchedContent.bytes(_utf8('not svg'))),
    ),
  );

  test(
    'draws the document covering the spec, scaled up as well as down, '
    'keeping its aspect, so either fit a view paints it in is sharp',
    () async {
      final decoder = SvgDecoder();

      final wide = await _decode(
        decoder,
        _request(
          FetchedContent.bytes(_halves(100, 50)),
          key: const MediaKey.remote('wide'),
        ),
      );
      final small = await _decode(
        decoder,
        _request(
          FetchedContent.bytes(_halves(24, 24)),
          key: const MediaKey.remote('small'),
          spec: const AssetSpec(pixelWidth: 96, pixelHeight: 96),
        ),
      );

      final (_, widePicture, wideBytes) = wide.advances.single;
      // 100 x 50 covering 64 x 64: 128 x 64.
      expect(widePicture.pictureSize, const ui.Size(128, 64));
      expect(wideBytes, 128 * 64 * 4);
      // A cover view shows the middle 64 px at one pixel per pixel: the blue
      // half ends at the centre. A contain view shows it whole, bars above and
      // below.
      final cover = await _pixels(widePicture, 64, 64, fit: AssetFit.cover);
      expect(_rgbaAt(cover, 64, 30, 32), (0, 0, 255, 255));
      expect(_rgbaAt(cover, 64, 33, 32), (255, 0, 0, 255));
      expect(_rgbaAt(cover, 64, 32, 0).$4, 255);
      final contain = await _pixels(widePicture, 64, 64);
      expect(_rgbaAt(contain, 64, 32, 4).$4, 0);
      expect(_rgbaAt(contain, 64, 10, 32), (0, 0, 255, 255));
      final (_, smallPicture, _) = small.advances.single;
      expect(smallPicture.pictureSize, const ui.Size(96, 96));
      final pixels = await _pixels(smallPicture, 96, 96);
      expect(_rgbaAt(pixels, 96, 10, 48), (0, 0, 255, 255));
      expect(_rgbaAt(pixels, 96, 86, 48), (255, 0, 0, 255));
    },
  );

  test('a thumbnail is a placeholder; a first-frame spec ends at the first '
      'frame', () async {
    final decoder = SvgDecoder();

    final thumbnail = await _decode(
      decoder,
      _request(
        FetchedContent.bytes(_halves(10, 10)),
        part: FetchPart.thumbnail,
      ),
    );
    final first = await _decode(
      decoder,
      _request(
        FetchedContent.bytes(_halves(10, 10)),
        spec: const AssetSpec(
          pixelWidth: 64,
          pixelHeight: 64,
          variant: AssetVariant.firstFrame,
        ),
      ),
    );

    expect(thumbnail.advances.single.$1, AssetStage.placeholder);
    expect(first.advances.single.$1, AssetStage.firstFrame);
  });

  test(
    'the long edge never passes the limits, whatever the spec asks',
    () async {
      final decoder = SvgDecoder(
        limits: SvgLimits.standard.copyWith(maxPixelEdge: 100),
      );

      final report = await _decode(
        decoder,
        _request(
          FetchedContent.bytes(_halves(10, 20)),
          spec: const AssetSpec(pixelWidth: 1000, pixelHeight: 1000),
        ),
      );

      expect(report.advances.single.$2.pictureSize, const ui.Size(50, 100));
    },
  );

  test('a template spec is tinted at paint', () async {
    final report = await _decode(
      SvgDecoder(),
      _request(
        FetchedContent.bytes(_halves(10, 10)),
        spec: const AssetSpec(
          pixelWidth: 10,
          pixelHeight: 10,
          decodeMode: AssetDecodeMode.template,
        ),
      ),
    );

    final pixels = await _pixels(
      report.advances.single.$2,
      10,
      10,
      tint: const ui.Color(0xFF00FF00),
    );
    expect(_rgbaAt(pixels, 10, 2, 5), (0, 255, 0, 255));
    expect(_rgbaAt(pixels, 10, 8, 5), (0, 255, 0, 255));
  });

  test('a refused document fails permanently with the rejection', () async {
    final scripted = await _decode(
      SvgDecoder(),
      _request(
        FetchedContent.bytes(
          _utf8('<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>'),
        ),
      ),
    );
    final oversized = await _decode(
      SvgDecoder(limits: SvgLimits.standard.copyWith(maxInputBytes: 16)),
      _request(FetchedContent.bytes(_halves(10, 10))),
    );

    expect(scripted.failure, AssetFailureKind.permanent);
    expect(
      (scripted.error! as SvgRejection).reason,
      SvgRejectionReason.element,
    );
    expect(
      (oversized.error! as SvgRejection).reason,
      SvgRejectionReason.tooLarge,
    );
    expect(scripted.advances, isEmpty);
  });

  test('a document that gives one edge only fills the spec\'s proportion '
      'on the other, as a browser fills its box', () async {
    final report = await _decode(
      SvgDecoder(),
      _request(
        FetchedContent.bytes(
          _utf8(
            '<svg xmlns="http://www.w3.org/2000/svg" height="20"> '
            '<rect width="5" height="5"/></svg>',
          ),
        ),
        spec: const AssetSpec(pixelWidth: 64, pixelHeight: 32),
      ),
    );

    expect(report.advances.single.$2.pictureSize, const ui.Size(64, 32));
  });

  test('a document that declares no size to draw at fails', () async {
    final report = await _decode(
      SvgDecoder(),
      _request(
        FetchedContent.bytes(
          _utf8(
            '<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0"> '
            '<rect width="1" height="1"/></svg>',
          ),
        ),
      ),
    );

    expect(report.failure, AssetFailureKind.permanent);
    expect(report.advances, isEmpty);
  });

  test('a file is drawn and released once; a ranged resource is refused '
      'and released', () async {
    final directory = Directory.systemTemp.createTempSync('mpx_svg_test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/a.svg')
      ..writeAsBytesSync(_halves(10, 10));
    var fileReleases = 0;
    var rangedReleases = 0;

    final drawn = await _decode(
      SvgDecoder(),
      _request(FetchedContent.file(file.path, onRelease: () => fileReleases++)),
    );
    final ranged = await _decode(
      SvgDecoder(),
      _request(
        FetchedContent.ranged(
          readerApi: 0,
          key: 'a',
          onRelease: () => rangedReleases++,
        ),
      ),
    );

    expect(drawn.advances.single.$1, AssetStage.full);
    expect(fileReleases, 1);
    expect(ranged.failure, AssetFailureKind.permanent);
    expect(rangedReleases, 1);
  });

  test('the same content at another size is drawn from the form compiled '
      'the first time', () async {
    final decoder = SvgDecoder();
    await _decode(decoder, _request(FetchedContent.bytes(_halves(10, 10))));

    // Content under one key never changes, so the bytes are not read again:
    // were they compiled, these would fail.
    final again = await _decode(
      decoder,
      _request(
        FetchedContent.bytes(_utf8('not svg')),
        spec: const AssetSpec(pixelWidth: 32, pixelHeight: 32),
      ),
    );

    expect(again.advances.single.$2.pictureSize, const ui.Size(32, 32));
  });

  test(
    'a decoder that keeps no compiled forms compiles every request',
    () async {
      final decoder = SvgDecoder(
        limits: SvgLimits.standard.copyWith(compiledCacheBytes: 0),
      );
      await _decode(decoder, _request(FetchedContent.bytes(_halves(10, 10))));

      final again = await _decode(
        decoder,
        _request(FetchedContent.bytes(_utf8('not svg'))),
      );

      expect(again.failure, AssetFailureKind.permanent);
    },
  );
}
