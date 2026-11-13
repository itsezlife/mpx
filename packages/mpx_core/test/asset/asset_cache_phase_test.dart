import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _key = MediaKey.remote('anim-1');
// A list item's decode and the fullscreen copy of it: one content, two
// entries.
const _item = AssetSpec(pixelWidth: 200, pixelHeight: 200);
const _full = AssetSpec(pixelWidth: 1080, pixelHeight: 1080);
const _plays = AssetProfile(animate: true);

Duration _ms(int ms) => Duration(milliseconds: ms);

// Four frames of 100 ms: the frame shown says the time into the pass.
final _frames = [_ms(100), _ms(100), _ms(100), _ms(100)];

void main() {
  late FakeAssetProducer producer;
  late ManualPlaybackTickSource ticks;
  late AssetCacheScope scope;

  setUp(() {
    producer = FakeAssetProducer();
    ticks = ManualPlaybackTickSource();
    scope = AssetCacheScope(
      producer: producer,
      clock: PlaybackClock(ticks: ticks),
    );
  });
  tearDown(() => scope.dispose());

  void paint(AssetBinding binding) {
    final recorder = PictureRecorder();
    binding.paint(Canvas(recorder), const Rect.fromLTWH(0, 0, 8, 8));
    recorder.endRecording().dispose();
  }

  // Ticks the clock at [ms] and paints [bindings] there.
  void at(int ms, List<AssetBinding> bindings) {
    ticks.tick(_ms(ms));
    bindings.forEach(paint);
  }

  (AssetBinding, FakeAssetPaintable) playing(AssetSpec spec) {
    final binding = scope.attach(_key, spec, _plays);
    final paintable = producer
        .attemptsFor(AssetRequest(_key, spec))
        .last
        .advance(AssetStage.full, tier: AssetTier.animated, frames: _frames);
    return (binding, paintable);
  }

  group('entries of one content that play at once share a phase', () {
    test('an entry that starts while another plays starts at its frame', () {
      final (item, itemFrames) = playing(_item);
      at(0, [item]);
      at(250, [item]);
      expect(itemFrames.frameShown, 2);

      final (full, fullFrames) = playing(_full);
      at(266, [item, full]);

      expect(fullFrames.frameShown, 2);
      at(316, [item, full]);
      expect(fullFrames.frameShown, itemFrames.frameShown);
      expect(fullFrames.frameShown, 3);
    });

    test('an entry drawn over while the other plays comes back in step', () {
      final (item, itemFrames) = playing(_item);
      at(0, [item]);
      final (full, fullFrames) = playing(_full);
      at(16, [item, full]);

      // The item is still on the clock but nothing paints it: the full copy
      // covers it.
      for (var ms = 32; ms <= 1424; ms += 16) {
        at(ms, [full]);
      }
      at(1440, [full, item]);

      expect(itemFrames.frameShown, fullFrames.frameShown);
      expect(itemFrames.frameShown, 2, reason: '1440 ms is 240 ms into a pass');
    });

    test('an entry comes back where the other one stopped, once that one '
        'left', () {
      final (item, itemFrames) = playing(_item);
      at(0, [item]);
      final (full, fullFrames) = playing(_full);
      for (var ms = 16; ms <= 1456; ms += 16) {
        at(ms, [full]);
      }
      expect(fullFrames.frameShown, 2);

      full.detach();
      at(1472, []);
      at(2000, [item]);

      expect(
        itemFrames.frameShown,
        2,
        reason: 'the full copy stopped 256 ms into its pass',
      );
    });

    test('a held entry goes on from its own frame when its hold ends', () {
      final (item, itemFrames) = playing(_item);
      at(0, [item]);
      at(150, [item]);
      expect(itemFrames.frameShown, 1);

      item.held = true;
      final (full, _) = playing(_full);
      for (var ms = 166; ms <= 366; ms += 16) {
        at(ms, [full]);
      }
      item.held = false;
      at(382, [item]);

      expect(itemFrames.frameShown, 1, reason: 'freeze and continue');
    });

    test('another content keeps its own phase', () {
      final (item, itemFrames) = playing(_item);
      at(0, [item]);
      at(250, [item]);

      final other = scope.attach(
        const MediaKey.remote('anim-2'),
        _full,
        _plays,
      );
      final otherFrames = producer.last.advance(
        AssetStage.full,
        tier: AssetTier.animated,
        frames: _frames,
      );
      at(266, [item, other]);

      expect(otherFrames.frameShown, 0);
      expect(itemFrames.frameShown, 2);
    });
  });
}
