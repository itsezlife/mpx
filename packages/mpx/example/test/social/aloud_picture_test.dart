import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/aloud_picture.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

const _key = MediaKey.remote('clip');

void main() {
  late FakePlayerBackend backend;
  late PlayerPool pool;

  setUp(() {
    backend = FakePlayerBackend(autoFirstFrame: false);
    pool = PlayerPool(backend: backend, budget: const PlayerBudget());
  });

  tearDown(() => pool.dispose());

  double opacityOf(WidgetTester tester, Finder child) => tester
      .widget<Opacity>(
        find.ancestor(of: child, matching: find.byType(Opacity)).first,
      )
      .opacity;

  Future<FakePlayerEngine> pumpPicture(WidgetTester tester) async {
    final lease = pool.lease(_key)
      ..seekTo(const Duration(seconds: 5))
      ..play();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AloudPicture(
          lease: lease,
          clip: const SizedBox(key: Key('clip')),
        ),
      ),
    );
    return backend.latestFor(_key)!;
  }

  testWidgets('the clip shows until the player has moved from its first '
      'frame: a cold start draws a frame of another moment first', (
    tester,
  ) async {
    final engine = await pumpPicture(tester);
    const clip = Key('clip');
    expect(opacityOf(tester, find.byKey(clip)), 1);
    expect(find.byType(PlayerView), findsOneWidget);

    engine.renderFirstFrame();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(opacityOf(tester, find.byKey(clip)), 1, reason: 'not moving yet');

    engine.advance(const Duration(milliseconds: 40));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(opacityOf(tester, find.byKey(clip)), 0);
  });
}
