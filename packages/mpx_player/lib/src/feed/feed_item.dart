import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';

/// What the feed policy knows about one item: enough to gate its autoplay,
/// size its prefix and pick its off-screen behaviour. The host fills it from
/// its own model.
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

  @override
  bool operator ==(Object other) =>
      other is FeedItem &&
      other.key == key &&
      other.byteSize == byteSize &&
      other.duration == duration &&
      other.round == round &&
      other.local == local &&
      other.hasAudio == hasAudio;

  @override
  int get hashCode =>
      Object.hash(key, byteSize, duration, round, local, hasAudio);

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

/// The device's conditions when the feed decides: network, power and heat.
///
/// A snapshot; `FeedSignals` produces it from the host's live signals. The
/// default is what a host without signals assumes: unmetered, not saving
/// power, nominal.
@immutable
final class FeedConditions {
  /// Creates a snapshot.
  const FeedConditions({
    this.network = FeedNetwork.unmetered,
    this.powerSaving = false,
    this.thermal = FeedThermal.nominal,
  });

  /// The network class.
  final FeedNetwork network;

  /// Whether the device saves power.
  final bool powerSaving;

  /// How hot the device runs.
  final FeedThermal thermal;

  /// Whether the device is under stress the feed backs off for: hot enough
  /// that the system throttles.
  bool get stressed => thermal.index >= FeedThermal.serious.index;

  @override
  bool operator ==(Object other) =>
      other is FeedConditions &&
      other.network == network &&
      other.powerSaving == powerSaving &&
      other.thermal == thermal;

  @override
  int get hashCode => Object.hash(network, powerSaving, thermal);

  @override
  String toString() =>
      'FeedConditions(${network.name}, powerSaving: $powerSaving, '
      'thermal: ${thermal.name})';
}
