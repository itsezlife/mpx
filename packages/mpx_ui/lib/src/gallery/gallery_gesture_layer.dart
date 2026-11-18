import 'package:flutter/widgets.dart';
import 'package:mpx_ui/src/gallery/gallery_gesture_recognizer.dart';
import 'package:mpx_ui/src/gallery/gallery_tap_recognizer.dart';

/// The gallery's two recognizers over [child]: the gesture owner and the
/// tap recognizer, side by side in one arena. Controls placed above this
/// layer as siblings never enter its arena; controls inside [child] compete
/// and win their own taps.
class GalleryGestureLayer extends StatelessWidget {
  /// Creates the layer.
  const GalleryGestureLayer({
    required this.drag,
    required this.taps,
    required this.tapRules,
    required this.child,
    super.key,
  });

  /// Where the decided drags go.
  final GalleryDragTarget drag;

  /// Where the taps go.
  final GalleryTapTarget taps;

  /// The tap timings.
  final GalleryTapRules tapRules;

  /// The media.
  final Widget child;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      GalleryGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<GalleryGestureRecognizer>(
            () => GalleryGestureRecognizer(debugOwner: this),
            (recognizer) => recognizer
              ..target = drag
              ..panSlop = tapRules.tapSlop,
          ),
      GalleryTapRecognizer:
          GestureRecognizerFactoryWithHandlers<GalleryTapRecognizer>(
            () => GalleryTapRecognizer(debugOwner: this),
            (recognizer) => recognizer
              ..target = taps
              ..rules = tapRules,
          ),
    },
    child: child,
  );
}
