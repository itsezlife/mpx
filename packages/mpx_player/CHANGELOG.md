# Changelog

## Unreleased

- `FeedController` and `FeedSlot`: feed playback inside any host
  scrollable. Slots measure their own visible share against every enclosing
  viewport; the controller plans per frame, holds the preloads and the
  pager's leases, and exposes each item's `FeedItemState`. `FeedScope`
  hands a controller to the slots below. In pager mode the most visible
  page plays, so any pager works.
- `FeedActiveItemRule.pick`: the in-view choice, shared by the list planner
  and the pager.
- The planners and `FeedPager` take facts that may be unknown (`itemOf`
  returns null): such items are neither played nor warmed.
  `FeedPager.itemCount` is settable and `FeedPager.replan` plans again.
- `PlayerPool`, `PlayerLease`, `PlayerState`, `PlayerBudget`, `PlayerView`.
- `PlayerBackend` / `PlayerEngine` seam; `FakePlayerBackend` and
  `PlayerEngineContract` in `testing.dart`.
- `FeedPolicy` (`list` and `pager` defaults, 25 knobs), `FeedItem`,
  `FeedConditions` and `FeedListPlanner`.
- `FeedSignals`: the host seam for network, power saving and thermal state,
  with `metered`, `powerSaving` and `stressed` for the core's pause layers.
- `FeedPagerPlanner` and `FeedPager`: the pager mode over the pool;
  `FeedPolicy.boundPreload` shared with the list planner.
- One sound owner: `PlayerPool.soundOwner`, `onSoundOwnerLeftScreen`, and
  the `AudioFocus` seam on `PlayerBackend` (`FakeAudioFocus` in tests).

## 0.0.1

- Initial package skeleton.
