import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';

/// What the feed policy knows about one item: enough to gate its autoplay
/// and size its prefix. The host fills it from its own model.
@immutable
final class FeedItem {
  /// Creates the facts of [key].
  const FeedItem(
    this.key, {
    this.byteSize,
    this.duration,
    this.round = false,
    this.local = false,
    this.hasAudio = true,
    this.descriptor,
    this.downloadContext,
  });

  /// Which media.
  final MediaKey key;

  /// The size of the file in bytes, when known.
  final int? byteSize;

  /// How long it plays, when known.
  final Duration? duration;

  /// Whether it is a round video (a short clip in a circle, with sound when
  /// it plays as the sound owner).
  final bool round;

  /// Whether its bytes are on the device already (sent from here, cached), so
  /// playing it costs no network.
  final bool local;

  /// Whether it has an audio track; a clip without one never takes sound.
  final bool hasAudio;

  /// What the host knows about the media (its preview, thumbnail, size), or
  /// null. A feed view tells the cache before it attaches the item, so the
  /// poster draws the preview and the thumbnail of media the cache has not
  /// seen.
  final MediaDescriptor? descriptor;

  /// Where the item shows, for the cache's auto-download policy: the clip's
  /// tag. Null uses the policy's default.
  final AutoDownloadContext? downloadContext;

  @override
  bool operator ==(Object other) =>
      other is FeedItem &&
      other.key == key &&
      other.byteSize == byteSize &&
      other.duration == duration &&
      other.round == round &&
      other.local == local &&
      other.hasAudio == hasAudio &&
      other.descriptor == descriptor &&
      other.downloadContext == downloadContext;

  @override
  int get hashCode => Object.hash(
    key,
    byteSize,
    duration,
    round,
    local,
    hasAudio,
    descriptor,
    downloadContext,
  );

  @override
  String toString() =>
      'FeedItem($key, byteSize: $byteSize, duration: $duration, '
      'round: $round, local: $local, hasAudio: $hasAudio)';
}

/// The class of the network the device uses now, as the feed weighs it.
enum FeedNetwork {
  /// No usable network.
  none,

  /// Free to use: Wi-Fi, Ethernet.
  unmetered,

  /// Costs the user: mobile data, a data-saving mode.
  metered,

  /// Mobile data abroad.
  roaming,
}

/// How hot the device runs, in the four steps the platforms share.
enum FeedThermal {
  /// Normal.
  nominal,

  /// Warm; nothing to give up yet.
  fair,

  /// Hot: the system throttles.
  serious,

  /// Very hot: the system sheds work.
  critical,
}

/// The device's conditions when the feed decides: network, power, heat and
/// the ringer.
///
/// A snapshot; `FeedSignals` produces it from the host's live signals. The
/// default is what a host without signals assumes: unmetered, not saving
/// power, nominal, not silenced.
@immutable
final class FeedConditions {
  /// Creates a snapshot.
  const FeedConditions({
    this.network = FeedNetwork.unmetered,
    this.powerSaving = false,
    this.thermal = FeedThermal.nominal,
    this.silenced = false,
  });

  /// The network class.
  final FeedNetwork network;

  /// Whether the device saves power.
  final bool powerSaving;

  /// How hot the device runs.
  final FeedThermal thermal;

  /// Whether the ringer or silent switch silences the device: a pager whose
  /// policy follows the ringer (`FeedInitialMute.followRinger`) starts muted.
  final bool silenced;

  /// Whether the device is under stress the feed backs off for: hot enough
  /// that the system throttles.
  bool get stressed => thermal.index >= FeedThermal.serious.index;

  @override
  bool operator ==(Object other) =>
      other is FeedConditions &&
      other.network == network &&
      other.powerSaving == powerSaving &&
      other.thermal == thermal &&
      other.silenced == silenced;

  @override
  int get hashCode => Object.hash(network, powerSaving, thermal, silenced);

  @override
  String toString() =>
      'FeedConditions(${network.name}, powerSaving: $powerSaving, '
      'thermal: ${thermal.name}, silenced: $silenced)';
}
