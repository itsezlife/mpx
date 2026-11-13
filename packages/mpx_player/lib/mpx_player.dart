/// The hardware player of mpx: a pool of players keyed by `MediaKey`, leased
/// by the surfaces that show them.
///
/// A host creates one `PlayerPool` over the platform's `PlayerBackend`. A
/// surface takes a `PlayerLease` for a key, sends it commands (play, pause,
/// seek, speed, loop, volume), listens to its `PlayerState` and draws it with
/// `PlayerView`. Every lease of a key shares one player, so a hand-off from
/// one surface to another keeps position and buffer. A `PlayerBudget` bounds
/// how many players hold an engine and how many play.
///
/// A `FeedPolicy` holds the rules of a scrolling surface (the 25 feed knobs
/// with reference defaults); `FeedListPlanner` turns what a list shows into
/// what plays, what is in view and what preloads.
///
/// Single-threaded on the UI isolate; no static state.
library;

export 'src/audio/audio_focus.dart';
export 'src/backend/player_backend.dart';
export 'src/feed/feed_controller.dart';
export 'src/feed/feed_item.dart';
export 'src/feed/feed_list_plan.dart';
export 'src/feed/feed_pager.dart';
export 'src/feed/feed_policy.dart';
export 'src/feed/feed_signals.dart';
export 'src/feed/feed_slot.dart';
export 'src/player/player_state.dart';
export 'src/pool/player_pool.dart';
export 'src/widget/player_view.dart';
