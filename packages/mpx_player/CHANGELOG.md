# Changelog

## Unreleased

- `PlayerPool`, `PlayerLease`, `PlayerState`, `PlayerBudget`, `PlayerView`.
- `PlayerBackend` / `PlayerEngine` seam; `FakePlayerBackend` and
  `PlayerEngineContract` in `testing.dart`.
- `FeedPolicy` (`list` and `pager` defaults, 25 knobs), `FeedItem`,
  `FeedConditions` and `FeedListPlanner`.
- `FeedSignals`: the host seam for network, power saving and thermal state,
  with `metered`, `powerSaving` and `stressed` for the core's pause layers.
- One sound owner: `PlayerPool.soundOwner`, `onSoundOwnerLeftScreen`, and
  the `AudioFocus` seam on `PlayerBackend` (`FakeAudioFocus` in tests).

## 0.0.1

- Initial package skeleton.
