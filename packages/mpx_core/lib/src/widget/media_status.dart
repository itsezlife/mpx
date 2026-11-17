import 'package:meta/meta.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';

/// The icon a status control shows on its disc.
enum MediaStatusIcon {
  /// No icon: a bare arc, or nothing.
  none,

  /// An arrow down: the content downloads on a tap.
  download,

  /// A cross: a tap stops the download.
  cancel,

  /// A triangle: a tap plays.
  play,

  /// Two bars: a tap pauses.
  pause,
}

/// What a status control shows: an [icon] on a disc, and an arc of
/// [progress] (0 to 1, or turning without one when null) when [arc] is set.
///
/// A plain value, so one control serves downloads, buffering and uploads,
/// and is testable without a cache. [MediaStatus.forTransfer] maps a
/// binding's download to it.
@immutable
final class MediaStatus {
  /// Creates a status.
  const MediaStatus({
    this.icon = MediaStatusIcon.none,
    this.arc = false,
    this.progress,
  });

  /// An [icon] on the disc, without an arc.
  const MediaStatus.icon(this.icon) : arc = false, progress = null;

  /// An arc of [progress] (null turns without one) around [icon].
  const MediaStatus.progress(this.progress, {this.icon = _cancel}) : arc = true;

  /// An arc turning without a progress and no icon: buffering.
  const MediaStatus.spinner()
    : icon = MediaStatusIcon.none,
      arc = true,
      progress = null;

  /// The status of content whose download is [transfer] and whose picture is
  /// at [stage]:
  ///
  /// | Transfer | Stage | Status |
  /// | --- | --- | --- |
  /// | none | below the first frame | none |
  /// | none | first frame or more | play when [playAction], else none |
  /// | waiting | any | cancel, an arc turning without progress |
  /// | receiving | any | cancel, an arc of the bytes received (turning when no total is known) |
  /// | awaiting the user | below the first frame | download |
  /// | failed | any | download (the retry) |
  factory MediaStatus.forTransfer(
    AssetTransfer transfer,
    AssetStage stage, {
    bool playAction = false,
  }) => switch (transfer) {
    AssetTransfer$Waiting() => const MediaStatus.progress(null),
    AssetTransfer$Receiving(:final fraction) => MediaStatus.progress(fraction),
    AssetTransfer$AwaitingUser()
        when stage.index < AssetStage.firstFrame.index =>
      const MediaStatus.icon(MediaStatusIcon.download),
    AssetTransfer$Failed() => const MediaStatus.icon(MediaStatusIcon.download),
    _ when playAction && stage.index >= AssetStage.firstFrame.index =>
      const MediaStatus.icon(MediaStatusIcon.play),
    _ => none,
  };

  static const MediaStatusIcon _cancel = MediaStatusIcon.cancel;

  /// Nothing shows.
  static const MediaStatus none = MediaStatus();

  /// The icon on the disc.
  final MediaStatusIcon icon;

  /// Whether a progress arc shows.
  final bool arc;

  /// The arc's progress, 0 to 1, or null for an arc that turns without one.
  final double? progress;

  /// Whether the control shows at all.
  bool get isVisible => icon != MediaStatusIcon.none || arc;

  @override
  bool operator ==(Object other) =>
      other is MediaStatus &&
      other.icon == icon &&
      other.arc == arc &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(icon, arc, progress);

  @override
  String toString() => 'MediaStatus(${icon.name}, arc: $arc, $progress)';
}

/// What a screen reader says for each icon of a status control. English by
/// default; a host passes its own.
@immutable
final class MediaStatusStrings {
  /// Creates the strings.
  const MediaStatusStrings({
    this.download = 'Download',
    this.cancel = 'Cancel download',
    this.play = 'Play',
    this.pause = 'Pause',
    this.loading = 'Loading',
  });

  /// For [MediaStatusIcon.download].
  final String download;

  /// For [MediaStatusIcon.cancel].
  final String cancel;

  /// For [MediaStatusIcon.play].
  final String play;

  /// For [MediaStatusIcon.pause].
  final String pause;

  /// For an arc with no icon.
  final String loading;

  /// The label of [status], or null when it shows nothing.
  String? labelOf(MediaStatus status) => switch (status.icon) {
    MediaStatusIcon.download => download,
    MediaStatusIcon.cancel => cancel,
    MediaStatusIcon.play => play,
    MediaStatusIcon.pause => pause,
    MediaStatusIcon.none => status.arc ? loading : null,
  };

  @override
  bool operator ==(Object other) =>
      other is MediaStatusStrings &&
      other.download == download &&
      other.cancel == cancel &&
      other.play == play &&
      other.pause == pause &&
      other.loading == loading;

  @override
  int get hashCode => Object.hash(download, cancel, play, pause, loading);
}
