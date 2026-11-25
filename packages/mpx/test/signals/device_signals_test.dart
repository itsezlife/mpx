import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx/testing.dart';

/// Stands in for the native side of `dev.mpx.device_signals`.
final class _FakePlatform {
  _FakePlatform() {
    _messenger.setMockStreamHandler(
      _channel,
      MockStreamHandler.inline(
        onListen: (_, events) {
          listens++;
          _events = events;
        },
        onCancel: (_) {
          cancels++;
          _events = null;
        },
      ),
    );
    addTearDown(() => _messenger.setMockStreamHandler(_channel, null));
  }

  static const _channel = EventChannel('dev.mpx.device_signals');
  static TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  MockStreamHandlerEventSink? _events;
  int listens = 0;
  int cancels = 0;

  /// Sends [event] and waits for the channel to deliver it.
  Future<void> send(Object? event) async {
    _events!.success(event);
    await pumpEventQueue();
  }

  Future<void> report({
    required NetworkClass network,
    required bool powerSaving,
    required ThermalStatus thermal,
    int? batteryLevel,
    int? mediaVolume,
  }) => send({
    'network': network.name,
    'powerSaving': powerSaving,
    'thermal': thermal.name,
    // The native side sends -1 for a battery it cannot read.
    'batteryLevel': batteryLevel ?? -1,
    'mediaVolume': mediaVolume ?? -1,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  runDeviceSignalsContract('DeviceSignals', () async {
    final platform = _FakePlatform();
    final signals = DeviceSignals();
    await pumpEventQueue();
    return (signals: signals, report: platform.report);
  });

  test('decodes every wire name the native side sends', () async {
    final platform = _FakePlatform();
    final signals = DeviceSignals();
    addTearDown(signals.dispose);
    await pumpEventQueue();

    final networks = <NetworkClass>[];
    for (final name in ['none', 'unmetered', 'metered', 'roaming']) {
      await platform.send({
        'network': name,
        'powerSaving': false,
        'thermal': 'nominal',
      });
      networks.add(signals.network.value);
    }
    final thermals = <ThermalStatus>[];
    for (final name in ['nominal', 'fair', 'serious', 'critical']) {
      await platform.send({
        'network': 'none',
        'powerSaving': true,
        'thermal': name,
      });
      thermals.add(signals.thermal.value);
    }

    expect(networks, [
      NetworkClass.none,
      NetworkClass.unmetered,
      NetworkClass.metered,
      NetworkClass.roaming,
    ]);
    expect(thermals, [
      ThermalStatus.nominal,
      ThermalStatus.fair,
      ThermalStatus.serious,
      ThermalStatus.critical,
    ]);
    expect(signals.powerSaving.value, isTrue);
  });

  test(
    'a reading from a native side with no battery is still decoded',
    () async {
      final platform = _FakePlatform();
      final signals = DeviceSignals();
      addTearDown(signals.dispose);
      await pumpEventQueue();

      await platform.send({
        'network': 'metered',
        'powerSaving': false,
        'thermal': 'nominal',
      });

      expect(signals.network.value, NetworkClass.metered);
      expect(signals.batteryLevel.value, isNull);
    },
  );

  test('instances share one platform listener', () async {
    final platform = _FakePlatform();
    final first = DeviceSignals();
    addTearDown(first.dispose);
    await pumpEventQueue();
    await platform.report(
      network: NetworkClass.metered,
      powerSaving: true,
      thermal: ThermalStatus.fair,
    );

    final second = DeviceSignals();
    addTearDown(second.dispose);
    await pumpEventQueue();

    expect(platform.listens, 1);
    expect(second.network.value, NetworkClass.metered);
    expect(second.powerSaving.value, isTrue);
    expect(second.thermal.value, ThermalStatus.fair);

    await platform.report(
      network: NetworkClass.none,
      powerSaving: true,
      thermal: ThermalStatus.fair,
    );

    expect(first.network.value, NetworkClass.none);
    expect(second.network.value, NetworkClass.none);
  });

  test('the platform listener stops with the last instance', () async {
    final platform = _FakePlatform();
    final first = DeviceSignals();
    final second = DeviceSignals();
    await pumpEventQueue();

    first.dispose();
    await pumpEventQueue();
    expect(platform.cancels, 0);

    second.dispose();
    await pumpEventQueue();
    expect(platform.cancels, 1);
  });

  test('an instance made after the listener stopped starts neutral', () async {
    final platform = _FakePlatform();
    final first = DeviceSignals();
    await pumpEventQueue();
    await platform.report(
      network: NetworkClass.roaming,
      powerSaving: true,
      thermal: ThermalStatus.critical,
    );
    first.dispose();
    await pumpEventQueue();

    final next = DeviceSignals();
    addTearDown(next.dispose);

    expect(next.network.value, NetworkClass.unmetered);
    expect(next.powerSaving.value, isFalse);
    expect(next.thermal.value, ThermalStatus.nominal);
  });

  test('a reading it cannot decode is reported and changes nothing', () async {
    final platform = _FakePlatform();
    final signals = DeviceSignals();
    addTearDown(signals.dispose);
    await pumpEventQueue();
    await platform.report(
      network: NetworkClass.metered,
      powerSaving: false,
      thermal: ThermalStatus.fair,
    );
    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previous);

    await platform.send({
      'network': 'satellite',
      'powerSaving': true,
      'thermal': 'serious',
    });
    await platform.send('not a map');

    expect(reported, hasLength(2));
    expect(signals.network.value, NetworkClass.metered);
    expect(signals.powerSaving.value, isFalse);
    expect(signals.thermal.value, ThermalStatus.fair);
  });
}
