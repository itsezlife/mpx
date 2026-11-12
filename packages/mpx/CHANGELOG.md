# Changelog

## Unreleased

- Device signals: `DeviceSignals` reads network class, power-saving mode and
  thermal status on Android, iOS and macOS as `ValueListenable`s.
  `FakeDeviceSignals` and `runDeviceSignalsContract` in `testing.dart`. The
  Android side adds the `ACCESS_NETWORK_STATE` permission to the host app.

## 0.0.1

- Initial package skeleton.
