import 'dart:async';
import 'dart:typed_data';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/native/platform_still.dart';

/// An in-memory [PlatformStillBackend] for tests: it draws a grey still of
/// the size asked for, answers at once or when the test says, and records
/// what it was asked and which requests were cancelled.
final class FakePlatformStillBackend implements PlatformStillBackend {
  /// Creates a backend that draws every source but the [unreadable] ones.
  FakePlatformStillBackend();

  /// Keys and paths of sources the platform cannot draw: answered null.
  final Set<String> unreadable = {};

  /// Whether answers wait for [answerHeld].
  bool hold = false;

  /// Every request, oldest first.
  final List<PlatformStillRequest> requests = [];

  /// The requests whose cancellation fired, oldest first.
  final List<PlatformStillRequest> cancelled = [];

  final List<void Function()> _held = [];

  /// Answers every held request.
  void answerHeld() {
    final held = List.of(_held);
    _held.clear();
    for (final answer in held) {
      answer();
    }
  }

  @override
  Future<PlatformStill?> extract(
    PlatformStillRequest request,
    CancellationToken cancellation,
  ) {
    requests.add(request);
    cancellation.onCancel(() => cancelled.add(request));
    final completer = Completer<PlatformStill?>();
    void answer() => completer.complete(_draw(request));
    if (hold) {
      _held.add(answer);
    } else {
      scheduleMicrotask(answer);
    }
    return completer.future;
  }

  PlatformStill? _draw(PlatformStillRequest request) {
    final name = switch (request.source) {
      PlatformStillSource$Ranged(:final key) => key,
      PlatformStillSource$File(:final path) => path,
    };
    if (unreadable.contains(name)) return null;
    final width = request.maxWidth;
    final height = request.maxHeight;
    return PlatformStill(
      width: width,
      height: height,
      rgba: Uint8List(width * height * 4)
        ..fillRange(0, width * height * 4, 0x80),
    );
  }
}
