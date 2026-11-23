import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/feed/feed_item.dart';
import 'package:mpx_player/src/feed/feed_lite_mode.dart';
import 'package:mpx_player/src/pool/player_pool.dart';

/// How a scrolling surface plays its clips.
enum FeedMode {
  /// Every visible clip plays muted and loops on the software path; frames
  /// advance only when enough of a clip shows. A chat or channel history.
  list,

  /// One item plays with sound; its neighbours stay warm. A reels or stories
  /// pager.
  pager,
}

/// How the item in view is picked among the visible ones.
enum FeedTieBreak {
  /// The item with the larger visible fraction wins; equal fractions go to
  /// the one nearer the centre.
  mostVisible,

  /// The item nearer the centre of the viewport wins; equal distances go to
  /// the more visible one.
  nearestCentre,
}

/// Knob 2: which visible item is "in view", and how much of a clip must show
/// for its frames to advance.
@immutable
final class FeedActiveItemRule {
  /// Creates a rule.
  const FeedActiveItemRule({
    this.minVisibleFraction = 0.5,
    this.tieBreak = FeedTieBreak.mostVisible,
    this.advanceFloor = 0.25,
  }) : assert(
         minVisibleFraction > 0 && minVisibleFraction <= 1,
         'The in-view threshold is a fraction above 0.',
       ),
       assert(
         advanceFloor >= 0 && advanceFloor <= 1,
         'The advance floor is a fraction.',
       );

  /// How much of an item must show for it to be in view. 0.5 is a suggestion;
  /// the reference gives no value.
  final double minVisibleFraction;

  /// How ties among items above [minVisibleFraction] are broken.
  final FeedTieBreak tieBreak;

  /// Below this visible fraction a clip keeps its decoder but stops advancing
  /// frames (`AssetProfile.advanceFloor`). The Android reference stops below a
  /// quarter.
  final double advanceFloor;

  /// The index in view among [visible] (each shown index to its visible
  /// fraction), or null when none shows [minVisibleFraction]. Ties are broken
  /// by [tieBreak] over [centreDistances] (how far each centre is from the
  /// viewport's, in any unit), and a full tie goes to the earlier index.
  ///
  /// A list reads it as the item in view; a pager as the page that plays.
  int? pick(
    Map<int, double> visible, {
    Map<int, double> centreDistances = const {},
  }) {
    int? best;
    for (final MapEntry(key: index, value: fraction) in visible.entries) {
      if (fraction < minVisibleFraction) continue;
      if (best == null || _beats(index, best, visible, centreDistances)) {
        best = index;
      }
    }
    return best;
  }

  bool _beats(
    int candidate,
    int current,
    Map<int, double> visible,
    Map<int, double> centres,
  ) {
    final byFraction = visible[candidate]!.compareTo(visible[current]!);
    final byCentre = (centres[current] ?? double.infinity).compareTo(
      centres[candidate] ?? double.infinity,
    );
    final (first, second) = switch (tieBreak) {
      FeedTieBreak.mostVisible => (byFraction, byCentre),
      FeedTieBreak.nearestCentre => (byCentre, byFraction),
    };
    if (first != 0) return first > 0;
    if (second != 0) return second > 0;
    return candidate < current;
  }

  @override
  bool operator ==(Object other) =>
      other is FeedActiveItemRule &&
      other.minVisibleFraction == minVisibleFraction &&
      other.tieBreak == tieBreak &&
      other.advanceFloor == advanceFloor;

  @override
  int get hashCode => Object.hash(minVisibleFraction, tieBreak, advanceFloor);
}

/// What the autoplay gate allows for one item.
enum FeedAutoplay {
  /// The item does not play by itself; it shows its first frame or thumbnail.
  none,

  /// Only a prefix is fetched ahead ([FeedPolicy.oversizePrefix]); the item
  /// plays once the user asks or the whole file arrives.
  prefixOnly,

  /// The item plays by itself.
  full,
}

/// Knob 3: decides autoplay for [item] under [conditions], reading the size
/// limits and the oversize prefix from [policy].
typedef FeedAutoplayGate =
    FeedAutoplay Function(
      FeedItem item,
      FeedConditions conditions,
      FeedPolicy policy,
    );

/// Knob 4: the largest file that autoplays in full, per network class.
@immutable
final class FeedSizeLimits {
  /// Creates limits, in bytes.
  const FeedSizeLimits({
    this.unmetered = 15 * _mib,
    this.metered = 10 * _mib,
    this.roaming = 500 * 1024,
  });

  static const int _mib = 1024 * 1024;

  /// On Wi-Fi and other free networks. The reference's high preset: 15 MiB.
  final int unmetered;

  /// On mobile data. The reference's medium preset: 10 MiB.
  final int metered;

  /// Abroad. The reference's low preset: 500 KiB.
  final int roaming;

  /// The limit on [network]; nothing autoplays without a network.
  int limitOn(FeedNetwork network) => switch (network) {
    FeedNetwork.none => 0,
    FeedNetwork.unmetered => unmetered,
    FeedNetwork.metered => metered,
    FeedNetwork.roaming => roaming,
  };

  @override
  bool operator ==(Object other) =>
      other is FeedSizeLimits &&
      other.unmetered == unmetered &&
      other.metered == metered &&
      other.roaming == roaming;

  @override
  int get hashCode => Object.hash(unmetered, metered, roaming);
}

/// Knob 7: whether a pager starts muted, when the host gives no mute of its
/// own.
enum FeedInitialMute {
  /// Always muted until the user unmutes.
  muted,

  /// Muted while the ringer or silent switch silences the device
  /// ([FeedConditions.silenced]); the user's toggle then holds for the
  /// session.
  followRinger,

  /// With sound.
  unmuted,
}

/// Knob 9: whether [next] starts on its own when [ended] finishes.
typedef FeedAutoAdvance = bool Function(FeedItem ended, FeedItem next);

/// Knob 10: how many items around the visible ones are preloaded. In a list
/// [ahead] counts in the scroll direction.
@immutable
final class FeedPreloadWindow {
  /// Creates a window.
  const FeedPreloadWindow({required this.ahead, required this.behind})
    : assert(ahead >= 0 && behind >= 0, 'A window does not shrink.');

  /// Items preloaded ahead.
  final int ahead;

  /// Items preloaded behind.
  final int behind;

  @override
  bool operator ==(Object other) =>
      other is FeedPreloadWindow &&
      other.ahead == ahead &&
      other.behind == behind;

  @override
  int get hashCode => Object.hash(ahead, behind);
}

/// Knob 11: the preload stage of the item [distance] items away from the
/// visible ones: positive ahead, negative behind; null for none.
typedef FeedPreloadStaging = AssetPreloadStage? Function(int distance);

/// Knob 12: how much of a file above the size limit is fetched ahead, as a
/// duration (resolved to bytes through the container's index), capped.
@immutable
final class FeedOversizePrefix {
  /// Creates a prefix rule.
  const FeedOversizePrefix({
    this.duration = const Duration(seconds: 4),
    this.maxBytes = 2 * 1024 * 1024,
  });

  /// How much playback the prefix holds. The reference fetches 4 s on one
  /// platform and the first second on another; a duration, never a fixed
  /// byte count, is the lesson of both.
  final Duration duration;

  /// The cap on the prefix, and the size limit above which a prefix is worth
  /// fetching at all: 2 MiB.
  final int maxBytes;

  @override
  bool operator ==(Object other) =>
      other is FeedOversizePrefix &&
      other.duration == duration &&
      other.maxBytes == maxBytes;

  @override
  int get hashCode => Object.hash(duration, maxBytes);
}

/// Knob 22: where a clip starts when it plays again on a surface.
enum FeedResume {
  /// From where it stopped.
  resume,

  /// From the beginning.
  restart,
}

/// The rules of one feed surface: what plays, with sound or not, and what
/// preloads. Pure values and functions: it reads no platform state; the
/// device's conditions come in through [FeedConditions].
///
/// One knob set serves both modes, with per-mode defaults taken from the
/// reference clients and the platform guidance; a host overrides any knob.
/// The numbering of the knobs follows the feed decision (ADR 0005). Every
/// knob here is read by the feed; the ones only a native player backend or a
/// later consumer can honour (start buffer, forward buffer cap, resolution
/// cap, quality step-up, off-screen behaviour, tray preload, diagnostics
/// hooks) join it with that consumer, and the one sound owner is the player
/// pool's rule, not a knob.
@immutable
final class FeedPolicy {
  /// The list mode's defaults: every visible clip plays muted and loops.
  const FeedPolicy.list({
    this.activeItem = const FeedActiveItemRule(),
    this.autoplayGate = referenceAutoplayGate,
    this.sizeLimits = const FeedSizeLimits(),
    this.lite = const FeedLiteMode(),
    this.mutedAutoplay = true,
    this.initialMute = FeedInitialMute.muted,
    this.autoAdvance = roundsAdvance,
    this.preloadWindow = const FeedPreloadWindow(ahead: 3, behind: 0),
    this.preloadStaging = listStaging,
    this.oversizePrefix = const FeedOversizePrefix(),
    this.cancelOnLeave = true,
    this.preparedPlayers = 0,
    this.heavyUnloadViewports = 2,
    this.preloadBackOffLayers = AssetCacheScope.standardPreloadPausingLayers,
    this.pausingLayers = standardPausingLayers,
    this.resume = FeedResume.resume,
    this.loop = true,
  }) : mode = FeedMode.list;

  /// The pager mode's defaults: one item with sound, its neighbours warm.
  const FeedPolicy.pager({
    this.activeItem = const FeedActiveItemRule(),
    this.autoplayGate = referenceAutoplayGate,
    this.sizeLimits = const FeedSizeLimits(),
    this.lite = const FeedLiteMode(),
    this.mutedAutoplay = false,
    this.initialMute = FeedInitialMute.followRinger,
    this.autoAdvance = alwaysAdvance,
    this.preloadWindow = const FeedPreloadWindow(ahead: 1, behind: 1),
    this.preloadStaging = pagerStaging,
    this.oversizePrefix = const FeedOversizePrefix(),
    this.cancelOnLeave = true,
    this.preparedPlayers = 2,
    this.heavyUnloadViewports = 2,
    this.preloadBackOffLayers = AssetCacheScope.standardPreloadPausingLayers,
    this.pausingLayers = standardPausingLayers,
    this.resume = FeedResume.restart,
    this.loop = false,
  }) : mode = FeedMode.pager;

  /// 1. The surface mode.
  final FeedMode mode;

  /// 2. Which item is in view, and the frame-advance floor.
  final FeedActiveItemRule activeItem;

  /// 3. Whether an item autoplays, in full, as a prefix, or not at all.
  final FeedAutoplayGate autoplayGate;

  /// 4. The largest file that autoplays in full, per network class.
  final FeedSizeLimits sizeLimits;

  /// The reader's autoplay settings and the power saver: what autoplays by
  /// kind, and the battery level under which nothing does.
  final FeedLiteMode lite;

  /// 5. Whether clips that play by themselves play muted (an ambient audio
  /// role that takes no audio focus).
  final bool mutedAutoplay;

  /// 7. Whether a pager starts muted when its host gives no mute
  /// (`FeedPager.muted`, `FeedController`'s pager).
  final FeedInitialMute initialMute;

  /// 9. Whether the next item starts when one ends; null for never.
  final FeedAutoAdvance? autoAdvance;

  /// 10. How many items around the visible ones are preloaded.
  final FeedPreloadWindow preloadWindow;

  /// 11. The preload stage by distance.
  final FeedPreloadStaging preloadStaging;

  /// 12. The prefix fetched for a file above the size limit; null for none.
  final FeedOversizePrefix? oversizePrefix;

  /// 13. Whether preloads outside the window are cancelled.
  final bool cancelOnLeave;

  /// 14. How many players are kept prepared beside the playing one. Device
  /// class and decoder-instance count bound it further.
  final int preparedPlayers;

  /// 17. How many viewports away from view (`FeedVisibility.viewportsAway`)
  /// an item's cell is released (`FeedItemState.released`): it drops its
  /// decoder and frames and shows its poster. Cells a list keeps laid out
  /// ahead or alive past this cost nothing.
  final double heavyUnloadViewports;

  /// 20. The pause layers under which the feed starts no preloads (low power,
  /// a fast scroll, a metered network, thermal stress), read from the asset
  /// cache scope's clock. The scope's own `preloadPausingLayers` hold the
  /// preloads already running.
  final Set<PlaybackPauseLayer> preloadBackOffLayers;

  /// 21. The pause layers under which nothing of the feed plays, read from
  /// the asset cache scope's clock: no item is `playing` and the pager
  /// pauses its page. Not low power: a power saver stops autoplay
  /// ([lite]), not a video the reader plays.
  final Set<PlaybackPauseLayer> pausingLayers;

  /// 22. Where a clip starts when it plays again.
  final FeedResume resume;

  /// 23. Whether a clip loops.
  final bool loop;

  /// The layers that pause a feed unless the host says otherwise: the
  /// standard ones but low power, which is the autoplay gate's
  /// ([FeedLiteMode]).
  static const Set<PlaybackPauseLayer> standardPausingLayers = {
    PlaybackPauseLayer.routeMoving,
    PlaybackPauseLayer.fastScroll,
    PlaybackPauseLayer.surfaceHidden,
    PlaybackPauseLayer.appInactive,
    PlaybackPauseLayer.overlayShown,
  };

  /// The player budget this policy asks the pool for: one playing, and
  /// [preparedPlayers] warm.
  PlayerBudget get playerBudget => PlayerBudget(prepared: preparedPlayers);

  /// The asset profile a clip of this feed attaches with: it plays, loops as
  /// [loop] says and advances only above the advance floor.
  AssetProfile clipProfile({
    double cornerRadius = 0,
    AssetFit fit = AssetFit.cover,
  }) => AssetProfile(
    animate: true,
    loop: loop,
    cornerRadius: cornerRadius,
    fit: fit,
    advanceFloor: activeItem.advanceFloor,
  );

  /// Whether [item] autoplays under [conditions], through [autoplayGate].
  FeedAutoplay autoplayOf(FeedItem item, FeedConditions conditions) =>
      autoplayGate(item, conditions, this);

  /// What the autoplay gate and the scroll speed leave of a preload [stage]
  /// for [item]: an item that will not play gets its metadata only, one that
  /// gets a prefix at most the prefix, and nothing heavier than a first frame
  /// starts during a [fastScroll].
  AssetPreloadStage boundPreload(
    AssetPreloadStage stage,
    FeedItem item,
    FeedConditions conditions, {
    bool fastScroll = false,
  }) {
    var bounded = switch (autoplayOf(item, conditions)) {
      FeedAutoplay.none => AssetPreloadStage.metadata,
      FeedAutoplay.prefixOnly => _atMostPrefix(stage),
      FeedAutoplay.full => stage,
    };
    if (fastScroll && bounded is AssetPreloadStage$Seconds) {
      bounded = AssetPreloadStage.metadata;
    }
    return bounded;
  }

  AssetPreloadStage _atMostPrefix(AssetPreloadStage stage) {
    final prefix = oversizePrefix;
    if (prefix == null) return AssetPreloadStage.metadata;
    final cap = AssetPreloadStage.seconds(prefix.duration);
    return stage.compareTo(cap) <= 0 ? stage : cap;
  }

  // --- Reference defaults ---------------------------------------------------

  /// The reference autoplay gate.
  ///
  /// The reader's settings come first, as in the reference clients: nothing
  /// of a kind autoplays when its setting is off, and nothing at all under the
  /// power saver ([FeedPolicy.lite]), a file on the device included. Then an
  /// item already on the device plays. Otherwise nothing plays with no
  /// network; a file within the size limit of the network plays in full; a
  /// larger one gets a prefix when prefixes are on and the limit is above the
  /// prefix cap (a small limit means the user saves data); else it does not
  /// play. An unknown size counts as within the limit.
  static FeedAutoplay referenceAutoplayGate(
    FeedItem item,
    FeedConditions conditions,
    FeedPolicy policy,
  ) {
    if (!policy.lite.allows(item, conditions)) return FeedAutoplay.none;
    if (item.local) return FeedAutoplay.full;
    if (conditions.network == FeedNetwork.none) return FeedAutoplay.none;
    final limit = policy.sizeLimits.limitOn(conditions.network);
    final size = item.byteSize;
    if (size == null || size <= limit) return FeedAutoplay.full;
    final prefix = policy.oversizePrefix;
    if (prefix != null && limit > prefix.maxBytes) {
      return FeedAutoplay.prefixOnly;
    }
    return FeedAutoplay.none;
  }

  /// A round video that ends starts the next round video.
  static bool roundsAdvance(FeedItem ended, FeedItem next) =>
      ended.round && next.round;

  /// Always the next item.
  static bool alwaysAdvance(FeedItem ended, FeedItem next) => true;

  /// The list's staging: the items ahead in the scroll direction get their
  /// first frame (cheap on the software path, and what a cell shows first);
  /// nothing behind.
  static AssetPreloadStage? listStaging(int distance) =>
      distance > 0 ? AssetPreloadStage.firstFrame : null;

  /// The pager's staging: the next item 5 s, the previous 3 s, items up to
  /// four away their metadata, nothing further.
  static AssetPreloadStage? pagerStaging(int distance) => switch (distance) {
    1 => const AssetPreloadStage.seconds(Duration(seconds: 5)),
    -1 => const AssetPreloadStage.seconds(Duration(seconds: 3)),
    >= -4 && <= 4 && != 0 => AssetPreloadStage.metadata,
    _ => null,
  };
}
