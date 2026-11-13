import 'dart:ui' as ui;

import 'package:mpx_ui/src/viewer/origin_bridge.dart';

/// An [OriginBridge] with a fixed map of origins and frames. It records what
/// the viewer hides and reveals, and every frame it hands out; [reveal]
/// completes at once unless [revealing] holds it.
final class FakeOriginBridge implements OriginBridge {
  /// Creates a bridge knowing [origins].
  FakeOriginBridge([Map<int, GalleryOrigin>? origins])
    : origins = origins ?? {};

  /// The origin of each index; change it to move or drop an origin.
  final Map<int, GalleryOrigin> origins;

  /// The picture of each index. [frameOf] hands out clones; the test owns
  /// these and disposes them.
  final Map<int, ui.Image> frames = {};

  /// Every frame [frameOf] handed out, in order: `(index, frame)`; the
  /// caller owns each.
  final List<(int, ui.Image)> handedFrames = [];

  /// The indexes hidden now.
  final Set<int> hidden = {};

  /// Every hide and show, in order: `(index, hidden)`.
  final List<(int, bool)> hideCalls = [];

  /// Every index [reveal] was asked for.
  final List<int> revealed = [];

  /// Every hand-back: `(index, position)`.
  final List<(int, Duration)> handedBack = [];

  /// When set, [reveal] waits for it.
  Future<void>? revealing;

  @override
  GalleryOrigin? originOf(int index) => origins[index];

  @override
  ui.Image? frameOf(int index) {
    final frame = frames[index]?.clone();
    if (frame != null) handedFrames.add((index, frame));
    return frame;
  }

  @override
  Future<void> reveal(int index) async {
    revealed.add(index);
    await revealing;
  }

  @override
  void handBack(int index, Duration position) =>
      handedBack.add((index, position));

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
