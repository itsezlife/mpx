import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

void main() {
  const key = MediaKey.remote('clip');

  testWidgets('shows the stand-in until the first frame, then the texture', (
    tester,
  ) async {
    final backend = FakePlayerBackend(autoPrepare: false);
    final pool = PlayerPool(backend: backend);
    addTearDown(pool.dispose);
    final lease = pool.lease(key)..prepare();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PlayerView(lease: lease, standIn: const Text('frame')),
      ),
    );
    expect(find.text('frame'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
    expect(lease.viewCount, 1);

    backend.latestFor(key)!.completePrepare();
    await tester.pump();

    expect(find.byType(Texture), findsOneWidget);
    expect(find.text('frame'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    expect(lease.viewCount, 0);
  });
}
