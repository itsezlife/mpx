/// The transfers demo over the engine's fakes: a pick goes out as a publish
/// job and shows with its item's cell, the lists follow the engine, a
/// cell's long press opens its logs, the debug panel's actions each leave
/// their event, and the quit confirmation follows `systemActive`.
///
/// **Seams:** [TransfersDemo] and [TransfersRoot] over a real `Transfers`
/// (`UploadsHarness`) with [FakeUploadTransport]s, a [FakePublisher] and a
/// [FakeTransferEnvelope]; the server's own calls answered by a mock client;
/// events through [RecordingDiagnostics] and the log journal.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_example/journal/data/diagnostics_journal.dart';
import 'package:mpx_example/journal/model/journal_view.dart';
import 'package:mpx_example/journal/view/journal_page.dart';
import 'package:mpx_example/transfers/dev_server.dart';
import 'package:mpx_example/transfers/network_cut.dart';
import 'package:mpx_example/transfers/transfer_settings.dart';
import 'package:mpx_example/transfers/transfers_demo.dart';
import 'package:mpx_example/transfers/transfers_page.dart';
import 'package:mpx_example/transfers/transfers_root.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

const String _path = '/picked/holiday-video.mp4';

const DemoPick _pick = DemoPick(
  path: _path,
  size: 300 * 1024,
  mimeType: 'video/mp4',
  name: 'holiday-video.mp4',
);

final class _Rig {
  _Rig._(this.harness, this.root, this.publisher, this.transports);

  final UploadsHarness harness;
  final TransfersRoot root;
  final FakePublisher publisher;
  final Map<String, FakeUploadTransport> transports;
  final DiagnosticsJournal journal = DiagnosticsJournal.memory();
  late final AssetCacheScope scope = AssetCacheScope(
    clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
    tracked: root.transfers.tracked,
  );
  int kills = 0;
  late final TransfersDemo demo = TransfersDemo(
    root: root,
    keepLocal: (_, _) async {},
    know: (_) {},
    kill: () => kills++,
  );

  Transfers get transfers => root.transfers;

  /// [sourceCopies] makes the engine read picked files as the page holds
  /// them, as on the web.
  static Future<_Rig> open({
    bool holdParts = false,
    UploadSourceCopies? sourceCopies,
  }) async {
    final files = FakeUploadSourceFiles()..put(_path, size: _pick.size);
    final transports = {
      for (final transport in DemoTransport.values)
        transport.id: FakeUploadTransport(
          id: transport.id,
          holdParts: holdParts,
        ),
    };
    final settings = TransferSettings.memory(
      server: Uri.parse('http://server.test:8090'),
    );
    final harness = await UploadsHarness.open(
      lifecycle: ManualPlaybackLifecycleSource(
        initial: AppLifecycleState.resumed,
      ),
      transports: transports.values.toList(),
      files: files,
      envelope: FakeTransferEnvelope(),
      envelopeConfig: TransfersRoot.envelopeConfig(settings),
      sourceCopies: sourceCopies,
    );
    final publisher = FakePublisher(hold: true);
    harness.transfers.registerPublisher(DevServerPublisher.id, publisher);
    final network = ValueNotifier(NetworkClass.unmetered);
    final root = TransfersRoot(
      transfers: harness.transfers,
      server: DevServer(
        settings.server,
        client: MockClient(
          (request) async => request.url.path == '/files'
              ? http.Response(
                  jsonEncode([
                    {'id': 'f1.mp4', 'size': 2048, 'contentType': 'video/mp4'},
                  ]),
                  200,
                )
              : http.Response('', 404),
        ),
      ),
      settings: settings,
      cut: NetworkCut(),
      network: network,
    );
    return _Rig._(harness, root, publisher, transports);
  }

  Widget app() => MaterialApp(
    home: AssetCacheProvider(
      scope: scope,
      child: TransfersPage(
        demo: demo,
        journal: journal,
        pick: () async => const [_pick],
      ),
    ),
  );

  // Unmounts the page and closes what holds timers, inside the test body.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    demo.dispose();
    root.dispose();
    scope.dispose();
    await transfers.dispose();
    journal.dispose();
    await tester.pump(const Duration(seconds: 2));
  }
}

Future<void> _tall(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(1000, 5000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

// Pumps until [done] holds, a frame of 50 ms at a time.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue, reason: 'did not happen in 5 s');
}

// Turns preparation off (the fakes prepare nothing) and sends the pick.
Future<void> _send(WidgetTester tester) async {
  await tester.tap(find.text('Prepare before upload'));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('transfers.send')));
  await tester.pump();
}

void main() {
  testWidgets('a pick goes out as a publish job through the chosen protocol, '
      'its item cell and the transfer job listed, and completes when the '
      'publisher answers', (tester) async {
    await _tall(tester);
    final recorder = RecordingDiagnostics.install();
    final rig = await _Rig.open();
    await tester.pumpWidget(rig.app());
    await tester.tap(find.text('Multipart'));
    await tester.pump();

    await _send(tester);
    await _until(tester, () => rig.publisher.calls.isNotEmpty);

    final job = (await rig.transfers.watchJobs().first).single;
    expect(job.tag, startsWith('demo:'));
    expect(rig.transports['multipart']!.opens, hasLength(1));
    expect(rig.transports['tus']!.opens, isEmpty);
    final item = job.items.single;
    expect(find.byKey(ValueKey('transfers.item.${item.itemId}')), findsOne);
    expect(find.byType(TransferCell), findsNWidgets(2)); // the item, a file
    expect(find.byIcon(Icons.upload_outlined), findsWidgets);

    rig.publisher.answer(
      PublishOutcome.published(
        serverKeys: {item.itemId: DevServer.keyOf('f9.mp4')},
      ),
    );
    await _until(
      tester,
      () => find.textContaining('\ncompleted').evaluate().isNotEmpty,
    );

    expect(
      recorder.whereOp(PublishOp.jobCreated).single,
      isMpxEvent(tag: job.tag, fields: containsPair('items', 1)),
    );
    expect(recorder.errors, isEmpty);
    // No user content: no path or file name in any event.
    for (final event in recorder.events) {
      expect('${event.fields}', isNot(contains('holiday')));
    }
    await rig.close(tester);
  });

  testWidgets('a file the page holds (the web) goes out as picked, read '
      'from the page and copied, though preparation was asked for', (
    tester,
  ) async {
    final recorder = RecordingDiagnostics.install();
    final copies = FakeUploadSourceCopies();
    final rig = await _Rig.open(sourceCopies: copies);
    final bytes = Uint8List.fromList(List.generate(12, (i) => i));

    final job = await rig.demo.send([
      DemoPick(
        path: 'picked.jpg',
        size: bytes.length,
        mimeType: 'image/jpeg',
        name: 'picked.jpg',
        pageSource: SourceBytes.memory(bytes),
      ),
    ], prepare: true);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(job.snapshot.items.single.state, isA<PublishItemState$Uploaded>());
    expect(rig.transports[rig.root.settings.transport.id]!.opens, hasLength(1));
    // Copied at the start, deleted once the upload completed.
    expect(copies.deleted, hasLength(1));
    expect(
      recorder.events
          .where((event) => event.op.name == 'sourceCopied')
          .single
          .fields['bytes'],
      12,
    );
    expect(recorder.errors, isEmpty);
    await rig.close(tester);
  });

  testWidgets('every event of the demo lands in the log journal, and a '
      'cell\'s long press opens the logs of its item', (tester) async {
    await _tall(tester);
    RecordingDiagnostics.install(); // restores the policy after
    final rig = await _Rig.open(holdParts: true);
    MpxDiagnostics.current = rig.journal.mpxDiagnostics;
    await tester.pumpWidget(rig.app());

    await _send(tester);
    await _until(tester, () => rig.transports['tus']!.held.isNotEmpty);
    final item = (await rig.transfers.watchJobs().first).single.items.single;

    expect(
      rig.journal.records.map((record) => record.category).toSet(),
      containsAll(<String>['publish', 'scheduler', 'envelope']),
    );
    expect(
      rig.journal.records.where(
        (record) => record.ids['itemId'] == item.itemId,
      ),
      isNotEmpty,
    );

    await tester.longPress(
      find.byKey(ValueKey('transfers.item.${item.itemId}')),
    );
    await tester.pumpAndSettle();

    final page = tester.widget<JournalPage>(find.byType(JournalPage));
    expect(page.filter!.ids, {JournalIdKind.itemId: item.itemId});
    await rig.close(tester);
  });

  testWidgets('the debug panel shows the snapshot and its actions each '
      'leave their event: network cut, system interruption, kill in 3 s', (
    tester,
  ) async {
    await _tall(tester);
    final recorder = RecordingDiagnostics.install();
    final rig = await _Rig.open(holdParts: true);
    await tester.pumpWidget(rig.app());
    await _send(tester);
    await _until(tester, () => rig.transports['tus']!.held.isNotEmpty);

    await tester.tap(find.byTooltip('Debug panel'));
    await tester.pumpAndSettle();
    expect(find.text('Parts in flight'), findsOne);
    expect(find.text('Restarts from zero'), findsOne);
    expect(find.text('Ended by the system'), findsOne);

    await tester.tap(find.byKey(const ValueKey('debug.cut')));
    await tester.pump();
    expect(rig.root.cut.value, isTrue);
    expect(
      recorder.whereOp(SchedulerOp.connectivityChanged).single,
      isMpxEvent(fields: containsPair('online', false)),
    );
    await tester.tap(find.byKey(const ValueKey('debug.cut')));
    await tester.pump();
    expect(
      recorder.whereOp(SchedulerOp.connectivityChanged).last,
      isMpxEvent(fields: containsPair('online', true)),
    );

    await tester.tap(find.byKey(const ValueKey('debug.interrupt')));
    await tester.pump();
    expect(
      recorder.whereOp(EnvelopeOp.systemEnded).single,
      isMpxEvent(
        level: MpxEventLevel.warning,
        fields: allOf(
          containsPair('cause', 'simulated'),
          containsPair('jobs', 1),
        ),
      ),
    );
    expect(
      rig.transfers.debugSnapshot().jobs.single.state,
      isA<TransferState$Paused>().having(
        (state) => state.reason,
        'reason',
        PauseReason.systemInterrupted,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('debug.kill')));
    await tester.pump(const Duration(milliseconds: 2900));
    expect(rig.kills, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(rig.kills, 1);
    await rig.close(tester);
  });

  testWidgets('a completed item forwards as a remote item: published with '
      'nothing uploaded', (tester) async {
    await _tall(tester);
    RecordingDiagnostics.install();
    final rig = await _Rig.open();
    await tester.pumpWidget(rig.app());
    await _send(tester);
    await _until(tester, () => rig.publisher.calls.isNotEmpty);
    final item = (await rig.transfers.watchJobs().first).single.items.single;
    // The server's file holding the item, as the server answers it.
    final serverKey = TransfersDemo.serverKeyOf(item)!;
    rig.publisher.answer(
      PublishOutcome.published(serverKeys: {item.itemId: serverKey}),
    );
    await _until(tester, () => find.text('Forward').evaluate().isNotEmpty);
    final opens = rig.transports['tus']!.opens.length;

    await tester.tap(find.text('Forward'));
    await _until(tester, () => rig.publisher.calls.length == 2);

    final refs = rig.publisher.calls.last.items.values.single;
    expect(refs.isRemote, isTrue);
    expect(refs.key, serverKey);
    expect(rig.transports['tus']!.opens, hasLength(opens));
    rig.publisher.answer(PublishOutcome.published());
    await tester.pump();
    await rig.close(tester);
  });

  testWidgets('quitting while a system upload is active asks first; with '
      'none it quits', (tester) async {
    RecordingDiagnostics.install();
    final rig = await _Rig.open(holdParts: true);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => TransfersQuitGuard(
          transfers: rig.transfers,
          navigatorKey: navigator,
          child: child!,
        ),
        home: const SizedBox(),
      ),
    );
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);

    await rig.demo.send(const [_pick], prepare: false);
    await _until(tester, () => rig.transfers.systemActive.value);
    final asked = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    expect(find.text('Uploads are running'), findsOne);
    await tester.tap(find.text('Keep running'));
    await tester.pumpAndSettle();

    expect(await asked, AppExitResponse.cancel);
    await rig.close(tester);
  });

  testWidgets('the server\'s files show as cells, described by their type', (
    tester,
  ) async {
    await _tall(tester);
    RecordingDiagnostics.install();
    final rig = await _Rig.open();
    await tester.pumpWidget(rig.app());
    await tester.pump();

    expect(find.byKey(const ValueKey('transfers.file.f1.mp4')), findsOne);
    expect(rig.demo.files.value.single.descriptor.kind, MediaKind.video);
    await rig.close(tester);
  });
}
