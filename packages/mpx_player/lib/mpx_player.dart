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
/// Single-threaded on the UI isolate; no static state.
library;

export 'src/backend/player_backend.dart';
export 'src/player/player_state.dart';
export 'src/pool/player_pool.dart';
export 'src/widget/player_view.dart';
