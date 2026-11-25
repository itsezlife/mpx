import 'package:meta/meta.dart';

/// Which status control a `AssetView` shows over its content.
@immutable
sealed class MediaStatusMode {
  const MediaStatusMode._();

  /// A bare arc of [radius] on its disc while the content downloads and has
  /// no frame, without an icon or taps; it goes on a failure (it offers no
  /// retry), and the surface relies on a re-attach, connectivity and
  /// `AssetBinding.retry`. A grid cell's indicator.
  const factory MediaStatusMode.arc(double radius) = MediaStatusMode$Arc;

  /// The full control in the centre: cancel and an arc while the content
  /// downloads, download while it waits for the user or failed, and play
  /// once it shows when [playAction] is set. Streamable video that is not
  /// local and waiting for the reader shows play in the centre when the host
  /// gives an `onPlay` to stream it, with a compact download control in the
  /// style's corner; a download that runs, or a surface with no `onPlay`,
  /// shows the download's control in the centre.
  const factory MediaStatusMode.control({bool playAction}) =
      MediaStatusMode$Control;

  /// No control.
  static const MediaStatusMode none = MediaStatusMode$None._();

  /// Only the compact control, in the style's corner.
  static const MediaStatusMode compact = MediaStatusMode$Compact._();
}

/// [MediaStatusMode.none].
final class MediaStatusMode$None extends MediaStatusMode {
  const MediaStatusMode$None._() : super._();
}

/// [MediaStatusMode.arc].
final class MediaStatusMode$Arc extends MediaStatusMode {
  /// See [MediaStatusMode.arc].
  const MediaStatusMode$Arc(this.radius) : super._();

  /// The disc's radius.
  final double radius;

  @override
  bool operator ==(Object other) =>
      other is MediaStatusMode$Arc && other.radius == radius;

  @override
  int get hashCode => radius.hashCode;
}

/// [MediaStatusMode.control].
final class MediaStatusMode$Control extends MediaStatusMode {
  /// See [MediaStatusMode.control].
  const MediaStatusMode$Control({this.playAction = false}) : super._();

  /// Whether content that shows offers play.
  final bool playAction;

  @override
  bool operator ==(Object other) =>
      other is MediaStatusMode$Control && other.playAction == playAction;

  @override
  int get hashCode => playAction.hashCode;
}

/// [MediaStatusMode.compact].
final class MediaStatusMode$Compact extends MediaStatusMode {
  const MediaStatusMode$Compact._() : super._();
}
