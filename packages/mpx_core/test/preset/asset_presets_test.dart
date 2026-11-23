import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

void main() {
  group('frame step', () {
    test('half rate shows every second frame of a source above 30 fps', () {
      const half = AssetPaintContext(halfFrameRate: true);

      expect(half.frameStepFor(60), 2);
      expect(half.frameStepFor(59.94), 2);
      expect(half.frameStepFor(30), 1);
      expect(half.frameStepFor(24), 1);
      expect(half.frameStepFor(0), 1);
    });

    test('full rate shows every frame', () {
      const full = AssetPaintContext();

      expect(full.frameStepFor(60), 1);
    });
  });

  group('animation', () {
    test('decodes at one size whatever the box, so a thumbnail and the '
        'fullscreen copy share one entry and one playback', () {
      const plays = AssetProfile(animate: true);
      final card = AssetPresets.animation(
        size: const Size(160, 160),
        profile: plays,
      );
      final viewer = AssetPresets.animation(
        size: const Size(400, 300),
        profile: const AssetProfile(animate: true, fit: AssetFit.cover),
      );

      expect(card.spec, viewer.spec);
      expect(
        card.spec,
        const AssetSpec(
          pixelWidth: AssetPresets.animationPixelExtent,
          pixelHeight: AssetPresets.animationPixelExtent,
        ),
      );
      expect(card.size, const Size(160, 160));
      expect(viewer.size, const Size(400, 300));
      expect(viewer.profile.fit, AssetFit.cover);
    });
  });

  group('square', () {
    test('decodes an explicit extent at the density, on its rung, with the '
        'given profile', () {
      final preset = AssetPresets.square(
        extent: 40,
        devicePixelRatio: 2.5,
        profile: const AssetProfile(animate: true, loop: false),
      );

      // 100 px: the rungs near it are 80 and 103 (128 x 4/5, rounded up).
      expect(preset.size, const Size(40, 40));
      expect(preset.spec.pixelWidth, 103);
      expect(preset.spec.pixelHeight, 103);
      expect(preset.profile, const AssetProfile(animate: true, loop: false));
    });
  });

  group('size ladder', () {
    test('a box a few pixels wider asks for the same decode', () {
      AssetSpec specAt(double width) => AssetPresets.media(
        size: Size(width, width * 0.6),
        devicePixelRatio: 1,
        profile: const AssetProfile(),
      ).spec;

      expect({for (var w = 1000.0; w <= 1020; w++) specAt(w)}, hasLength(1));
    });

    test('rounds each side up to its rung', () {
      // Rungs near 330 px: 320, 410 (512 x 4/5, rounded up); near 200 px:
      // 160, 205 (256 x 4/5, rounded up).
      final preset = AssetPresets.media(
        size: const Size(330, 200),
        devicePixelRatio: 1,
        profile: const AssetProfile(),
      );

      expect(preset.size, const Size(330, 200));
      expect((preset.spec.pixelWidth, preset.spec.pixelHeight), (410, 205));
    });

    test('a side already on a rung stays', () {
      final preset = AssetPresets.media(
        size: const Size(1024, 640),
        devicePixelRatio: 1,
        profile: const AssetProfile(),
      );

      expect((preset.spec.pixelWidth, preset.spec.pixelHeight), (1024, 640));
    });
  });

  group('media', () {
    test('shows the box it is given and decodes it at the density', () {
      // 320 x 180 px: 320 is a rung (512 x 5/8), 180 rounds up to 205.
      final preset = AssetPresets.media(
        size: const Size(160, 90),
        devicePixelRatio: 2,
        profile: const AssetProfile(animate: true),
      );

      expect(preset.size, const Size(160, 90));
      expect(preset.spec.pixelWidth, 320);
      expect(preset.spec.pixelHeight, 205);
      expect(preset.profile, const AssetProfile(animate: true));
    });

    test('caps the decode at the longer side, keeping the proportion', () {
      // A 206 dp item at density 3 is 618 px: decoded at 512.
      final square = AssetPresets.media(
        size: const Size.square(206),
        devicePixelRatio: 3,
        profile: const AssetProfile(),
        maxPixelExtent: 512,
      );
      final wide = AssetPresets.media(
        size: const Size(288, 162),
        devicePixelRatio: 3,
        profile: const AssetProfile(),
        maxPixelExtent: 512,
      );

      expect(square.size, const Size.square(206));
      expect((square.spec.pixelWidth, square.spec.pixelHeight), (512, 512));
      expect((wide.spec.pixelWidth, wide.spec.pixelHeight), (512, 288));
    });

    test('a decode under the cap stands on its rung, not on the cap', () {
      // 336 px rounds up to 410 (512 x 4/5), below the cap of 512.
      final preset = AssetPresets.media(
        size: const Size.square(112),
        devicePixelRatio: 3,
        profile: const AssetProfile(),
        maxPixelExtent: 512,
      );

      expect((preset.spec.pixelWidth, preset.spec.pixelHeight), (410, 410));
    });

    test('a rung past the cap is held to the cap', () {
      // 420 px would round up to 512, past the cap of 480.
      final preset = AssetPresets.media(
        size: const Size.square(420),
        devicePixelRatio: 1,
        profile: const AssetProfile(),
        maxPixelExtent: 480,
      );

      expect((preset.spec.pixelWidth, preset.spec.pixelHeight), (480, 480));
    });
  });

  group('AssetPreset', () {
    test('is equal to a preset of the same size, spec and profile', () {
      const spec = AssetSpec(pixelWidth: 4, pixelHeight: 4);
      const a = AssetPreset(
        size: Size(2, 2),
        spec: spec,
        profile: AssetProfile(),
      );
      const b = AssetPreset(
        size: Size(2, 2),
        spec: spec,
        profile: AssetProfile(),
      );
      const c = AssetPreset(
        size: Size(3, 3),
        spec: spec,
        profile: AssetProfile(),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
