import 'package:meta/meta.dart';

/// How far a staged preload takes content nobody shows yet.
///
/// Stages are ordered: [metadata] < [seconds] (shorter before longer) <
/// [firstFrame]. Several preloads of one entry ask for the furthest of their
/// stages; a binding asks for everything.
@immutable
sealed class AssetPreloadStage implements Comparable<AssetPreloadStage> {
  const AssetPreloadStage._();

  /// The first [duration] of the content's bytes, fetched and not decoded:
  /// what a player starts from. The fetcher resolves the duration to bytes
  /// (`FetchRequest.prefix`).
  const factory AssetPreloadStage.seconds(Duration duration) =
      AssetPreloadStage$Seconds;

  /// Only what is known about the content: its descriptor, resolved through
  /// the host's resolver if the pipeline does not know it. No bytes.
  static const AssetPreloadStage metadata = AssetPreloadStage$Metadata._();

  /// The content fetched and decoded to its first frame.
  static const AssetPreloadStage firstFrame = AssetPreloadStage$FirstFrame._();

  /// The further of this stage and [other].
  AssetPreloadStage furthest(AssetPreloadStage other) =>
      compareTo(other) >= 0 ? this : other;

  int get _rank;

  @override
  int compareTo(AssetPreloadStage other) {
    final byRank = _rank.compareTo(other._rank);
    if (byRank != 0) return byRank;
    return switch ((this, other)) {
      (
        AssetPreloadStage$Seconds(duration: final a),
        AssetPreloadStage$Seconds(duration: final b),
      ) =>
        a.compareTo(b),
      _ => 0,
    };
  }
}

/// [AssetPreloadStage.metadata].
final class AssetPreloadStage$Metadata extends AssetPreloadStage {
  const AssetPreloadStage$Metadata._() : super._();

  @override
  int get _rank => 0;

  @override
  String toString() => 'AssetPreloadStage.metadata';
}

/// [AssetPreloadStage.seconds].
final class AssetPreloadStage$Seconds extends AssetPreloadStage {
  /// Creates the stage; [duration] is positive (a const constructor cannot
  /// compare durations, so it is not asserted).
  const AssetPreloadStage$Seconds(this.duration) : super._();

  /// How much of the content, from its start.
  final Duration duration;

  @override
  int get _rank => 1;

  @override
  bool operator ==(Object other) =>
      other is AssetPreloadStage$Seconds && other.duration == duration;

  @override
  int get hashCode => duration.hashCode;

  @override
  String toString() => 'AssetPreloadStage.seconds($duration)';
}

/// [AssetPreloadStage.firstFrame].
final class AssetPreloadStage$FirstFrame extends AssetPreloadStage {
  const AssetPreloadStage$FirstFrame._() : super._();

  @override
  int get _rank => 2;

  @override
  String toString() => 'AssetPreloadStage.firstFrame';
}

/// A live staged preload, from `AssetCacheScope.preload` until [cancel].
///
/// It pins its entry as a hidden binding would, so what it fetched stays
/// until it is cancelled.
abstract interface class AssetPreload {
  /// How far the preload takes its entry.
  AssetPreloadStage get stage;

  /// Where the entry stands in the host's order of preloads: 0 for the next
  /// item, larger further away. Among preloads, a lower distance is served
  /// first.
  int get distance;

  /// Whether [cancel] has run.
  bool get isCancelled;

  /// Gives the preload back. The last claim on an entry (no binding, no other
  /// preload) cancels its running attempt; what it reached waits in the
  /// budget like any unattached entry. Idempotent.
  void cancel();
}
