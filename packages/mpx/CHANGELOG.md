# Changelog

## Unreleased

- The bytes cache reports through `MpxDiagnostics.current`:
  `CacheDiagnosticsBridge.policy`, which `MpxStack.create` installs as
  `BytesDiagnostics.current`, turns each bytes event into an `MpxEvent` of
  category `cache` (`CacheOp`, the bytes operation in `fields.bytesOp`)
  with its level and stack trace, and drops its message, which can carry
  keys and URLs. A host that opens the bytes cache itself installs the
  same policy. Breaking: `MpxStack.create(diagnostics:)` is gone; set
  `MpxDiagnostics.current` instead.
- `MpxStack` repeats what failed for want of a network when the device's
  `network` signal comes back from `none` (`AssetCacheScope.connectivityRestored`):
  an avatar or a picture asked for offline loads once the network is back,
  with no re-attach.
- Device signals carry the media volume (`IDeviceSignals.mediaVolume`, 0 to
  100 percent, 0 when muted, null when unknown): the Android music stream's
  (`VOLUME_CHANGED_ACTION`) and the Apple audio session's output volume.
- Device signals carry the battery level (`IDeviceSignals.batteryLevel`, an
  int percentage, null when the device cannot tell): read on Android and iOS,
  unknown on macOS and where there is no native side.
- The auto-download policy weighs a vector image as a still.
- `RangedContentPublisher.publish(onProgress:, whole:)`: a published clip
  reports its bytes as they land (the first stretch's and the reads'), so a
  tile's arc and size move while it downloads; with `whole` (a user's
  download, `FetchRequest.whole`) the native publisher fetches the rest
  behind the reads until the content is released, so the clip is kept
  whole and is downloaded after a restart. Breaking for implementers.

- `MpxStack.create(fallbackDecoders:)` registers a fallback decoder per
  kind (`DecoderRegistry.registerFallback`).
- `NetworkAutoDownloadPolicy` decides which missing media downloads by
  itself from `AutoDownloadPresets` (a row per context tag, a `fallback`
  for the rest; per network class, `AutoDownloadLimits` per kind) and the
  network class of `IDeviceSignals`; without a network it keeps the last
  connected class. `$Android`, `$IOS` and `$Desktop` hold each platform's
  standard defaults. `MpxStack.create(autoDownload:)` defaults to it for
  `defaultTargetPlatform`, and `MpxStack.autoDownload` exposes the policy.
  Missing videos over the limit, and videos and animations whose size is
  unknown, now show their stand-ins and wait for a tap instead of
  downloading (`AutoDownloadLimit.upTo(unknownSizeDownloads:)`; stills of
  unknown size still download).
- `BytesCachePreviewStore`: derived previews as rows of the bytes cache
  under `BytesQuota.previews`, with a 512-entry memory tier and writes
  after the frame. `MpxStack.create(previews:, previewBlur:)` uses it by
  default; `MpxStack.previews` exposes it.
- `MpxStack.create(rangedParts:)` tunes how ranged downloads split into
  parts and how many run at once per file (`RangedParts`); missing media
  now downloads in parts, several in flight, instead of one GET.
- `NativeRangedContentPublisher` hands a clip over once its index (the tail
  of a file whose `moov` follows its media data) and a first stretch
  (`firstStretchBytes`, 2 MiB) are there, and pauses its fetching when its
  surface leaves the screen. The example streams clips this way again.
- `BytesCacheFetcher` hands media out as the file it is in over a store
  that keeps files, leased until the decoder releases it, instead of reading
  it into the UI isolate; a missing immutable part is fetched as a ranged
  resource in one GET. `RangedContentPublisher` (`NativeRangedContentPublisher`
  in `package:mpx/native.dart`, `FakeRangedContentPublisher` in
  `testing.dart`) publishes missing content of its kinds for native readers
  instead of downloading it first; opt-in, since a published clip blocks
  its decode worker on missing bytes. The example does not publish: its
  clips download whole off the UI isolate, and its lab reports coverage
  (items that reached a picture, video frames decoded) beside the hitches,
  flagging a replay that drew less than its recording.
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
