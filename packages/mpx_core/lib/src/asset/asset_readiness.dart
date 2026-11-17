import 'package:meta/meta.dart';

/// How far an asset has come, in order. There is no failed stage: an asset
/// that cannot be produced stays at the stage it reached (a preview or a
/// thumbnail, if any) and is retried; see `AssetBinding.lastError`.
///
/// [preview] and [placeholder] are stand-ins: an `index` at or below
/// [placeholder] means the content itself has nothing to show yet.
enum AssetStage {
  /// Nothing is known to draw yet; the binding paints the scope's placeholder.
  none,

  /// A stand-in known without any fetch: the preview the descriptor carries
  /// (`MediaDescriptor.preview`), or one the cache derived before.
  preview,

  /// A fetched stand-in is available (a thumbnail).
  placeholder,

  /// The first frame, as a plain still, is available.
  firstFrame,

  /// The whole asset is available.
  full,
}

/// A binding's [stage] and whether it is [isFinal].
///
/// Final means nothing better will arrive for this entry, so a surface can
/// stop waiting: `full`, or `firstFrame` for a spec that asked for the first
/// frame only. A stage short of final is not an error, only unfinished.
@immutable
final class AssetReadiness {
  /// Creates a readiness at [stage].
  const AssetReadiness(this.stage, {this.isFinal = false});

  /// The best stage reached.
  final AssetStage stage;

  /// Whether no later stage will come.
  final bool isFinal;

  @override
  bool operator ==(Object other) =>
      other is AssetReadiness &&
      other.stage == stage &&
      other.isFinal == isFinal;

  @override
  int get hashCode => Object.hash(stage, isFinal);

  @override
  String toString() => 'AssetReadiness(${stage.name}, isFinal: $isFinal)';
}
