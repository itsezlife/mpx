import 'package:meta/meta.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';

/// The icon a status control shows on its disc.
enum MediaStatusIcon {
  /// No icon: a bare arc, or nothing.
  none,

  /// An arrow down: the content downloads on a tap.
  download,

  /// A cross: a tap stops the download, or the upload when the status is
  /// an upload's ([MediaStatus.upload]).
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
/// binding's transfer, either way, to it.
@immutable
final class MediaStatus {
  /// Creates a status.
  const MediaStatus({
    this.icon = MediaStatusIcon.none,
    this.arc = false,
    this.progress,
    this.upload = false,
  });

  /// An [icon] on the disc, without an arc.
  const MediaStatus.icon(this.icon)
    : arc = false,
      progress = null,
      upload = false;

  /// An arc of [progress] (null turns without one) around [icon]; an
  /// [upload]'s arc counts the bytes sent, and its cancel stops the upload.
  const MediaStatus.progress(
    this.progress, {
    this.icon = _cancel,
    this.upload = false,
  }) : arc = true;

  /// An arc turning without a progress and no icon: buffering.
  const MediaStatus.spinner()
    : icon = MediaStatusIcon.none,
      arc = true,
      progress = null,
      upload = false;

  /// The status of content whose transfer is [transfer] and whose picture is
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
  /// | sending | any | an upload's cancel, an arc of the bytes sent (turning when no total is known) |
  /// | sent | any | as none: no ring, the picture kept |
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
    AssetTransfer$Sending(:final fraction) => MediaStatus.progress(
      fraction,
      upload: true,
    ),
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

  /// Whether the status is an upload's: its arc counts the bytes sent and
  /// its cancel stops the upload, which a screen reader says
  /// ([MediaStatusStrings.cancelUpload]).
  final bool upload;

  /// Whether the control shows at all.
  bool get isVisible => icon != MediaStatusIcon.none || arc;

  @override
  bool operator ==(Object other) =>
      other is MediaStatus &&
      other.icon == icon &&
      other.arc == arc &&
      other.progress == progress &&
      other.upload == upload;

  @override
  int get hashCode => Object.hash(icon, arc, progress, upload);

  @override
  String toString() =>
      'MediaStatus(${icon.name}, arc: $arc, $progress'
      '${upload ? ', upload' : ''})';
}

/// What a screen reader says for each icon of a status control. English by
/// default; a host passes its own.
@immutable
final class MediaStatusStrings {
  /// Creates the strings.
  const MediaStatusStrings({
    this.download = 'Download',
    this.cancel = 'Cancel download',
    this.cancelUpload = 'Cancel upload',
    this.play = 'Play',
    this.pause = 'Pause',
    this.loading = 'Loading',
  });

  /// For [MediaStatusIcon.download].
  final String download;

  /// For [MediaStatusIcon.cancel] of a download.
  final String cancel;

  /// For [MediaStatusIcon.cancel] of an upload ([MediaStatus.upload]).
  final String cancelUpload;

  /// For [MediaStatusIcon.play].
  final String play;

  /// For [MediaStatusIcon.pause].
  final String pause;

  /// For an arc with no icon.
  final String loading;

  /// The label of [status], or null when it shows nothing.
  String? labelOf(MediaStatus status) => switch (status.icon) {
    MediaStatusIcon.download => download,
    MediaStatusIcon.cancel => status.upload ? cancelUpload : cancel,
    MediaStatusIcon.play => play,
    MediaStatusIcon.pause => pause,
    MediaStatusIcon.none => status.arc ? loading : null,
  };

  @override
  bool operator ==(Object other) =>
      other is MediaStatusStrings &&
      other.download == download &&
      other.cancel == cancel &&
      other.cancelUpload == cancelUpload &&
      other.play == play &&
      other.pause == pause &&
      other.loading == loading;

  @override
  int get hashCode =>
      Object.hash(download, cancel, cancelUpload, play, pause, loading);
}
