import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _received = 1258291;
const _total = 4718592;

void main() {
  group('MediaSizeFormat', () {
    test(r'$IOS writes one unit: 1.2 / 4.5 MB', () {
      expect(MediaSizeFormat.$IOS.progress(_received, _total), '1.2 / 4.5 MB');
    });

    test(r'$Android writes each unit', () {
      expect(
        MediaSizeFormat.$Android.progress(_received, _total),
        '1.2 MB / 4.5 MB',
      );
      expect(
        MediaSizeFormat.$Android.progress(300 * 1024, _total),
        '300.0 KB / 4.5 MB',
      );
    });

    test(r'$Desktop writes tenths of a megabyte', () {
      expect(
        MediaSizeFormat.$Desktop.progress(100 * 1024, 300 * 1024),
        '0.1 / 0.3 MB',
      );
    });

    test('sizes round to tenths and pick their unit', () {
      const format = MediaSizeFormat.$Android;
      expect(format.size(830), '830 B');
      expect(format.size(12800), '12.5 KB');
      expect(format.size(_total), '4.5 MB');
      expect(format.size(1288490189), '1.2 GB');
      expect(format.size(1101005), '1.1 MB');
    });

    test('the narrow form is a floored percent', () {
      expect(MediaSizeFormat.$Android.percent(_received, _total), '26%');
      expect(MediaSizeFormat.$Android.percent(10, 0), '0%');
      expect(MediaSizeFormat.$Android.narrowBelow, 120);
      expect(MediaSizeFormat.$Desktop.narrowBelow, 0);
    });

    test('durations are m:ss and h:mm:ss', () {
      expect(MediaSizeFormat.duration(const Duration(seconds: 13)), '0:13');
      expect(MediaSizeFormat.duration(const Duration(seconds: 75)), '1:15');
      expect(
        MediaSizeFormat.duration(const Duration(hours: 1, seconds: 5)),
        '1:00:05',
      );
      expect(MediaSizeFormat.duration(const Duration(seconds: -2)), '0:00');
    });
  });

  group('MediaBadge rows', () {
    const style = MediaBadgeStyle.$IOS;
    const strings = MediaBadgeStrings();

    List<String> rows({
      Duration? duration,
      bool gif = false,
      AssetTransfer transfer = AssetTransfer.none,
      double width = 300,
    }) => MediaBadge.rowsOf(
      style: style,
      strings: strings,
      duration: duration,
      gif: gif,
      transfer: transfer,
      width: width,
    );

    test('a duration alone', () {
      expect(rows(duration: const Duration(seconds: 13)), ['0:13']);
    });

    test('GIF for an animated image with no duration', () {
      expect(rows(gif: true), ['GIF']);
    });

    test('two rows while receiving: time over size', () {
      expect(
        rows(
          duration: const Duration(seconds: 13),
          transfer: const AssetTransfer.receiving(_received, _total),
        ),
        ['0:13', '1.2 / 4.5 MB'],
      );
    });

    test('the total while it waits for the user or failed', () {
      expect(rows(transfer: const AssetTransfer.awaitingUser(_total)), [
        '4.5 MB',
      ]);
      expect(
        rows(
          transfer: const AssetTransfer.failed(
            AssetFailureKind.transient,
            10,
            _total,
          ),
        ),
        ['4.5 MB'],
      );
    });

    test('a percent when narrow', () {
      expect(
        rows(
          transfer: const AssetTransfer.receiving(_received, _total),
          width: 80,
        ),
        ['26%'],
      );
    });

    test('a download that stopped short shows the bytes it left', () {
      expect(
        rows(transfer: const AssetTransfer.awaitingUser(_total, _received)),
        ['1.2 / 4.5 MB'],
      );
    });

    test('nothing for cached content without a duration', () {
      expect(rows(), isEmpty);
    });

    test('a host string replaces the label', () {
      expect(
        MediaBadge.rowsOf(
          style: style,
          strings: const MediaBadgeStrings(gif: 'Gif', megabytes: 'Mo'),
          gif: true,
          transfer: const AssetTransfer.awaitingUser(_total),
        ),
        ['Gif', '4.5 Mo'],
      );
    });
  });

  group('MediaBadge widget', () {
    late FakeAssetProducer producer;
    late ManualPlaybackTickSource ticks;
    late AssetCacheScope scope;
    const key = MediaKey.remote('clip');

    setUp(() {
      producer = FakeAssetProducer();
      ticks = ManualPlaybackTickSource();
      scope = AssetCacheScope(
        producer: producer,
        clock: PlaybackClock(ticks: ticks),
      );
      addTearDown(scope.dispose);
    });

    Widget host(Widget child) => MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: Align(alignment: Alignment.topLeft, child: child),
    );

    testWidgets('reads the binding: descriptor, transfer, then nothing', (
      tester,
    ) async {
      final binding = scope.attach(
        key,
        const AssetSpec(pixelWidth: 8, pixelHeight: 8),
        const AssetProfile(),
      );
      addTearDown(binding.detach);
      await tester.pumpWidget(host(MediaBadge.binding(binding)));
      expect(find.byType(Text), findsNothing);

      producer.last
        ..describe(
          const MediaDescriptor(
            key: key,
            kind: MediaKind.video,
            duration: Duration(seconds: 13),
            byteSize: _total,
          ),
        )
        ..transfer(_received, null);
      await tester.pump();

      expect(find.text('0:13'), findsOneWidget);
      expect(find.text('1.2 / 4.5 MB'), findsOneWidget);
    });

    // What the first row says per kind of content: a video its duration, a
    // GIF (an animated image or a silent loop coded as video) "GIF" and
    // never a duration, anything else nothing.
    for (final (name, descriptor, label) in [
      (
        'a video: its duration',
        const MediaDescriptor(
          key: key,
          kind: MediaKind.video,
          animated: true,
          duration: Duration(seconds: 13),
        ),
        '0:13',
      ),
      (
        'a silent loop coded as video: GIF',
        const MediaDescriptor(
          key: key,
          kind: MediaKind.video,
          animated: true,
          silentLoop: true,
          duration: Duration(seconds: 13),
        ),
        'GIF',
      ),
      (
        'an animated image with a duration: GIF',
        const MediaDescriptor(
          key: key,
          kind: MediaKind.animatedImage,
          animated: true,
          duration: Duration(seconds: 3),
        ),
        'GIF',
      ),
      (
        'a vector animation with a duration: nothing',
        const MediaDescriptor(
          key: key,
          kind: MediaKind.vectorAnimation,
          animated: true,
          duration: Duration(seconds: 3),
        ),
        null,
      ),
    ]) {
      testWidgets('labels by kind, $name', (tester) async {
        final binding = scope.attach(
          key,
          const AssetSpec(pixelWidth: 8, pixelHeight: 8),
          const AssetProfile(),
        );
        addTearDown(binding.detach);
        producer.last.describe(descriptor);
        await tester.pumpWidget(host(MediaBadge.binding(binding)));

        final texts = [
          for (final text in tester.widgetList<Text>(find.byType(Text)))
            text.data,
        ];
        expect(texts, [?label]);
      });
    }

    testWidgets('counts down while the clip plays', (tester) async {
      final binding = scope.attach(
        key,
        const AssetSpec(pixelWidth: 8, pixelHeight: 8),
        const AssetProfile(animate: true, loop: true),
      );
      addTearDown(binding.detach);
      producer.last
        ..describe(
          const MediaDescriptor(
            key: key,
            kind: MediaKind.video,
            duration: Duration(seconds: 13),
          ),
        )
        ..advance(
          AssetStage.full,
          frames: List.filled(13, const Duration(seconds: 1)),
        );
      await tester.pumpWidget(host(MediaBadge.binding(binding)));
      expect(find.text('0:13'), findsOneWidget);

      for (var i = 1; i <= 6; i++) {
        ticks.tick(Duration(milliseconds: 500 * i));
        binding.advancePlayback();
      }
      await tester.pump();

      expect(find.text('0:10'), findsOneWidget);
    });

    testWidgets('counts down while another surface of the entry plays the '
        'clip (a view that only shows the controls)', (tester) async {
      const spec = AssetSpec(pixelWidth: 8, pixelHeight: 8);
      final playing = scope.attach(
        key,
        spec,
        const AssetProfile(animate: true, loop: true),
      );
      addTearDown(playing.detach);
      producer.last
        ..describe(
          const MediaDescriptor(
            key: key,
            kind: MediaKind.video,
            duration: Duration(seconds: 13),
          ),
        )
        ..advance(
          AssetStage.full,
          frames: List.filled(13, const Duration(seconds: 1)),
        );
      final controls = scope.attach(key, spec, const AssetProfile());
      addTearDown(controls.detach);
      await tester.pumpWidget(host(MediaBadge.binding(controls)));
      expect(find.text('0:13'), findsOneWidget);

      for (var i = 1; i <= 6; i++) {
        ticks.tick(Duration(milliseconds: 500 * i));
        playing.advancePlayback();
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(find.text('0:10'), findsOneWidget);
    });

    testWidgets('a held or paused clip keeps the time left at its position, '
        'not the whole length', (tester) async {
      final binding = scope.attach(
        key,
        const AssetSpec(pixelWidth: 8, pixelHeight: 8),
        const AssetProfile(animate: true, loop: true),
      );
      addTearDown(binding.detach);
      producer.last
        ..describe(
          const MediaDescriptor(
            key: key,
            kind: MediaKind.video,
            duration: Duration(seconds: 13),
          ),
        )
        ..advance(
          AssetStage.full,
          frames: List.filled(13, const Duration(seconds: 1)),
        );
      await tester.pumpWidget(host(MediaBadge.binding(binding)));
      for (var i = 1; i <= 6; i++) {
        ticks.tick(Duration(milliseconds: 500 * i));
        binding.advancePlayback();
      }
      await tester.pump();
      expect(find.text('0:10'), findsOneWidget);

      final hold = scope.holdPlayback(
        key,
        const AssetSpec(pixelWidth: 8, pixelHeight: 8),
      );
      await tester.pump();
      expect(binding.isPlaying, isFalse);
      expect(find.text('0:10'), findsOneWidget);

      hold.release();
      binding.visible = false;
      await tester.pump();
      expect(find.text('0:10'), findsOneWidget);
    });

    testWidgets('a host style from its theme changes colours and text only', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: MediaLoadingStyleScope(
            style: (platform) => platform.copyWith(
              badge: platform.badge.copyWith(
                background: Colors.teal,
                textStyle: platform.badge.textStyle.copyWith(
                  color: Colors.amber,
                ),
              ),
            ),
            child: const Align(
              alignment: Alignment.topLeft,
              child: MediaBadge(gif: true),
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('GIF'));
      expect(text.style!.color, Colors.amber);
      expect(text.style!.fontSize, 12);
      final box = tester.widget<DecoratedBox>(find.byType(DecoratedBox));
      expect((box.decoration as BoxDecoration).color, Colors.teal);
      expect(
        (box.decoration as BoxDecoration).borderRadius,
        BorderRadius.circular(8),
      );
    });
  });

  test('pins each platform style', () {
    expect(MediaBadgeStyle.$Android.offset, const Offset(4, 4));
    expect(MediaBadgeStyle.$Android.background, const Color(0x66000000));
    expect(MediaBadgeStyle.$Android.textStyle.fontSize, 12);
    expect(MediaBadgeStyle.$IOS.offset, const Offset(6, 6));
    expect(MediaBadgeStyle.$IOS.radius, 9);
    expect(MediaBadgeStyle.$IOS.textStyle.fontSize, 11);
    expect(MediaBadgeStyle.$IOS.fade, const Duration(milliseconds: 200));
    expect(MediaBadgeStyle.$Desktop.background, const Color(0x54000000));
    expect(MediaBadgeStyle.$Desktop.textStyle.fontSize, 13);
    expect(MediaLoadingStyle.$IOS.badge, MediaBadgeStyle.$IOS);
  });
}
