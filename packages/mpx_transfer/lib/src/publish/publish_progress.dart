import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';

/// How a publish job's progress is weighted: what share of an item its
/// preparation takes, by the kind of preparation, and what share of the
/// whole job the publisher's call takes.
///
/// A job's progress is byte-weighted: each item weighs its source's size
/// until its preparation ends, then the bytes it uploads; an item sent as
/// remote weighs nothing and an item the reuse table answered is done at
/// once. Within an item, the preparation share runs with the preparation
/// and the rest with the upload; an item that needs no preparation is all
/// upload. The items together fill the job up to `1 - publish`; the last
/// [publish] share fills when the publisher answers, so a ring is nearly
/// full while the request is in flight.
///
/// The values shown on a job and an item never go back: a re-estimate (a
/// prepared size replacing the source's, an upload's total growing) is
/// folded in, so the remaining part of the ring stretches over the new
/// remaining work instead of the ring shrinking.
@immutable
final class PublishProgressWeights {
  /// Weights; each one 0..1 and [publish] below 1.
  const PublishProgressWeights({
    this.videoPreparation = defaultVideoPreparation,
    this.photoPreparation = defaultPhotoPreparation,
    this.filePreparation = defaultFilePreparation,
    this.publish = defaultPublish,
  }) : assert(
         videoPreparation >= 0 && videoPreparation <= 1,
         'A preparation share is a fraction of its item, 0..1.',
       ),
       assert(
         photoPreparation >= 0 && photoPreparation <= 1,
         'A preparation share is a fraction of its item, 0..1.',
       ),
       assert(
         filePreparation >= 0 && filePreparation <= 1,
         'A preparation share is a fraction of its item, 0..1.',
       ),
       assert(
         publish >= 0 && publish < 1,
         'The publish share leaves some of the job to its items.',
       );

  /// The weights a facade uses unless given others.
  static const PublishProgressWeights standard = PublishProgressWeights();

  /// [videoPreparation] unless given: a conversion is long.
  static const double defaultVideoPreparation = 0.3;

  /// [photoPreparation] unless given: encoding a still is quick.
  static const double defaultPhotoPreparation = 0.02;

  /// [filePreparation] unless given: a file is sent as it is.
  static const double defaultFilePreparation = 0.02;

  /// [publish] unless given.
  static const double defaultPublish = 0.05;

  /// The share of a video item its preparation takes.
  final double videoPreparation;

  /// The share of a photo item its preparation takes.
  final double photoPreparation;

  /// The share of a file item its preparation takes.
  final double filePreparation;

  /// The share of the whole job the publisher's call takes.
  final double publish;

  /// The share of an item prepared for [intent] its preparation takes.
  double preparationOf(PreparationIntent intent) => switch (intent) {
    PreparationIntent$Video() => videoPreparation,
    PreparationIntent$Photo() => photoPreparation,
    PreparationIntent$File() => filePreparation,
  };

  @override
  bool operator ==(Object other) =>
      other is PublishProgressWeights &&
      other.videoPreparation == videoPreparation &&
      other.photoPreparation == photoPreparation &&
      other.filePreparation == filePreparation &&
      other.publish == publish;

  @override
  int get hashCode =>
      Object.hash(videoPreparation, photoPreparation, filePreparation, publish);

  @override
  String toString() =>
      'PublishProgressWeights(video $videoPreparation, photo '
      '$photoPreparation, file $filePreparation, publish $publish)';
}

/// A progress value that never goes back, fed the value as computed now.
///
/// Clamping alone (the larger of the last value and the new one) would
/// hold the ring still after a re-estimate until the work caught up with
/// it. Instead a drop moves only the base, and each later rise of the
/// computed value fills the same fraction of what remains above the shown
/// value as it fills of what remains above the base: the ring keeps moving
/// and still reaches 1 exactly when the work does.
///
/// Internal to the package.
@internal
final class ProgressFold {
  /// A fold starting at [floor]: the value a journal kept, or 0.
  ProgressFold([this._value = 0]);

  double _value;
  double? _base;

  /// The value shown now.
  double get value => _value;

  /// Folds [computed] (0..1) in; answers the value shown. Feeding the same
  /// value again changes nothing.
  double fold(double computed) {
    final next = computed.clamp(0.0, 1.0);
    final base = _base;
    if (next >= 1) {
      _value = 1;
    } else if (base == null) {
      if (next > _value) _value = next;
    } else if (next > base) {
      _value += (next - base) * (1 - _value) / (1 - base);
      if (_value > 1) _value = 1;
    }
    _base = next;
    return _value;
  }
}

/// One item as a job's progress counts it: its [weight] in bytes (null
/// while unknown) and its [fraction] done, 0..1.
typedef ItemMeasure = ({int? weight, double fraction});

/// A job's items as its progress counts them together.
///
/// Internal to the package.
@internal
extension ItemMeasures on List<ItemMeasure> {
  /// The items together, before the publish share: each item's fraction by
  /// its weight. An item whose weight is not known yet weighs as much as the
  /// known ones on average (one byte when none is known); a job with no
  /// items, or only weightless ones, counts its items alike.
  double get fraction {
    final items = this;
    if (items.isEmpty) return 1;
    final known = [for (final item in items) ?item.weight];
    final fallback = known.isEmpty
        ? 1.0
        : known.fold(0, (sum, weight) => sum + weight) / known.length;
    var total = 0.0;
    var done = 0.0;
    for (final item in items) {
      final weight = item.weight?.toDouble() ?? fallback;
      total += weight;
      done += weight * item.fraction;
    }
    if (total <= 0) {
      var sum = 0.0;
      for (final item in items) {
        sum += item.fraction;
      }
      return sum / items.length;
    }
    return done / total;
  }
}
