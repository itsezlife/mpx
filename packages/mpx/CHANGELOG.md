# Changelog

## Unreleased

- `BytesCacheFetcher` hands media out as the file it is in over a store
  that keeps files, leased until the decoder releases it, instead of reading
  it into the UI isolate; a missing immutable part is fetched as a ranged
  resource in one GET. `RangedContentPublisher` (`NativeRangedContentPublisher`
  in `package:mpx/native.dart`, `FakeRangedContentPublisher` in
  `testing.dart`) publishes missing content of its kinds for native readers
  instead of downloading it first.
- `MpxStack`: `ranged` holds the store's ranged resources, `publisher`
  builds a publisher over them, and the default client runs its media
  transfers on a worker isolate.
- `MpxStack.create`: a working media stack from one call (bytes store, HTTP
  client, fetch adapter, pipeline, asset cache scope, pause layers fed by the
  device signals), with host decoders and registered quotas.
- `BytesCacheFetcher`: the core's `ContentFetcher` over `http_bytes_cache`,
  keyed by `MediaKey`; a host `MediaLocator` names the URL of missing media.
- The example draws a still, an animated WebP, a Lottie and a video loop.
- Device signals: `DeviceSignals` reads network class, power-saving mode and
  thermal status on Android, iOS and macOS as `ValueListenable`s.
  `FakeDeviceSignals` and `runDeviceSignalsContract` in `testing.dart`. The
  Android side adds the `ACCESS_NETWORK_STATE` permission to the host app.

## 0.0.1

- Initial package skeleton.
