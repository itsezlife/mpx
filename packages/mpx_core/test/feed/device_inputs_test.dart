import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

void main() {
  late PlaybackClock clock;
  setUp(() => clock = PlaybackClock(ticks: ManualPlaybackTickSource()));
  tearDown(() => clock.dispose());

  for (final (name, layer) in [
    ('meteredNetwork', PlaybackPauseLayer.meteredNetwork),
    ('thermalStress', PlaybackPauseLayer.thermalStress),
  ]) {
    test('the $name input drives its layer and dispose clears it', () {
      final input = ValueNotifier(true);
      addTearDown(input.dispose);
      final activity = PlaybackActivity(
        clock: clock,
        meteredNetwork: layer == PlaybackPauseLayer.meteredNetwork
            ? input
            : null,
        thermalStress: layer == PlaybackPauseLayer.thermalStress ? input : null,
      );

      expect(clock.pausedLayers, contains(layer));
      input.value = false;
      expect(clock.pausedLayers, isNot(contains(layer)));
      input.value = true;
      expect(clock.pausedLayers, contains(layer));

      activity.dispose();
      expect(clock.pausedLayers, isNot(contains(layer)));
      input.value = false;
      input.value = true;
      expect(clock.pausedLayers, isNot(contains(layer)));
    });
  }

  test('network and thermal layers do not pause animations', () {
    clock
      ..setPaused(PlaybackPauseLayer.meteredNetwork, paused: true)
      ..setPaused(PlaybackPauseLayer.thermalStress, paused: true);

    expect(clock.isPaused, isFalse);
  });

  test('the clock tells layer listeners about each change', () {
    var heard = 0;
    void listener() => heard++;
    clock
      ..addLayerListener(listener)
      ..setPaused(PlaybackPauseLayer.lowPower, paused: true)
      ..setPaused(PlaybackPauseLayer.lowPower, paused: true)
      ..setPaused(PlaybackPauseLayer.lowPower, paused: false)
      ..removeLayerListener(listener)
      ..setPaused(PlaybackPauseLayer.lowPower, paused: true);

    expect(heard, 2);
  });
}
