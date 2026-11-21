import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

const gridLabels = LibraryGridLabels(
  photo: 'Photo',
  video: 'Video',
  open: 'Open',
  select: 'Select',
  gif: 'GIF',
  camera: 'Camera',
);

const stateLabels = LibraryPickerLabels(
  allMedia: 'All media',
  allPhotos: 'All photos',
  allVideos: 'All videos',
  cameraAlbum: 'Camera',
  favourites: 'Favourites',
  empty: 'No photos yet',
  deniedTitle: 'Access to media',
  deniedText: 'Allow access to your photos and videos.',
  allowAccess: 'Allow access',
  openSettings: 'Open Settings',
  camera: 'Camera',
  restricted: 'Access is restricted',
  limitedText: 'You allowed some photos',
  manage: 'Manage',
  selectMore: 'Select more photos',
  changeSettings: 'Change settings',
  partialText: 'You allowed some photos and videos',
  cameraDeniedText: 'Allow camera access',
);

MediaKey key(int index) =>
    LibraryKeys.libraryKeyOf(FakeMediaLibrary.assetAt(index));

/// A picker over a fake library in a 390 x 800 window.
final class PickerHarness {
  PickerHarness({
    int assets = 30,
    LibraryAccess access = LibraryAccess.full,
    LibraryAccess grantOnRequest = LibraryAccess.full,
  }) : library = FakeMediaLibrary(
         assets: assets,
         access: access,
         grantOnRequest: grantOnRequest,
       ) {
    clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    scope = AssetCacheScope(producer: producer, clock: clock);
  }

  final FakeMediaLibrary library;

  /// What the surfaces see of the screen, when a test drives it frame by
  /// frame (a keyboard animating); the pump's values when null.
  final ValueNotifier<MediaQueryData?> media = ValueNotifier(null);
  final FakeAssetProducer producer = FakeAssetProducer();
  late final PlaybackClock clock;
  late final AssetCacheScope scope;
  final OrderedPickerSelection selection = OrderedPickerSelection();
  final List<(MediaKey, PickerRefusal)> refusals = [];
  final List<PickerViewerItem> slotItems = [];
  int cameras = 0;
  int cameraTaps = 0;
  int cameraLongPresses = 0;
  final List<CameraSlotSignals> signals = [];

  Future<void> pump(
    WidgetTester tester, {
    LibraryGridPolicy policy = LibraryGridPolicy.$Android,
    bool mediaAllowed = true,
    bool cameraDenied = false,
    bool cameraSlot = false,
    PickerSelection? picker,
    bool viewerSlot = false,
    bool reorder = false,
    double keyboard = 0,
    double top = 0,
    String? viewerTitle,
    bool slotHoldsKeyboard = false,
    void Function(List<MediaKey> keys)? onRemoved,
    ScrollController? controller,
    LibraryGridLookup? lookup,
    Widget Function(BuildContext context, Widget grid)? gridBuilder,
    ValueListenable<List<PickerCapture>>? captures,
    bool opensFirstCapture = true,
    VoidCallback? onViewerClosed,
    Key? pickerKey,
  }) async {
    tester.view
      ..physicalSize = const Size(390, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      scope.dispose();
      clock.dispose();
      await library.dispose();
    });
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<MediaQueryData?>(
          valueListenable: media,
          builder: (context, override, child) => MediaQuery(
            data:
                override ??
                MediaQueryData(
                  size: const Size(390, 800),
                  viewInsets: EdgeInsets.only(bottom: keyboard),
                  padding: EdgeInsets.only(top: top),
                  viewPadding: EdgeInsets.only(top: top),
                ),
            child: child!,
          ),
          child: AssetCacheProvider(
            scope: scope,
            // A host that gives no text root: every surface sets its own.
            child: unthemedHost(
              Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (context, _, _) => LibraryPicker(
                    library: library,
                    selection: picker ?? selection,
                    labels: gridLabels,
                    stateLabels: stateLabels,
                    policy: policy,
                    mediaAllowed: mediaAllowed,
                    notAllowedText: 'Media is not allowed here',
                    cameraDenied: cameraDenied,
                    onCamera: () => cameras++,
                    onCameraTap: () => cameraTaps++,
                    onCameraLongPress: () => cameraLongPresses++,
                    onRefused: (key, reason) => refusals.add((key, reason)),
                    controller: controller,
                    lookup: lookup,
                    gridBuilder: gridBuilder,
                    key: pickerKey,
                    captures: captures,
                    opensFirstCapture: opensFirstCapture,
                    onViewerClosed: onViewerClosed,
                    cameraSlotBuilder: cameraSlot
                        ? (context, value) {
                            signals.add(value.value);
                            value.addListener(() => signals.add(value.value));
                            return const SizedBox.expand(
                              key: ValueKey('camera'),
                            );
                          }
                        : null,
                    onReorder: reorder ? selection.move : null,
                    viewerTitle: viewerTitle,
                    viewerBottomSlotHoldsKeyboard: slotHoldsKeyboard,
                    onRemoved: onRemoved,
                    viewerBottomBuilder: viewerSlot
                        ? (context, item) {
                            slotItems.add(item);
                            return const SizedBox(
                              key: ValueKey('slot'),
                              height: 60,
                            );
                          }
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// Pumps four 50 ms frames, then checks no text on screen is drawn in a
  /// fallback style.
  static Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expectThemedText(tester);
  }
}

Finder cell(int index) => find.byKey(ValueKey(key(index)));

void main() {
  group('access states', () {
    testWidgets('not determined asks once and shows the outcome', (
      tester,
    ) async {
      final h = PickerHarness(
        access: LibraryAccess.notDetermined,
        grantOnRequest: LibraryAccess.denied,
      );
      await h.pump(tester);
      expect(h.library.requestAccessCalls, 1);
      expect(find.text('Access to media'), findsOneWidget);
    });

    testWidgets(r'denied on $Android: camera and access buttons', (
      tester,
    ) async {
      final h = PickerHarness(access: LibraryAccess.denied);
      await h.pump(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-denied-camera')));
      expect(h.cameras, 1);
      await tester.tap(find.byKey(const ValueKey('mpx-denied-access')));
      await PickerHarness.settle(tester);
      expect(h.library.requestAccessCalls, 1);
      expect(h.library.openSettingsCalls, 1, reason: 'still denied: settings');
      expect(find.byType(LibraryGrid), findsNothing);
    });

    testWidgets(r'denied on $IOS: Open Settings and a camera tile', (
      tester,
    ) async {
      final h = PickerHarness(access: LibraryAccess.denied);
      await h.pump(tester, policy: LibraryGridPolicy.$IOS);
      await tester.tap(find.byKey(const ValueKey('mpx-denied-settings')));
      expect(h.library.openSettingsCalls, 1);
      await tester.tap(find.byKey(const ValueKey('mpx-denied-camera-tile')));
      expect(h.cameras, 1);
    });

    testWidgets('restricted shows the host text', (tester) async {
      final h = PickerHarness(access: LibraryAccess.restricted);
      await h.pump(tester);
      expect(find.text('Access is restricted'), findsOneWidget);
    });

    testWidgets(r'limited on $IOS: the Manage banner and its menu', (
      tester,
    ) async {
      final h = PickerHarness(access: LibraryAccess.limited);
      await h.pump(tester, policy: LibraryGridPolicy.$IOS);
      expect(find.byType(LibraryGrid), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mpx-limited-banner')));
      await PickerHarness.settle(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-manage-0')));
      await PickerHarness.settle(tester);
      expect(h.library.manageSelectedCalls, 1);
      await tester.tap(find.byKey(const ValueKey('mpx-limited-banner')));
      await PickerHarness.settle(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-manage-1')));
      await PickerHarness.settle(tester);
      expect(h.library.openSettingsCalls, 1);
    });

    testWidgets(r'partial on $Android: a banner that asks again', (
      tester,
    ) async {
      final h = PickerHarness(access: LibraryAccess.partial);
      await h.pump(tester);
      expect(find.byType(LibraryGrid), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mpx-partial-banner')));
      await PickerHarness.settle(tester);
      expect(h.library.manageSelectedCalls, 1);
    });

    testWidgets('not allowed hides the grid behind the host text', (
      tester,
    ) async {
      final h = PickerHarness();
      await h.pump(tester, mediaAllowed: false);
      expect(find.text('Media is not allowed here'), findsOneWidget);
      expect(find.byType(LibraryGrid), findsNothing);
    });

    testWidgets('an empty library shows the empty text', (tester) async {
      final h = PickerHarness(assets: 0);
      await h.pump(tester);
      expect(find.text('No photos yet'), findsOneWidget);
    });

    testWidgets('a transition to full access shows the grid', (tester) async {
      final h = PickerHarness(access: LibraryAccess.denied);
      await h.pump(tester);
      h.library.setAccess(LibraryAccess.full);
      await PickerHarness.settle(tester);
      expect(find.byType(LibraryGrid), findsOneWidget);
      expect(cell(0), findsOneWidget);
    });
  });

  testWidgets('the host wraps the grid alone and reaches it through its '
      'controller and lookup', (tester) async {
    final h = PickerHarness(assets: 300);
    final controller = ScrollController();
    final lookup = LibraryGridLookup();
    addTearDown(controller.dispose);
    addTearDown(lookup.dispose);
    await h.pump(
      tester,
      controller: controller,
      lookup: lookup,
      gridBuilder: (context, grid) =>
          KeyedSubtree(key: const ValueKey('wrap'), child: grid),
    );
    final wrap = find.byKey(const ValueKey('wrap'));
    expect(
      find.descendant(of: wrap, matching: find.byType(LibraryGrid)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: wrap, matching: find.byType(LibraryAlbumSwitcher)),
      findsNothing,
    );
    expect(controller.hasClients, isTrue);
    expect(lookup.assetAt(0)?.id, FakeMediaLibrary.assetAt(0).id);
  });

  group('camera denied', () {
    testWidgets(r'$IOS: a banner and no camera slot', (tester) async {
      final h = PickerHarness();
      await h.pump(
        tester,
        policy: LibraryGridPolicy.$IOS,
        cameraDenied: true,
        cameraSlot: true,
      );
      expect(
        find.byKey(const ValueKey('mpx-camera-denied-banner')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('camera')), findsNothing);
    });

    testWidgets(r'$Android: the slot stays and its builder is told', (
      tester,
    ) async {
      final h = PickerHarness();
      await h.pump(tester, cameraDenied: true, cameraSlot: true);
      expect(find.byKey(const ValueKey('camera')), findsOneWidget);
      expect(h.signals.last.cameraDenied, isTrue);
    });
  });

  group('camera slot', () {
    testWidgets('tap and long press reach the host; it is a Camera button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final h = PickerHarness();
      await h.pump(tester, cameraSlot: true);
      await tester.tap(find.byKey(const ValueKey('camera')));
      await tester.longPress(find.byKey(const ValueKey('camera')));
      expect(h.cameraTaps, 1);
      expect(h.cameraLongPresses, 1);
      expect(find.bySemanticsLabel('Camera'), findsOneWidget);
      expect(h.signals.last.shouldPause, isFalse);
      handle.dispose();
    });

    testWidgets(r'placement: $IOS only at 3 columns, never in other albums', (
      tester,
    ) async {
      final h = PickerHarness();
      h.library.addAlbum(
        const LibraryAlbumId('camera'),
        kind: LibraryAlbumKind.camera,
        title: 'Camera',
        assets: [FakeMediaLibrary.assetAt(0).id],
      );
      await h.pump(tester, policy: LibraryGridPolicy.$IOS, cameraSlot: true);
      expect(find.byKey(const ValueKey('camera')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mpx-album-switcher')));
      await PickerHarness.settle(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-album-camera')));
      await PickerHarness.settle(tester);
      expect(find.byKey(const ValueKey('camera')), findsNothing);
    });
  });

  group('album switcher', () {
    for (final policy in [LibraryGridPolicy.$Android, LibraryGridPolicy.$IOS]) {
      testWidgets(
        'lists albums with counts and rebinds the grid '
        '(${identical(policy, LibraryGridPolicy.$IOS) ? 'iOS' : 'Android'})',
        (tester) async {
          final h = PickerHarness();
          h.library.addAlbum(
            const LibraryAlbumId('camera'),
            kind: LibraryAlbumKind.camera,
            title: '',
            assets: [
              FakeMediaLibrary.assetAt(5).id,
              FakeMediaLibrary.assetAt(6).id,
            ],
          );
          await h.pump(tester, policy: policy);
          expect(find.text('All media'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('mpx-album-switcher')));
          await PickerHarness.settle(tester);
          expect(find.text('30'), findsOneWidget);
          expect(find.text('2'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('mpx-album-camera')));
          await PickerHarness.settle(tester);
          expect(find.text('Camera'), findsWidgets);
          expect(cell(5), findsOneWidget);
          expect(cell(0), findsNothing);
        },
      );
    }

    testWidgets('each row shows its cover: the newest item of the album, '
        'its thumbnail told to the cache so the library key resolves', (
      tester,
    ) async {
      final h = PickerHarness();
      final newest = FakeMediaLibrary.assetAt(5);
      h.library.addAlbum(
        const LibraryAlbumId('camera'),
        kind: LibraryAlbumKind.camera,
        title: '',
        assets: [newest.id, FakeMediaLibrary.assetAt(6).id],
      );
      await h.pump(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-album-switcher')));
      await PickerHarness.settle(tester);

      // Android rows: a 40 px cover at a device pixel ratio of 1.
      final key = LibraryKeys.thumbnailKeyOf(newest, 40);
      final row = find.byKey(const ValueKey('mpx-album-camera'));
      final cover = find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (widget) => widget is ContentView && widget.content == key,
        ),
      );
      expect(cover, findsOneWidget);
      expect(h.producer.known.map((d) => d.key), contains(key));
      expect(h.producer.attempts.map((a) => a.request.key), contains(key));
    });

    testWidgets('an album that starts at the end opens scrolled to it', (
      tester,
    ) async {
      final h = PickerHarness(assets: 200);
      h.library.addAlbum(
        const LibraryAlbumId('old-first'),
        kind: LibraryAlbumKind.user,
        title: 'Trip',
        startsAtEnd: true,
        assets: [for (var i = 0; i < 200; i++) FakeMediaLibrary.assetAt(i).id],
      );
      await h.pump(tester, policy: LibraryGridPolicy.$IOS);
      await tester.tap(find.byKey(const ValueKey('mpx-album-switcher')));
      await PickerHarness.settle(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-album-old-first')));
      await PickerHarness.settle(tester);
      expect(cell(199), findsOneWidget);
      expect(cell(0), findsNothing);
    });
  });

  testWidgets('resuming reads the albums again', (tester) async {
    final h = PickerHarness();
    await h.pump(tester);
    h.library.addAlbum(
      const LibraryAlbumId('new'),
      kind: LibraryAlbumKind.user,
      title: 'New album',
      assets: [FakeMediaLibrary.assetAt(1).id],
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await PickerHarness.settle(tester);
    await tester.tap(find.byKey(const ValueKey('mpx-album-switcher')));
    await PickerHarness.settle(tester);
    expect(find.text('New album'), findsOneWidget);
  });

  testWidgets('a resume with nothing changed keeps the grid as it is', (
    tester,
  ) async {
    final h = PickerHarness();
    await h.pump(tester);
    final grid = tester.state<LibraryGridState>(find.byType(LibraryGrid));
    final pages = grid.pages;
    expect(cell(0), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
      expect(cell(0), findsOneWidget);
    }
    expect(grid.pages, same(pages));
  });

  group('library changes', () {
    testWidgets('a selected item deleted from the device leaves the '
        'selection, and the rest renumber', (tester) async {
      final h = PickerHarness();
      await h.pump(tester);
      for (final i in [0, 1, 2]) {
        h.selection.toggle(key(i));
      }
      h.library.remove({FakeMediaLibrary.assetAt(1).id});
      await PickerHarness.settle(tester);
      expect(h.selection.keys, [key(0), key(2)]);
      expect(h.selection.orderOf(key(2)), 2);
    });

    testWidgets('a host that takes the removals itself is told them', (
      tester,
    ) async {
      final h = PickerHarness();
      final told = <List<MediaKey>>[];
      await h.pump(tester, onRemoved: told.add);
      h.selection
        ..toggle(key(0))
        ..toggle(key(1));
      h.library.remove({FakeMediaLibrary.assetAt(0).id});
      await PickerHarness.settle(tester);
      expect(told, [
        [key(0)],
      ]);
      expect(h.selection.keys, [key(0), key(1)], reason: 'the host decides');
    });

    testWidgets('an album whose cover went shows its next item and count', (
      tester,
    ) async {
      final h = PickerHarness();
      final first = FakeMediaLibrary.assetAt(5);
      final next = FakeMediaLibrary.assetAt(6);
      h.library.addAlbum(
        const LibraryAlbumId('camera'),
        kind: LibraryAlbumKind.camera,
        title: '',
        assets: [first.id, next.id],
      );
      await h.pump(tester);
      h.library.remove({first.id});
      await PickerHarness.settle(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-album-switcher')));
      await PickerHarness.settle(tester);
      final row = find.byKey(const ValueKey('mpx-album-camera'));
      final covers = tester
          .widgetList<ContentView>(
            find.descendant(of: row, matching: find.byType(ContentView)),
          )
          .map((v) => v.content);
      expect(covers, [LibraryKeys.thumbnailKeyOf(next, 40)]);
      expect(
        find.descendant(of: row, matching: find.text('1')),
        findsOneWidget,
      );
    });
  });

  group('album switcher arrow', () {
    testWidgets(r'$Android: a filled triangle in a 24 box right after the '
        'title', (tester) async {
      final h = PickerHarness();
      await h.pump(tester);
      final switcher = find.byKey(const ValueKey('mpx-album-switcher'));
      final arrow = find.byKey(const ValueKey('mpx-album-arrow'));
      final title = find.descendant(of: switcher, matching: find.byType(Text));
      expect(tester.getSize(arrow), const Size.square(24));
      expect(tester.getTopLeft(arrow).dx, tester.getTopRight(title).dx);
      expect(
        tester.getCenter(arrow).dy,
        closeTo(tester.getCenter(title).dy, 1),
      );
      expectThemedText(tester);
    });

    testWidgets(r'$IOS: a chevron 5 after the title, at 40% of its colour', (
      tester,
    ) async {
      final h = PickerHarness();
      await h.pump(tester, policy: LibraryGridPolicy.$IOS);
      final switcher = find.byKey(const ValueKey('mpx-album-switcher'));
      final arrow = find.byKey(const ValueKey('mpx-album-arrow'));
      final title = find.descendant(of: switcher, matching: find.byType(Text));
      expect(tester.getTopLeft(arrow).dx - tester.getTopRight(title).dx, 5);
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: arrow, matching: find.byType(Opacity)).first,
      );
      expect(opacity.opacity, 0.4);
    });
  });
}
