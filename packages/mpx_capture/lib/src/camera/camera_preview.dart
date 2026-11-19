import 'package:flutter/widgets.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';

/// Shows a [CameraSession]'s preview: upright, mirrored for a front camera,
/// covering the widget's size by default.
///
/// It only shows: pausing the session when the preview is off screen or
/// covered is the host's call (the library grid's camera slot hands it the
/// signals). [placeholder] stands in while there is no texture (opening,
/// denied, failed, closed, or a fake).
class CameraPreview extends StatelessWidget {
  /// Creates a preview of [session].
  const CameraPreview({
    required this.session,
    this.fit = BoxFit.cover,
    this.placeholder = const SizedBox.expand(),
    super.key,
  });

  /// The session whose camera shows.
  final CameraSession session;

  /// How the frames fill the widget.
  final BoxFit fit;

  /// Shown while there is no texture.
  final Widget placeholder;

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<CameraSessionValue>(
    valueListenable: session.value,
    builder: (context, value, _) {
      final textureId = value.textureId;
      final size = value.previewSize;
      if (!value.isAvailable || textureId == null || size == null) {
        return placeholder;
      }
      Widget frames = SizedBox(
        width: size.width.toDouble(),
        height: size.height.toDouble(),
        child: Texture(textureId: textureId),
      );
      if (value.quarterTurns % 4 != 0) {
        frames = RotatedBox(quarterTurns: value.quarterTurns, child: frames);
      }
      if (value.mirrored) frames = Transform.flip(flipX: true, child: frames);
      return ClipRect(
        child: FittedBox(fit: fit, child: frames),
      );
    },
  );
}
