import 'package:flutter_test/flutter_test.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx/testing.dart';

void main() {
  runDeviceSignalsContract('FakeDeviceSignals', () async {
    final fake = FakeDeviceSignals();
    return (
      signals: fake,
      report:
          ({
            required NetworkClass network,
            required bool powerSaving,
            required ThermalStatus thermal,
          }) async {
            fake.network.value = network;
            fake.powerSaving.value = powerSaving;
            fake.thermal.value = thermal;
          },
    );
  });

  test('FakeDeviceSignals starts at the values it is given', () {
    final fake = FakeDeviceSignals(
      network: NetworkClass.roaming,
      powerSaving: true,
      thermal: ThermalStatus.critical,
    );
    addTearDown(fake.dispose);

    expect(fake.network.value, NetworkClass.roaming);
    expect(fake.powerSaving.value, isTrue);
    expect(fake.thermal.value, ThermalStatus.critical);
  });
}
