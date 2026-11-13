import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

Duration _ms(int ms) => Duration(milliseconds: ms);

void main() {
  test('by default a seek to zero rewinds, any other does nothing, and the '
      'picture handed is disposed', () {
    final paintable = _Rewinding();
    final recorder = PictureRecorder();
    Canvas(recorder);
    final picture = recorder.endRecording().toImageSync(1, 1);

    paintable.seekPlayback(_ms(300), picture: picture);
    expect(paintable.rewinds, 0);
    expect(picture.debugDisposed, isTrue);

    paintable.seekPlayback(Duration.zero);
    expect(paintable.rewinds, 1);
  });

  AssetPlaybackContract.run(() {
    final fake = FakeAssetPaintable(
      frameDurations: [_ms(40), _ms(60), _ms(80)],
    );
    return AssetPlaybackHarness(
      paintable: fake,
      frameDurations: fake.frameDurations,
      frameAt:
          (
            time, {
            animate = true,
            loop = false,
            rest = AssetRestFrame.first,
          }) async {
            AssetPlaybackContract.paintOnce(
              fake,
              time,
              animate: animate,
              loop: loop,
              rest: rest,
            );
            return fake.frameShown;
          },
    );
  });
}

/// Counts what the base class's playback seams do.
final class _Rewinding extends AssetPaintable {
  int rewinds = 0;

  @override
  AtlasSprite? get sprite => null;

  @override
  bool get isAnimated => true;

  @override
  bool get isHolding => false;

  @override
  bool restart() => false;

  @override
  void rewind() => rewinds++;

  @override
  void paint(Canvas canvas, Rect rect, AssetPaintContext context) {}

  @override
  void dispose() {}
}
