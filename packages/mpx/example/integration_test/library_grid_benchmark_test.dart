/// Scrolls the library grid over a fake library of 10 000 assets and
/// reports frame timings (`flutter test
/// integration_test/library_grid_benchmark_test.dart -d DEVICE`; on Android
/// it reinstalls the example, wiping its data).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('library grid scroll', (tester) async {
    final library = FakeMediaLibrary(assets: 10000);
    final album = (await library.albums()).single;
    final clock = PlaybackClock(ticks: SchedulerPlaybackTickSource());
    final scope = AssetCacheScope(producer: FakeAssetProducer(), clock: clock);
    final controller = ScrollController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AssetCacheProvider(
          scope: scope,
          child: LibraryGrid(
            library: library,
            album: album,
            selection: OrderedPickerSelection(),
            controller: controller,
            labels: const LibraryGridLabels(
              photo: 'Photo',
              video: 'Video',
              open: 'Open',
              select: 'Select',
              gif: 'GIF',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await binding.watchPerformance(() async {
      for (var i = 0; i < 10; i++) {
        await tester.fling(
          find.byType(LibraryGrid),
          const Offset(0, -2000),
          4000,
        );
        await tester.pumpAndSettle();
      }
    }, reportKey: 'library_grid_scroll');
    controller.dispose();
    scope.dispose();
    clock.dispose();
    await library.dispose();
  });
}
