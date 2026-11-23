import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _photo = MediaKey.remote('photo-1');
// A page's decode, then the same page a window drag later.
const _wide = AssetSpec(pixelWidth: 1600, pixelHeight: 1000);
const _narrower = AssetSpec(pixelWidth: 1200, pixelHeight: 750);
const _profile = AssetProfile();

void main() {
  late FakeAssetProducer producer;
  late AssetCacheScope scope;

  setUp(() {
    producer = FakeAssetProducer();
    scope = AssetCacheScope(
      producer: producer,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
    );
  });
  tearDown(() => scope.dispose());

  group('a still already decoded larger', () {
    test('answers a smaller spec, with no decode of its own', () {
      scope.attach(_photo, _wide, _profile);
      final wide = producer.last.advance(AssetStage.full);

      final narrower = scope.attach(_photo, _narrower, _profile);

      expect(producer.attempts, hasLength(1));
      expect(narrower.paintable, same(wide));
      expect(
        narrower.readiness,
        const AssetReadiness(AssetStage.full, isFinal: true),
      );
    });

    test('more than twice as large on a side decodes the spec anew', () {
      scope.attach(_photo, _wide, _profile);
      producer.last.advance(AssetStage.full);

      scope.attach(
        _photo,
        const AssetSpec(pixelWidth: 799, pixelHeight: 500),
        _profile,
      );

      expect(producer.attempts, hasLength(2));
    });

    test('of another decode mode is another picture', () {
      scope.attach(_photo, _wide, _profile);
      producer.last.advance(AssetStage.full);

      scope.attach(
        _photo,
        const AssetSpec(
          pixelWidth: 1200,
          pixelHeight: 750,
          decodeMode: AssetDecodeMode.template,
        ),
        _profile,
      );

      expect(producer.attempts, hasLength(2));
    });

    test('of another variant is another picture', () {
      scope.attach(
        _photo,
        const AssetSpec(
          pixelWidth: 1600,
          pixelHeight: 1000,
          variant: AssetVariant.firstFrame,
        ),
        _profile,
      );
      producer.last.advance(AssetStage.firstFrame);

      scope.attach(_photo, _narrower, _profile);

      expect(producer.attempts, hasLength(2));
    });

    test('an animation keeps its own spec and playback', () {
      scope.attach(_photo, _wide, _profile);
      producer.last.advance(
        AssetStage.full,
        tier: AssetTier.animated,
        animated: true,
      );

      scope.attach(_photo, _narrower, _profile);

      expect(producer.attempts, hasLength(2));
    });

    test('the smallest that covers the spec answers it', () {
      scope
        ..attach(_photo, _wide, _profile)
        ..attach(
          _photo,
          const AssetSpec(pixelWidth: 1300, pixelHeight: 800),
          _profile,
        );
      producer.attempts.first.advance(AssetStage.full);
      final closer = producer.last.advance(AssetStage.full);

      final narrower = scope.attach(_photo, _narrower, _profile);

      expect(narrower.paintable, same(closer));
    });
  });
}
