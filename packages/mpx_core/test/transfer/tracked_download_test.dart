import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _key = MediaKey.remote('clip-1');
const _spec = AssetSpec(pixelWidth: 64, pixelHeight: 64);
const _large = AssetSpec(pixelWidth: 128, pixelHeight: 128);
const _profile = AssetProfile();
const _item = MediaDescriptor(
  key: _key,
  kind: MediaKind.still,
  byteSize: 400,
  thumbnail: MediaThumbnailRef('thumb-1'),
);
final _bytes = FetchedContent.bytes(Uint8List.fromList(const [1, 2, 3]));

/// A scope over a pipeline of fakes, with tracked transfers unless [tracked]
/// is off. The content is missing from every cache until a test says it is
/// local.
final class _Harness {
  _Harness({bool tracked = true})
    : transfers = FakeTrackedTransfers(),
      fetcher = FakeFetcher() {
    pipeline = AssetPipeline(
      fetcher: fetcher,
      decoders: DecoderRegistry()..register(MediaKind.still, FakeDecoder()),
    )..know(_item);
    fetcher
      ..serve(_key, _bytes)
      ..serveThumbnail(_item.thumbnail!, _bytes)
      ..missing.add(_key);
    scope = AssetCacheScope(
      producer: pipeline,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
      tracked: tracked ? transfers : null,
    );
  }

  final FakeTrackedTransfers transfers;
  final FakeFetcher fetcher;
  late final AssetPipeline pipeline;
  late final AssetCacheScope scope;

  AssetBinding attach({bool control = true, AssetSpec spec = _spec}) =>
      scope.attach(_key, spec, _profile, tracksTransfer: control);

  List<FakeFetch> get contentFetches =>
      fetcher.fetchesOf(_key, FetchPart.content);

  // The job brought the content into the cache.
  void landed() {
    fetcher.missing.remove(_key);
    transfers.drive(_key, AssetTransfer.none);
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void dispose() {
    scope.dispose();
    pipeline.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Harness harness;

  setUp(() {
    harness = _Harness();
    addTearDown(harness.dispose);
  });

  group(
    'a binding with a status control in a scope with tracked transfers',
    () {
      test('downloads through the seam, as an auto download, and fetches only '
          'the stand-ins itself', () async {
        final binding = harness.attach();
        await harness.settle();

        expect(harness.transfers.downloads, [
          (key: _key, origin: TransferOrigin.auto),
        ]);
        expect(harness.contentFetches, isEmpty);
        expect(binding.transfer, const AssetTransfer.waiting(400));
        expect(binding.readiness.stage, AssetStage.placeholder);
      });

      test('shows the receiving value of the job, then the picture the job '
          'brought', () async {
        final binding = harness.attach();
        await harness.settle();
        var heard = 0;
        binding.addListener(() => heard++);

        harness.transfers.drive(_key, const AssetTransfer.receiving(100, 400));
        expect(binding.transfer, const AssetTransfer.receiving(100, 400));
        expect(heard, greaterThan(0));

        harness.landed();
        await harness.settle();

        expect(binding.transfer, AssetTransfer.none);
        expect(binding.readiness.stage, AssetStage.full);
        expect(harness.transfers.downloads, hasLength(1));
      });

      test('cancel reaches cancel(key) and is remembered; download asks the '
          'job again as the user', () async {
        final binding = harness.attach();
        await harness.settle();
        harness.transfers.drive(_key, const AssetTransfer.receiving(100, 400));

        binding.cancelDownload();

        expect(harness.transfers.cancels, [_key]);
        expect(binding.transfer, const AssetTransfer.awaitingUser(400, 100));

        // Scrolled away and back: the cancel holds, nothing is asked.
        binding.detach();
        final again = harness.attach();
        await harness.settle();
        expect(harness.transfers.downloads, hasLength(1));

        again.download();

        expect(harness.transfers.downloads.last, (
          key: _key,
          origin: TransferOrigin.user,
        ));
        expect(again.transfer, const AssetTransfer.waiting(400));
      });

      test('cancel with nothing under way forwards nothing', () async {
        final binding = harness.attach();
        await harness.settle();
        harness.transfers.drive(_key, const AssetTransfer.awaitingUser(400));

        binding.cancelDownload();

        expect(harness.transfers.cancels, isEmpty);
      });

      test('a user download first is the user\'s job', () async {
        final binding = harness.attach();
        await harness.settle();
        harness.transfers.drive(_key, const AssetTransfer.awaitingUser(400));

        binding.download();

        expect(harness.transfers.downloads.last.origin, TransferOrigin.user);
      });

      test('two bindings of one key, one spec or two, see one value and make '
          'one download call', () async {
        final first = harness.attach();
        final second = harness.attach();
        final larger = harness.attach(spec: _large);
        await harness.settle();

        harness.transfers.drive(_key, const AssetTransfer.receiving(200, 400));

        expect(harness.transfers.downloads, hasLength(1));
        for (final binding in [first, second, larger]) {
          expect(binding.transfer, const AssetTransfer.receiving(200, 400));
        }
      });

      test('a failed job is asked again on the next attach', () async {
        final binding = harness.attach();
        await harness.settle();
        harness.transfers.drive(
          _key,
          const AssetTransfer.failed(AssetFailureKind.transient, 10, 400),
        );
        expect(
          binding.transfer,
          const AssetTransfer.failed(AssetFailureKind.transient, 10, 400),
        );

        binding.detach();
        harness.attach();
        await harness.settle();

        expect(harness.transfers.downloads, hasLength(2));
      });

      test(
        'stops watching when the last binding with a control leaves',
        () async {
          final binding = harness.attach();
          await harness.settle();
          expect(harness.transfers.isWatched(_key), isTrue);

          binding.detach();

          expect(harness.transfers.isWatched(_key), isFalse);
        },
      );

      test('an upload whose source is the content shows sending and sent over '
          'the local picture, and its cancel goes to the job', () async {
        harness.fetcher.missing.remove(_key);
        final binding = harness.attach();
        await harness.settle();
        expect(binding.readiness.stage, AssetStage.full);
        expect(harness.transfers.downloads, isEmpty);

        harness.transfers.drive(_key, const AssetTransfer.sending(10, 30));
        expect(binding.transfer, const AssetTransfer.sending(10, 30));

        binding.cancelDownload();
        expect(harness.transfers.cancels, [_key]);

        harness.transfers.drive(_key, AssetTransfer.sent);
        expect(binding.transfer, AssetTransfer.sent);

        harness.transfers.drive(_key, AssetTransfer.none);
        expect(binding.transfer, AssetTransfer.none);
        expect(binding.readiness.stage, AssetStage.full);
      });
    },
  );

  group('the seam stays out of', () {
    test('a binding without a status control: thumbnails and content are the '
        'scope\'s own fetches', () async {
      final binding = harness.attach(control: false);
      await harness.settle();

      expect(harness.transfers.downloads, isEmpty);
      expect(harness.transfers.isWatched(_key), isFalse);
      expect(harness.contentFetches, hasLength(1));
      expect(binding.readiness.stage, AssetStage.full);
    });

    test(
      'a scope without tracked transfers: the download is untracked',
      () async {
        final plain = _Harness(tracked: false);
        addTearDown(plain.dispose);

        final binding = plain.attach();
        await plain.settle();

        expect(plain.transfers.downloads, isEmpty);
        expect(plain.contentFetches, hasLength(1));
        expect(binding.readiness.stage, AssetStage.full);
      },
    );
  });

  group('diagnostics', () {
    test('a tracked download, its mapping and a forwarded cancel', () async {
      final diagnostics = RecordingDiagnostics.install();
      final binding = harness.attach();
      await harness.settle();
      harness.transfers.drive(_key, const AssetTransfer.receiving(100, 400));
      binding
        ..cancelDownload()
        ..download();

      expect(diagnostics.whereCategory('binding'), [
        isMpxEvent(
          level: MpxEventLevel.debug,
          op: BindingOp.trackedDownload,
          mediaKey: _key,
          fields: {'origin': 'auto'},
        ),
        isMpxEvent(
          level: MpxEventLevel.trace,
          op: BindingOp.mapped,
          mediaKey: _key,
          fields: {'transfer': 'waiting'},
        ),
        isMpxEvent(op: BindingOp.mapped, fields: {'transfer': 'receiving'}),
        isMpxEvent(
          level: MpxEventLevel.info,
          op: BindingOp.cancelForwarded,
          mediaKey: _key,
          fields: {'direction': 'download'},
        ),
        isMpxEvent(op: BindingOp.mapped, fields: {'transfer': 'awaitingUser'}),
        isMpxEvent(op: BindingOp.trackedDownload, fields: {'origin': 'user'}),
        isMpxEvent(op: BindingOp.mapped, fields: {'transfer': 'waiting'}),
      ]);
      expect(diagnostics.errors, isEmpty);
    });

    test('an upload cancel is forwarded as an upload', () async {
      final diagnostics = RecordingDiagnostics.install();
      harness.fetcher.missing.remove(_key);
      final binding = harness.attach();
      await harness.settle();
      harness.transfers.drive(_key, const AssetTransfer.sending(1, 3));

      binding.cancelDownload();

      expect(
        diagnostics.whereOp(BindingOp.cancelForwarded).single,
        isMpxEvent(fields: {'direction': 'upload'}),
      );
    });

    test('an untracked download says so, in both kinds of scope', () async {
      final diagnostics = RecordingDiagnostics.install();
      harness.attach(control: false);
      await harness.settle();
      final plain = _Harness(tracked: false);
      addTearDown(plain.dispose);
      plain.attach();
      await plain.settle();

      expect(diagnostics.whereOp(BindingOp.untracked), [
        isMpxEvent(level: MpxEventLevel.debug, mediaKey: _key, fields: isEmpty),
        isMpxEvent(level: MpxEventLevel.debug, mediaKey: _key, fields: isEmpty),
      ]);
      expect(diagnostics.whereOp(BindingOp.trackedDownload), isEmpty);
    });
  });

  group('AssetView', () {
    const preset = AssetPreset(
      size: Size(100, 100),
      spec: _spec,
      profile: _profile,
    );

    Widget host(MediaStatusMode status) => MaterialApp(
      home: AssetCacheProvider(
        scope: harness.scope,
        child: Center(
          child: AssetView(content: _key, preset: preset, status: status),
        ),
      ),
    );

    testWidgets('with the full control downloads through the seam and shows '
        'the job\'s bytes; its cancel reaches the job', (tester) async {
      await tester.pumpWidget(host(const MediaStatusMode.control()));
      await tester.pump();

      expect(harness.transfers.downloads.single.origin, TransferOrigin.auto);
      harness.transfers.drive(_key, const AssetTransfer.receiving(100, 400));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.bySemanticsLabel('Cancel download'));
      expect(harness.transfers.cancels, [_key]);
    });

    testWidgets('with a bare arc stays the scope\'s own fetch', (tester) async {
      await tester.pumpWidget(host(const MediaStatusMode.arc(20)));
      await tester.pump();

      expect(harness.transfers.downloads, isEmpty);
      expect(harness.contentFetches, hasLength(1));
    });

    testWidgets('a status that gains the control attaches again as tracked', (
      tester,
    ) async {
      await tester.pumpWidget(host(MediaStatusMode.none));
      await tester.pump();
      expect(harness.transfers.isWatched(_key), isFalse);

      await tester.pumpWidget(host(MediaStatusMode.compact));
      await tester.pump();

      expect(harness.transfers.isWatched(_key), isTrue);
    });
  });
}
