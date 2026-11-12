import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/testing.dart';

void main() {
  group('FakePlayerBackend', () {
    const broken = MediaKey.remote('broken');
    PlayerEngineContract.run(
      () => PlayerEngineHarness(
        backend: FakePlayerBackend(unplayable: {broken}),
        playable: const MediaKey.remote('clip'),
        unplayable: broken,
        settle: () => Future<void>.delayed(Duration.zero),
      ),
    );
  });
}
