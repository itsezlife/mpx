import 'package:mpx_ui/src/viewer/origin_bridge.dart';

/// An [OriginBridge] with a fixed map of origins. It records what the viewer
/// hides and reveals; [reveal] completes at once unless [revealing] holds it.
final class FakeOriginBridge implements OriginBridge {
  /// Creates a bridge knowing [origins].
  FakeOriginBridge([Map<int, GalleryOrigin>? origins])
    : origins = origins ?? {};

  /// The origin of each index; change it to move or drop an origin.
  final Map<int, GalleryOrigin> origins;

  /// The indexes hidden now.
  final Set<int> hidden = {};

  /// Every hide and show, in order: `(index, hidden)`.
  final List<(int, bool)> hideCalls = [];

  /// Every index [reveal] was asked for.
  final List<int> revealed = [];

  /// When set, [reveal] waits for it.
  Future<void>? revealing;

  @override
  GalleryOrigin? originOf(int index) => origins[index];

  @override
  Future<void> reveal(int index) async {
    revealed.add(index);
    await revealing;
  }

  @override
  void setHidden(int index, {required bool hidden}) {
    hideCalls.add((index, hidden));
    if (hidden) {
      this.hidden.add(index);
    } else {
      this.hidden.remove(index);
    }
  }
}
