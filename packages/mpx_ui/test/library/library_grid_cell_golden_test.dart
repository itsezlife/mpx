import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_ui/mpx_ui.dart';

const _labels = LibraryGridLabels(
  photo: 'Photo',
  video: 'Video',
  open: 'Open',
  select: 'Select',
  gif: 'GIF',
);

const _photo = LibraryAsset(
  id: LibraryAssetId('p'),
  kind: LibraryAssetKind.photo,
);
const _video = LibraryAsset(
  id: LibraryAssetId('v'),
  kind: LibraryAssetKind.video,
  duration: Duration(seconds: 75),
  subtypes: {LibraryAssetSubtype.slowMotion},
);
const _gif = LibraryAsset(
  id: LibraryAssetId('g'),
  kind: LibraryAssetKind.photo,
  subtypes: {LibraryAssetSubtype.animated, LibraryAssetSubtype.live},
);

void main() {
  // The baselines sit beside this file, whether it runs alone or inside
  // unit_test.dart (whose comparator would look beside that file). The
  // previous comparator comes back after: the files share the process.
  late GoldenFileComparator previous;
  setUpAll(() {
    previous = goldenFileComparator;
    goldenFileComparator = LocalFileComparator(
      Uri.file(
        '${Directory.current.path}/test/library/'
        'library_grid_cell_golden_test.dart',
      ),
    );
  });
  tearDownAll(() => goldenFileComparator = previous);

  for (final (name, policy) in [
    ('android', LibraryGridPolicy.$Android),
    ('ios', LibraryGridPolicy.$IOS),
  ]) {
    testWidgets('a cell in each state ($name)', (tester) async {
      final clock = PlaybackClock(ticks: ManualPlaybackTickSource());
      final scope = AssetCacheScope(
        producer: FakeAssetProducer(),
        clock: clock,
      );
      addTearDown(() {
        scope.dispose();
        clock.dispose();
      });
      Widget cell(
        LibraryAsset? asset, {
        int? order,
        bool dimmed = false,
        BorderRadius radius = BorderRadius.zero,
      }) => SizedBox.square(
        dimension: 100,
        child: LibraryGridCell(
          asset: asset,
          extent: 100,
          thumbnailPixels: 100,
          policy: policy,
          tokens: const LibraryGridTokens(),
          labels: _labels,
          order: order,
          dimmed: dimmed,
          radius: radius,
          onToggle: () {},
          onOpen: () {},
        ),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: AssetCacheProvider(
            scope: scope,
            child: Center(
              child: RepaintBoundary(
                child: ColoredBox(
                  color: const Color(0xFF000000),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        cell(null),
                        cell(
                          _photo,
                          radius: const BorderRadius.only(
                            topLeft: Radius.circular(16),
                          ),
                        ),
                        cell(_photo, order: 3),
                        cell(_video),
                        cell(_gif, order: 12),
                        cell(_photo, dimmed: true),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(RepaintBoundary).first,
        matchesGoldenFile('goldens/library_grid_cell_$name.png'),
      );
    });
  }
}
