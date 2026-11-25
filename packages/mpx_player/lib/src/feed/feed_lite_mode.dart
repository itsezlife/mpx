import 'package:flutter/foundation.dart';
import 'package:mpx_player/src/feed/feed_item.dart';

/// The reader's autoplay settings and the power saver, as a "lite mode".
///
/// - What autoplays is a setting per kind of media: [autoplayVideos] and
///   [autoplayGifs] (a silent loop). Off, nothing of that kind plays by
///   itself, even a file that is on the device; a tap still plays it.
/// - The power saver is a battery level, not the system's battery saver: at or
///   under [powerSaverLevel] percent nothing autoplays, whatever the
///   settings. 0 never applies it, 100 always does. A device whose battery is
///   unknown never has it applied.
/// - The system's own battery saver counts as the power saver only when the
///   host says so ([osPowerSaverCounts]); a reader who turned it on for the
///   phone's sake did not turn off the feed's videos.
@immutable
final class FeedLiteMode {
  /// Creates the settings; the defaults: both kinds on,
  /// the power saver at 10 %.
  const FeedLiteMode({
    this.autoplayVideos = true,
    this.autoplayGifs = true,
    this.powerSaverLevel = 10,
    this.osPowerSaverCounts = false,
  }) : assert(
         powerSaverLevel >= 0 && powerSaverLevel <= 100,
         'a battery level is a percentage',
       );

  /// Whether videos play by themselves.
  final bool autoplayVideos;

  /// Whether GIFs (silent loops) play by themselves.
  final bool autoplayGifs;

  /// The battery percentage at or under which nothing autoplays; 0 for never.
  final int powerSaverLevel;

  /// Whether the system's battery saver is the power saver too.
  final bool osPowerSaverCounts;

  /// Whether the power saver is on under [conditions].
  bool isPowerSaverApplied(FeedConditions conditions) {
    if (osPowerSaverCounts && conditions.powerSaving) return true;
    if (powerSaverLevel <= 0) return false;
    if (powerSaverLevel >= 100) return true;
    final battery = conditions.batteryLevel;
    return battery != null && battery <= powerSaverLevel;
  }

  /// Whether [item] may autoplay under [conditions] by these settings.
  bool allows(FeedItem item, FeedConditions conditions) {
    if (isPowerSaverApplied(conditions)) return false;
    return (item.descriptor?.silentLoop ?? false)
        ? autoplayGifs
        : autoplayVideos;
  }

  /// These settings with the given fields changed.
  FeedLiteMode copyWith({
    bool? autoplayVideos,
    bool? autoplayGifs,
    int? powerSaverLevel,
    bool? osPowerSaverCounts,
  }) => FeedLiteMode(
    autoplayVideos: autoplayVideos ?? this.autoplayVideos,
    autoplayGifs: autoplayGifs ?? this.autoplayGifs,
    powerSaverLevel: powerSaverLevel ?? this.powerSaverLevel,
    osPowerSaverCounts: osPowerSaverCounts ?? this.osPowerSaverCounts,
  );

  @override
  bool operator ==(Object other) =>
      other is FeedLiteMode &&
      other.autoplayVideos == autoplayVideos &&
      other.autoplayGifs == autoplayGifs &&
      other.powerSaverLevel == powerSaverLevel &&
      other.osPowerSaverCounts == osPowerSaverCounts;

  @override
  int get hashCode => Object.hash(
    autoplayVideos,
    autoplayGifs,
    powerSaverLevel,
    osPowerSaverCounts,
  );
}
