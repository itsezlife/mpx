import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

// A clip plays as a silent loop in its bubble (the software path) and opens
// fullscreen on the player: the player starts where the loop is, the bubble's
// frame shows until the player's first frame, and closing hands the
// player's position back to the bubble.
void main() {
  const clip = MediaKey.remote('clip');
  const bubblePosition = Duration(seconds: 12);

  testWidgets('the player starts at the bubble position, and the bubble '
      'frame shows until its first frame', (tester) async {
    final backend = FakePlayerBackend(autoFirstFrame: false);
    final pool = PlayerPool(backend: backend);
    addTearDown(pool.dispose);

    final lease = pool.lease(clip)
      ..seekTo(bubblePosition)
      ..play();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PlayerView(lease: lease, standIn: const Text('bubble frame')),
      ),
    );
    await tester.pump();

    final engine = backend.latestFor(clip)!;
    expect(engine.preparedFrom, bubblePosition);
    expect(lease.state.value.phase, PlayerPhase.ready);
    // Ready, but no frame in the texture yet: the bubble's frame stays.
    expect(find.text('bubble frame'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);

    engine.renderFirstFrame();
    await tester.pump();

    expect(find.byType(Texture), findsOneWidget);
    expect(find.text('bubble frame'), findsNothing);
  });

  test('closing hands the position back for the bubble', () async {
    final backend = FakePlayerBackend();
    final pool = PlayerPool(backend: backend);
    addTearDown(pool.dispose);
    final lease = pool.lease(clip)
      ..seekTo(bubblePosition)
      ..play();
    await Future<void>.delayed(Duration.zero);
    backend.latestFor(clip)!.advance(const Duration(seconds: 5));

    final handBack = lease.position;
    lease.release();

    expect(handBack, const Duration(seconds: 17));
    expect(backend.latestFor(clip)!.state.value.playing, isFalse);
  });

  test('a warm player is moved to the bubble position', () async {
    final backend = FakePlayerBackend();
    final pool = PlayerPool(backend: backend);
    addTearDown(pool.dispose);
    pool.lease(clip)
      ..prepare()
      ..release();
    await Future<void>.delayed(Duration.zero);

    final lease = pool.lease(clip)
      ..seekTo(bubblePosition)
      ..play();

    expect(backend.created, hasLength(1));
    expect(lease.position, bubblePosition);
  });
}
