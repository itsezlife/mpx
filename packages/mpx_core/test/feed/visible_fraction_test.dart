import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _key = MediaKey.remote('clip');
const _spec = AssetSpec(pixelWidth: 320, pixelHeight: 180);
const _plays = AssetProfile(animate: true);
const _floored = AssetProfile(animate: true, advanceFloor: 0.25);

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

  AssetBinding playing(AssetProfile profile) {
    final binding = scope.attach(_key, _spec, profile);
    producer.last.advance(
      AssetStage.full,
      tier: AssetTier.animated,
      animated: true,
    );
    return binding;
  }

  test('starts fully visible; visible maps to 1 and 0', () {
    final binding = scope.attach(_key, _spec, _plays);

    expect(binding.visibleFraction, 1);
    binding.visible = false;
    expect(binding.visibleFraction, 0);
    expect(binding.visible, isFalse);
    binding.visible = true;
    expect(binding.visibleFraction, 1);
  });

  test('clamps to 0..1', () {
    final binding = scope.attach(_key, _spec, _plays)..visibleFraction = 3;
    expect(binding.visibleFraction, 1);
    binding.visibleFraction = -1;
    expect(binding.visibleFraction, 0);
  });

  test('any visible part is shown and wanted at visible priority', () {
    final binding = scope.attach(_key, _spec, _plays)..visibleFraction = 0.1;

    expect(binding.visible, isTrue);
    expect(producer.last.demand.priority, AssetPriority.visible);

    binding.visibleFraction = 0;
    expect(producer.last.demand.priority, AssetPriority.preload);
  });

  test('below the advance floor a shown binding holds its frame', () {
    final binding = playing(_floored)..visibleFraction = 0.2;

    expect(binding.visible, isTrue);
    expect(binding.isPlaying, isFalse);

    binding.visibleFraction = 0.25;
    expect(binding.isPlaying, isTrue);

    binding.visibleFraction = 0.24;
    expect(binding.isPlaying, isFalse);
  });

  test('without a floor any visible part advances', () {
    final binding = playing(_plays)..visibleFraction = 0.01;

    expect(binding.isPlaying, isTrue);
  });

  test('the surface hold is its own: leaving the floor keeps it', () {
    final binding = playing(_floored)
      ..held = true
      ..visibleFraction = 0.1
      ..visibleFraction = 1;

    expect(binding.held, isTrue);
    expect(binding.isPlaying, isFalse);
  });
}
