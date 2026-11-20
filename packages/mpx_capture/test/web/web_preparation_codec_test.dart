/// The web still encoder in a real browser:
/// `flutter test --platform chrome test/web`. The VM gate skips it
/// (`@TestOn`), and `unit_test.dart` does not import it: `package:web`
/// does not compile for the VM.
@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';
import 'package:web/web.dart' as web;

Future<String> _pngUrl(int width, int height) async {
  final canvas = web.OffscreenCanvas(width, height);
  final context =
      canvas.getContext('2d')! as web.OffscreenCanvasRenderingContext2D;
  context
    ..fillStyle = 'rgb(200, 30, 30)'.toJS
    ..fillRect(0, 0, width, height);
  final blob = await canvas
      .convertToBlob(web.ImageEncodeOptions(type: 'image/png'))
      .toDart;
  return web.URL.createObjectURL(blob);
}

void main() {
  const codec = WebPreparationCodec();

  test('probes and encodes a picked blob within the side', () async {
    final url = await _pngUrl(3000, 2000);
    final still = await codec.probeStill(url);
    expect(still.dimensions.width, 3000);
    expect(still.mimeType, 'image/png');

    final encoded = await codec.encodeStill(url, maxSide: 2560, quality: 90);
    expect(encoded.dimensions.width, 2560);
    expect(encoded.dimensions.height, 1707);
    expect(encoded.bytes, isNotEmpty);
    expect(encoded.bytes![0], 0xFF, reason: 'a JPEG');
    expect(encoded.bytes![1], 0xD8);
  });

  test('the web policy keeps a small PNG, end to end', () async {
    final url = await _pngUrl(800, 600);
    final prepared =
        await MediaPreparer(
              codec: codec,
              transcoder: FakeTranscoder(),
              outputDirectory: 'memory',
            )
            .prepare(
              PreparationInput(url, mimeType: 'image/png'),
              const PreparationIntent.photo(),
              PreparationPolicy.$Web,
            )
            .result;
    expect(prepared.isOriginal, isTrue);
    expect(prepared.thumbnail, isNotEmpty);
  });

  test('a blob that is no picture fails the probe', () async {
    final url = web.URL.createObjectURL(
      web.Blob(['hello'.toJS].toJS, web.BlobPropertyBag(type: 'text/plain')),
    );
    await expectLater(codec.probeStill(url), throwsA(isA<CaptureFailed>()));
  });
}
