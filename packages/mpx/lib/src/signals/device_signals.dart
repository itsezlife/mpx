import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// --- Values ---

/// What using the current network costs, coarsest first.
///
/// The wire name of each value is its [Enum.name].
enum NetworkClass {
  /// No network with internet access.
  none,

  /// A network the user does not pay for by the byte, such as most Wi-Fi.
  unmetered,

  /// A network the user may pay for by the byte, such as cellular. A network
  /// the user asked to spare (a low-data mode) also reads as metered.
  metered,

  /// A metered network outside the home carrier. Only Android reports it.
  roaming,
}

/// How hot the device runs, mildest first.
///
/// Four steps, because Apple platforms report four; Android's seven fold into
/// them. The wire name of each value is its [Enum.name].
enum ThermalStatus {
  /// No throttling.
  nominal,

  /// Slightly raised; work can go on.
  fair,

  /// Throttling has begun; optional work should stop.
  serious,

  /// The device is about to shed load itself; do the least possible.
  critical,
}

// --- Contract ---

/// Live readings of the device state that playback and preload policies
/// weigh: [network] class, [powerSaving] mode, [thermal] status and the
/// [batteryLevel].
///
/// Every value starts neutral (unmetered, not saving power, nominal), which
/// is what a host with no signals at all would assume, and changes when the
/// device reports. A listenable notifies only when its own value changes.
abstract interface class IDeviceSignals {
  /// The class of the network the device uses by default.
  ValueListenable<NetworkClass> get network;

  /// Whether the user or the system turned on a power-saving mode.
  ValueListenable<bool> get powerSaving;

  /// The device's thermal status.
  ValueListenable<ThermalStatus> get thermal;

  /// The battery, 0 to 100 percent; null when the device cannot tell (a
  /// desktop with no battery, a platform with no native side).
  ValueListenable<int?> get batteryLevel;

  /// The media volume of the device, 0 to 100 percent (0 is muted); null when
  /// the device cannot tell. A rise of it is a reader asking for sound.
  ValueListenable<int?> get mediaVolume;

  /// Stops reading the device. The listenables keep their last values and
  /// must not be listened to afterwards.
  void dispose();
}

// --- Platform implementation ---

/// [IDeviceSignals] read from the platform over the `dev.mpx.device_signals`
/// event channel (Android, iOS, macOS).
///
/// Instances share one platform subscription: a second event-channel listener
/// would silently take the stream from the first, so every instance listens
/// through one shared hub, and an instance made after the first reading starts
/// from it. The platform listener stops when the last instance is disposed.
///
/// On a platform without the native side the values stay neutral.
final class DeviceSignals implements IDeviceSignals {
  /// Starts reading the device.
  DeviceSignals() {
    if (_hub.latest case final reading?) _take(reading);
    _hub.attach(this);
  }

  static final _hub = _DeviceSignalsHub();

  @override
  final ValueNotifier<NetworkClass> network = ValueNotifier(
    NetworkClass.unmetered,
  );

  @override
  final ValueNotifier<bool> powerSaving = ValueNotifier(false);

  @override
  final ValueNotifier<ThermalStatus> thermal = ValueNotifier(
    ThermalStatus.nominal,
  );

  @override
  final ValueNotifier<int?> batteryLevel = ValueNotifier(null);

  @override
  final ValueNotifier<int?> mediaVolume = ValueNotifier(null);

  bool _disposed = false;

  void _take(_Reading reading) {
    network.value = reading.network;
    powerSaving.value = reading.powerSaving;
    thermal.value = reading.thermal;
    batteryLevel.value = reading.batteryLevel;
    mediaVolume.value = reading.mediaVolume;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _hub.detach(this);
    network.dispose();
    powerSaving.dispose();
    thermal.dispose();
    batteryLevel.dispose();
    mediaVolume.dispose();
  }
}

typedef _Reading = ({
  NetworkClass network,
  bool powerSaving,
  ThermalStatus thermal,
  int? batteryLevel,
  int? mediaVolume,
});

/// The one listener of the event channel, fanning readings out to every live
/// [DeviceSignals].
final class _DeviceSignalsHub {
  static const _channel = EventChannel('dev.mpx.device_signals');

  final Set<DeviceSignals> _members = {};
  StreamSubscription<Object?>? _subscription;

  /// The last reading, replayed to an instance made after it; cleared when
  /// the platform listener stops, since it goes stale from then on.
  _Reading? latest;

  void attach(DeviceSignals member) {
    _members.add(member);
    _subscription ??= _channel.receiveBroadcastStream().listen(
      _onEvent,
      onError: _onError,
    );
  }

  void detach(DeviceSignals member) {
    _members.remove(member);
    if (_members.isNotEmpty) return;
    unawaited(_subscription?.cancel());
    _subscription = null;
    latest = null;
  }

  void _onEvent(Object? event) {
    final _Reading reading;
    try {
      reading = _decode(event);
    } on Object catch (error, stack) {
      _onError(error, stack);
      return;
    }
    latest = reading;
    for (final member in List.of(_members)) {
      member._take(reading);
    }
  }

  // A reading the Dart side cannot decode means the two sides disagree on
  // the wire; the values keep their last reading and the error is reported,
  // not dropped.
  void _onError(Object error, StackTrace stack) => FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'mpx',
      context: ErrorDescription('while reading device signals'),
    ),
  );
}

/// One wire reading: a map with `network` and `thermal` wire names, a
/// `powerSaving` bool, a `batteryLevel` and a `mediaVolume` int (-1 when
/// unknown, and absent from a native side that predates them). Unknown names throw; the sides ship
/// together.
_Reading _decode(Object? event) => switch (event) {
  {
    'network': final String network,
    'powerSaving': final bool powerSaving,
    'thermal': final String thermal,
  } =>
    (
      network: NetworkClass.values.byName(network),
      powerSaving: powerSaving,
      thermal: ThermalStatus.values.byName(thermal),
      batteryLevel: switch (event['batteryLevel']) {
        final int level when level >= 0 && level <= 100 => level,
        _ => null,
      },
      mediaVolume: switch (event['mediaVolume']) {
        final int level when level >= 0 && level <= 100 => level,
        _ => null,
      },
    ),
  _ => throw FormatException('Not a device signals reading', event),
};
