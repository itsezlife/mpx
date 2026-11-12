import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_player/mpx_player.dart';

const _mib = 1024 * 1024;

// The shape of a host's own signal enums, as the device signals of the
// umbrella package have them.
enum HostNetwork { none, unmetered, metered, roaming }

enum HostThermal { nominal, fair, serious, critical }

void main() {
  late ValueNotifier<FeedNetwork> network;
  late ValueNotifier<bool> powerSaving;
  late ValueNotifier<FeedThermal> thermal;
  late FeedSignals signals;

  setUp(() {
    network = ValueNotifier(FeedNetwork.unmetered);
    powerSaving = ValueNotifier(false);
    thermal = ValueNotifier(FeedThermal.nominal);
    signals = FeedSignals(
      network: network,
      powerSaving: powerSaving,
      thermal: thermal,
    );
  });
  tearDown(() {
    signals.dispose();
    network.dispose();
    powerSaving.dispose();
    thermal.dispose();
  });

  FeedAutoplay autoplay(
    int bytes, {
    FeedPolicy policy = const FeedPolicy.list(),
  }) => FeedListPlanner(policy, conditions: signals.value)
      .plan(
        const FeedListViewport(itemCount: 1, visible: {0: 1}),
        (_) => FeedItem(const MediaKey.remote('clip'), byteSize: bytes),
      )
      .autoplay[0]!;

  test('without inputs the conditions are neutral', () {
    final none = FeedSignals();
    addTearDown(none.dispose);

    expect(none.value, const FeedConditions());
  });

  test('the snapshot follows the inputs, and listeners hear changes', () {
    var heard = 0;
    signals.addListener(() => heard++);

    network.value = FeedNetwork.metered;
    powerSaving.value = true;
    thermal.value = FeedThermal.serious;

    expect(
      signals.value,
      const FeedConditions(
        network: FeedNetwork.metered,
        powerSaving: true,
        thermal: FeedThermal.serious,
      ),
    );
    expect(heard, 3);
  });

  test('a read without listeners is never stale', () {
    network.value = FeedNetwork.roaming;

    expect(signals.value.network, FeedNetwork.roaming);
  });

  test('the autoplay gate follows network and power', () {
    expect(autoplay(12 * _mib), FeedAutoplay.full);

    network.value = FeedNetwork.metered;
    expect(autoplay(12 * _mib), FeedAutoplay.prefixOnly);
    expect(autoplay(5 * _mib), FeedAutoplay.full);

    network.value = FeedNetwork.roaming;
    expect(autoplay(5 * _mib), FeedAutoplay.none);

    network.value = FeedNetwork.none;
    expect(autoplay(1024), FeedAutoplay.none);

    network.value = FeedNetwork.unmetered;
    powerSaving.value = true;
    expect(autoplay(1024), FeedAutoplay.none);
  });

  test('the size limits are host knobs', () {
    const generous = FeedPolicy.list(
      sizeLimits: FeedSizeLimits(metered: 50 * _mib),
    );
    network.value = FeedNetwork.metered;

    expect(autoplay(40 * _mib, policy: generous), FeedAutoplay.full);
  });

  test('metered, power saving and stressed feed the core layers', () {
    final heard = <String>[];
    signals.metered.addListener(() => heard.add('metered'));
    signals.powerSaving.addListener(() => heard.add('power'));
    signals.stressed.addListener(() => heard.add('stressed'));

    network.value = FeedNetwork.roaming;
    expect(signals.metered.value, isTrue);
    network.value = FeedNetwork.metered;
    // Still metered: no change to hear.
    thermal.value = FeedThermal.fair;
    expect(signals.stressed.value, isFalse);
    thermal.value = FeedThermal.critical;
    powerSaving.value = true;

    expect(heard, ['metered', 'stressed', 'power']);
  });

  test('drives the core pause layers through PlaybackActivity', () {
    final clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    addTearDown(clock.dispose);
    final activity = PlaybackActivity(
      clock: clock,
      lowPower: signals.powerSaving,
      meteredNetwork: signals.metered,
      thermalStress: signals.stressed,
    );
    addTearDown(activity.dispose);

    network.value = FeedNetwork.metered;
    thermal.value = FeedThermal.serious;

    expect(clock.pausedLayers, {
      PlaybackPauseLayer.meteredNetwork,
      PlaybackPauseLayer.thermalStress,
    });
  });

  test('adapts host enums by mapping', () {
    final hostNetwork = ValueNotifier(HostNetwork.metered);
    final hostThermal = ValueNotifier(HostThermal.fair);
    addTearDown(hostNetwork.dispose);
    addTearDown(hostThermal.dispose);
    final adapted = FeedSignals.adapt<HostNetwork, HostThermal>(
      network: hostNetwork,
      toNetwork: (value) => FeedNetwork.values.byName(value.name),
      thermal: hostThermal,
      toThermal: (value) => FeedThermal.values.byName(value.name),
    );
    addTearDown(adapted.dispose);
    var heard = 0;
    adapted.addListener(() => heard++);

    hostNetwork.value = HostNetwork.roaming;

    expect(adapted.value.network, FeedNetwork.roaming);
    expect(adapted.value.thermal, FeedThermal.fair);
    expect(heard, 1);
  });

  test('dispose stops listening to the inputs', () {
    var heard = 0;
    signals
      ..addListener(() => heard++)
      ..dispose();

    // The inputs are the host's: still usable, and nobody hears them here.
    network.value = FeedNetwork.metered;
    expect(heard, 0);
    signals = FeedSignals();
  });
}
