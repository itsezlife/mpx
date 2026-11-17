import 'dart:ui' show Size;

import 'package:mpx_core/src/asset/asset_cache_budgets.dart';
import 'package:mpx_core/src/asset/asset_producer.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/asset/testing/fake_asset_paintable.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';

/// One attempt a [FakeAssetProducer] was asked to make; the test plays the
/// producer by calling [advance], [fail] and [cancelled].
final class FakeAssetAttempt implements AssetTask {
  FakeAssetAttempt._(this.request, this._progress, this.demand);

  /// What was asked for.
  final AssetRequest request;

  final AssetProgress _progress;

  /// What the bindings of the entry want, live.
  final AssetDemand demand;

  /// Whether the scope cancelled this attempt.
  bool isCancelled = false;

  /// Paintables handed to the cache by this attempt.
  final List<FakeAssetPaintable> paintables = [];

  /// Reports [stage] with a fresh paintable and returns it. [frames] gives
  /// the paintable a sequence to play (and makes it animated). An animated
  /// paintable has a first-frame still unless [firstFrameStill] is false.
  FakeAssetPaintable advance(
    AssetStage stage, {
    int bytes = 100,
    AssetTier tier = AssetTier.still,
    bool animated = false,
    List<Duration> frames = const [],
    bool firstFrameStill = true,
    Size? pictureSize,
  }) {
    final plays = animated || frames.isNotEmpty;
    final paintable = FakeAssetPaintable(
      label: '${request.key}@${stage.name}',
      isAnimated: plays,
      frameDurations: frames,
      pictureSize: pictureSize,
      firstFrame: plays && firstFrameStill
          ? FakeAssetPaintable(label: '${request.key}@${stage.name}:frame0')
          : null,
    );
    paintables.add(paintable);
    _progress.advance(stage, paintable, bytes: bytes, tier: tier);
    return paintable;
  }

  /// Reports what the content is.
  void describe(MediaDescriptor descriptor) => _progress.describe(descriptor);

  /// Reports that [fraction] of the content's download has arrived.
  void download(double fraction) => _progress.download(fraction);

  /// Reports a failed attempt.
  void fail(
    Object error, {
    AssetFailureKind kind = AssetFailureKind.transient,
  }) => _progress.fail(error, StackTrace.current, kind);

  /// Reports that the work was cancelled by its own side.
  void cancelled() => _progress.cancelled();

  @override
  void cancel() => isCancelled = true;
}

/// An [AssetProducer] that does nothing by itself: every attempt waits for the
/// test to report.
final class FakeAssetProducer implements AssetProducer {
  /// Whether the scope holds preloads now ([holdPreloads]).
  bool preloadsHeld = false;

  @override
  void holdPreloads({required bool held}) => preloadsHeld = held;

  /// Every descriptor the scope handed over ([know]), oldest first.
  final List<MediaDescriptor> known = [];

  @override
  void know(MediaDescriptor descriptor) => known.add(descriptor);

  /// Every attempt started, oldest first.
  final List<FakeAssetAttempt> attempts = [];

  /// Called inside [produce] for each new attempt, to answer synchronously
  /// like a memory hit.
  void Function(FakeAssetAttempt attempt)? onProduce;

  /// The attempts made for [request].
  List<FakeAssetAttempt> attemptsFor(AssetRequest request) => [
    for (final attempt in attempts)
      if (attempt.request == request) attempt,
  ];

  /// The attempt started last.
  FakeAssetAttempt get last => attempts.last;

  @override
  AssetTask produce(
    AssetRequest request,
    AssetProgress progress,
    AssetDemand demand,
  ) {
    final attempt = FakeAssetAttempt._(request, progress, demand);
    attempts.add(attempt);
    onProduce?.call(attempt);
    return attempt;
  }
}
