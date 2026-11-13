import 'package:flutter/widgets.dart';
import 'package:mpx_capture/src/round/round_video_recorder.dart';

/// Shows the camera of a [RoundVideoRecording] as the round it records: the
/// centre square of the preview frames, clipped to a circle, filling the
/// widget's size. Draws nothing when the recording has no texture.
class RoundVideoPreview extends StatelessWidget {
  /// Creates a preview of [recording].
  const RoundVideoPreview({required this.recording, super.key});

  /// The recording whose camera shows.
  final RoundVideoRecording recording;

  @override
  Widget build(BuildContext context) {
    final textureId = recording.textureId;
    if (textureId == null) return const SizedBox.expand();
    final size = recording.previewSize;
    return ClipOval(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: size.width.toDouble(),
          height: size.height.toDouble(),
          child: Texture(textureId: textureId),
        ),
      ),
    );
  }
}
