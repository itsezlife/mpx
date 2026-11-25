import 'package:flutter_test/flutter_test.dart';
import 'package:mpx/src/signals/device_signals.dart';

/// Makes the device under a contract test report one full reading.
///
/// Completes once the reading has reached the signals.
typedef DeviceSignalsReport =
    Future<void> Function({
      required NetworkClass network,
      required bool powerSaving,
      required ThermalStatus thermal,
      int? batteryLevel,
      int? mediaVolume,
    });

/// Fresh [IDeviceSignals] for one contract test, with the hook that drives
/// what the device reports to it.
typedef DeviceSignalsHarness = ({
  IDeviceSignals signals,
  DeviceSignalsReport report,
});

/// Behaviour every [IDeviceSignals] shares, whatever reads the device.
///
/// Call inside a test file's `main`; the suite registers its own group named
/// [name]. Each test disposes the signals it created.
void runDeviceSignalsContract(
  String name,
  Future<DeviceSignalsHarness> Function() create,
) {
  group('$name honours the IDeviceSignals contract', () {
    Future<DeviceSignalsHarness> open() async {
      final harness = await create();
      addTearDown(harness.signals.dispose);
      return harness;
    }

    test('starts neutral: unmetered, not saving power, nominal', () async {
      final (:signals, report: _) = await open();

      expect(signals.network.value, NetworkClass.unmetered);
      expect(signals.powerSaving.value, isFalse);
      expect(signals.thermal.value, ThermalStatus.nominal);
      expect(signals.batteryLevel.value, isNull);
      expect(signals.mediaVolume.value, isNull);
    });

    test('takes every value the device reports', () async {
      final (:signals, :report) = await open();

      await report(
        network: NetworkClass.metered,
        powerSaving: true,
        thermal: ThermalStatus.serious,
        batteryLevel: 42,
        mediaVolume: 60,
      );

      expect(signals.network.value, NetworkClass.metered);
      expect(signals.powerSaving.value, isTrue);
      expect(signals.thermal.value, ThermalStatus.serious);
      expect(signals.batteryLevel.value, 42);
      expect(signals.mediaVolume.value, 60);
    });

    test('a volume that goes to zero is muted, not unknown', () async {
      final (:signals, :report) = await open();
      await report(
        network: NetworkClass.unmetered,
        powerSaving: false,
        thermal: ThermalStatus.nominal,
        mediaVolume: 0,
      );

      expect(signals.mediaVolume.value, 0);
    });

    test('a battery the device cannot read is unknown, not empty', () async {
      final (:signals, :report) = await open();
      await report(
        network: NetworkClass.unmetered,
        powerSaving: false,
        thermal: ThermalStatus.nominal,
        batteryLevel: 80,
      );

      await report(
        network: NetworkClass.unmetered,
        powerSaving: false,
        thermal: ThermalStatus.nominal,
      );

      expect(signals.batteryLevel.value, isNull);
    });

    test('notifies only the listenables whose value changed', () async {
      final (:signals, :report) = await open();
      final heard = <String>[];
      signals.network.addListener(() => heard.add('network'));
      signals.powerSaving.addListener(() => heard.add('powerSaving'));
      signals.thermal.addListener(() => heard.add('thermal'));
      signals.batteryLevel.addListener(() => heard.add('battery'));
      signals.mediaVolume.addListener(() => heard.add('volume'));

      await report(
        network: NetworkClass.unmetered,
        powerSaving: false,
        thermal: ThermalStatus.fair,
      );
      expect(heard, ['thermal']);

      await report(
        network: NetworkClass.unmetered,
        powerSaving: false,
        thermal: ThermalStatus.fair,
        batteryLevel: 50,
      );
      expect(heard, ['thermal', 'battery']);

      await report(
        network: NetworkClass.unmetered,
        powerSaving: false,
        thermal: ThermalStatus.fair,
        batteryLevel: 50,
        mediaVolume: 30,
      );
      expect(heard, ['thermal', 'battery', 'volume']);
    });

    test('a repeated reading notifies nobody', () async {
      final (:signals, :report) = await open();
      await report(
        network: NetworkClass.none,
        powerSaving: true,
        thermal: ThermalStatus.critical,
      );
      var notified = 0;
      void count() => notified++;
      signals.network.addListener(count);
      signals.powerSaving.addListener(count);
      signals.thermal.addListener(count);

      await report(
        network: NetworkClass.none,
        powerSaving: true,
        thermal: ThermalStatus.critical,
      );

      expect(notified, 0);
    });
  });
}
