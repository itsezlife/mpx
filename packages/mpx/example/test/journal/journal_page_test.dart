/// The Logs screen filters the journal by level, category and correlation
/// id, opens on one item's events, and exports a file of plain records.
///
/// **Seams:** [JournalViewController] over a [DiagnosticsJournal] (filters,
/// export) and [JournalPage] as its route pushes it (the export button's
/// guard, the details dialog), fed through [RecordingDiagnostics]-shaped
/// events.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_example/journal/controller/journal_view_controller.dart';
import 'package:mpx_example/journal/data/diagnostics_journal.dart';
import 'package:mpx_example/journal/model/journal_record.dart';
import 'package:mpx_example/journal/model/journal_view.dart';
import 'package:mpx_example/journal/view/journal_page.dart';

enum _Op implements DiagnosticOp {
  shown,
  failed;

  @override
  String get category => 'transport';
}

enum _OtherOp implements DiagnosticOp {
  other;

  @override
  String get category => 'binding';
}

/// Emits one event into a recorder, as a package's path does, and hands what
/// it recorded to [journal], as a host's policy does.
void _emit(
  DiagnosticsJournal journal, {
  MpxEventLevel level = MpxEventLevel.info,
  DiagnosticOp? op,
  String? jobId,
  String? itemId,
  MediaKey? mediaKey,
  String? tag,
  Object? error,
}) {
  final recorder = RecordingDiagnostics();
  recorder.emit(
    level,
    op ?? (level == MpxEventLevel.error ? _Op.failed : _Op.shown),
    jobId: jobId,
    itemId: itemId,
    mediaKey: mediaKey,
    tag: tag,
    error: error,
  );
  recorder.events.forEach(journal.addMpxEvent);
}

/// A share sheet that takes its time: it is up until [close].
final class _ShareSheet {
  final files = <JournalExportFile>[];
  Completer<void> _open = Completer<void>();

  Future<void> share(JournalExportFile file, {Rect? origin}) {
    files.add(file);
    return _open.future;
  }

  void close() {
    _open.complete();
    _open = Completer<void>();
  }
}

void main() {
  group('the filter', () {
    late DiagnosticsJournal journal;
    late JournalViewController controller;

    setUp(() {
      journal = DiagnosticsJournal.memory();
      controller = JournalViewController(
        journal: journal,
        share: (_, {origin}) async {},
      );
      addTearDown(journal.dispose);
      addTearDown(controller.dispose);
    });

    test('keeps the records of each correlation id, newest first', () {
      const key = MediaKey.remote('k1');
      final ids = <JournalIdKind, String>{
        JournalIdKind.jobId: 'j1',
        JournalIdKind.itemId: 'i1',
        JournalIdKind.mediaKey: key.encoded,
        JournalIdKind.tag: 't1',
      };
      void emitWith(JournalIdKind kind) => _emit(
        journal,
        jobId: kind == JournalIdKind.jobId ? 'j1' : null,
        itemId: kind == JournalIdKind.itemId ? 'i1' : null,
        mediaKey: kind == JournalIdKind.mediaKey ? key : null,
        tag: kind == JournalIdKind.tag ? 't1' : null,
      );
      for (final kind in ids.keys) {
        emitWith(kind);
        emitWith(kind);
      }
      _emit(journal);
      // Another item of the same job.
      _emit(journal, jobId: 'j1', itemId: 'i2');

      for (final MapEntry(key: kind, value: id) in ids.entries) {
        controller.filterById(kind, id);
        final visible = controller.snapshot.visible;
        expect(visible, isNotEmpty, reason: kind.name);
        expect(
          visible.every((record) => kind.of(record.ids) == id),
          isTrue,
          reason: kind.name,
        );
        controller.filterById(kind, '');
      }
      controller.filterById(JournalIdKind.itemId, 'i1');
      expect(controller.snapshot.visible, hasLength(2));
      controller
        ..filterById(JournalIdKind.itemId, '')
        ..filterById(JournalIdKind.jobId, 'j1');
      expect(controller.snapshot.visible, hasLength(3));
      expect(
        controller.snapshot.visible.first.ids['itemId'],
        'i2',
        reason: 'newest first',
      );
    });

    test('by level and category, counting each level under the rest', () {
      final previous = MpxDiagnostics.current;
      addTearDown(() => MpxDiagnostics.current = previous);
      MpxDiagnostics.current = journal.mpxDiagnostics;
      _emit(journal, op: _OtherOp.other);
      _emit(journal, level: MpxEventLevel.error, op: _OtherOp.other);
      _emit(journal, level: MpxEventLevel.error);
      CacheDiagnosticsBridge.policy.report(
        const BytesLogEvent(
          level: BytesLogLevel.warning,
          message: 'stale',
          op: BytesLogOp.resolveStaleUsed,
        ),
      );

      controller.soloLevel(MpxEventLevel.error);
      expect(controller.snapshot.visible, hasLength(2));
      controller.soloCategory('binding');
      expect(controller.snapshot.visible, hasLength(1));
      expect(controller.snapshot.countOf(MpxEventLevel.info), 1);
      controller
        ..soloLevel(MpxEventLevel.warning)
        ..soloCategory('cache');
      expect(controller.snapshot.visible.single.category, 'cache');
      expect(controller.snapshot.categories, ['binding', 'cache', 'transport']);
    });

    test('"logs of this item" keeps that item\'s records alone', () {
      _emit(journal, itemId: '3');
      _emit(journal, itemId: '30');
      _emit(journal);
      final ofItem = JournalViewController(
        journal: journal,
        share: (_, {origin}) async {},
        filter: JournalFilter.ofItem('3'),
      );
      addTearDown(ofItem.dispose);

      expect(ofItem.snapshot.visible.single.ids['itemId'], '3');
      expect(ofItem.filter.ids, {JournalIdKind.itemId: '3'});
    });

    testWidgets('shows what arrived while paused only on resume, and counts '
        'it', (tester) async {
      final paused = JournalViewController(
        journal: journal,
        share: (_, {origin}) async {},
      );
      _emit(journal);
      await tester.pump(const Duration(milliseconds: 300));
      expect(paused.snapshot.visible, hasLength(1));

      paused.pause();
      _emit(journal);
      _emit(journal);
      await tester.pump(const Duration(milliseconds: 300));
      expect(paused.snapshot.visible, hasLength(1));
      expect(paused.newCount, 2);

      paused.resume();
      expect(paused.snapshot.visible, hasLength(3));
      expect(paused.newCount, 0);
      paused.dispose();
      journal.flush();
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  group('the export', () {
    test('is a header line, then one JSON line per visible record, oldest '
        'first', () async {
      final journal = DiagnosticsJournal.memory();
      addTearDown(journal.dispose);
      final sheet = _ShareSheet();
      final controller = JournalViewController(
        journal: journal,
        share: sheet.share,
        filter: JournalFilter.ofItem('5'),
        clock: () => DateTime(2026, 11, 27, 9, 30, 15),
      );
      addTearDown(controller.dispose);
      for (var n = 0; n < 3; n++) {
        _emit(journal, itemId: '5');
      }
      _emit(journal, itemId: '6');
      final recorder = RecordingDiagnostics.install();

      final done = controller.export();
      sheet.close();
      await done;

      final file = sheet.files.single;
      expect(file.name, 'mpx_log_2026-11-27_09-30-15.jsonl');
      final [header, ...records] = const LineSplitter().convert(
        utf8.decode(file.bytes),
      );
      expect(
        jsonDecode(header),
        allOf([
          containsPair('journal', 1),
          containsPair('records', 3),
          containsPair('build', 'debug'),
          containsPair('mpxCommit', isA<String>()),
          contains('platform'),
          contains('device'),
          contains('osVersion'),
          containsPair('filter', containsPair('ids', {'itemId': '5'})),
        ]),
      );
      expect(records, hasLength(3));
      final times = [
        for (final line in records) JournalRecord.tryParse(line)!.time,
      ];
      expect(times, orderedEquals([...times]..sort()));
      expect(recorder.events, [
        isMpxEvent(
          level: MpxEventLevel.info,
          category: 'journal',
          op: JournalOp.exported,
          fields: containsPair('records', 3),
        ),
      ]);
    });

    test('carries no user content: an error and a cache event naming a URL '
        'and a text leave neither in the file', () async {
      const text = 'Meet me at the north entrance';
      const url = 'https://files.example.com/u/1234/report.pdf?token=s3cr3t';
      final journal = DiagnosticsJournal.memory();
      addTearDown(journal.dispose);
      final previous = MpxDiagnostics.current;
      addTearDown(() => MpxDiagnostics.current = previous);
      MpxDiagnostics.current = journal.mpxDiagnostics;
      final sheet = _ShareSheet();
      final controller = JournalViewController(
        journal: journal,
        share: sheet.share,
      );
      addTearDown(controller.dispose);
      _emit(journal, itemId: '9');
      _emit(
        journal,
        level: MpxEventLevel.error,
        itemId: '9',
        error: 'HttpException: Connection closed, uri = $url',
      );
      CacheDiagnosticsBridge.policy.report(
        const BytesLogEvent(
          level: BytesLogLevel.error,
          message: 'bytes store: write of $url for "$text" failed',
          op: BytesLogOp.writeThrough,
        ),
      );

      final done = controller.export();
      sheet.close();
      await done;

      final content = utf8.decode(sheet.files.single.bytes);
      expect(content, contains('files.example.com'));
      expect(content, isNot(contains('north entrance')));
      expect(content, isNot(contains('report.pdf')));
      expect(content, isNot(contains('/u/1234')));
      expect(content, isNot(contains('s3cr3t')));
    });

    test('a share that fails is reported', () async {
      final journal = DiagnosticsJournal.memory();
      addTearDown(journal.dispose);
      final controller = JournalViewController(
        journal: journal,
        share: (_, {origin}) async => throw StateError('no sheet'),
      );
      addTearDown(controller.dispose);
      _emit(journal);
      final recorder = RecordingDiagnostics.install();

      await controller.export();

      expect(recorder.events, [
        isMpxEvent(
          level: MpxEventLevel.error,
          op: JournalOp.exportFailed,
          error: isA<StateError>(),
        ),
      ]);
      expect(controller.isExporting, isFalse);
    });
  });

  group('the screen', () {
    Future<(DiagnosticsJournal, _ShareSheet)> pushLogs(
      WidgetTester tester, {
      JournalFilter? filter,
    }) async {
      final journal = DiagnosticsJournal.memory();
      addTearDown(journal.dispose);
      _emit(journal, itemId: '4');
      _emit(journal, level: MpxEventLevel.warning, itemId: '4');
      journal.flush();
      final sheet = _ShareSheet();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox.expand()),
      );
      unawaited(
        navigator.currentState!.push(
          JournalPage.route(
            journal: journal,
            filter: filter,
            share: sheet.share,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (journal, sheet);
    }

    testWidgets('lists the records and opens one\'s details', (tester) async {
      await pushLogs(tester);

      expect(find.text('transport.shown'), findsNWidgets(2));
      await tester.tap(find.text('transport.shown').first);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('itemId: 4'), findsOneWidget);
    });

    testWidgets('a burst of taps on export shares one file', (tester) async {
      final (_, sheet) = await pushLogs(tester);

      final export = find.byKey(const ValueKey('journal-export'));
      for (var i = 0; i < 5; i++) {
        await tester.tap(export);
      }
      await tester.pump();
      expect(sheet.files, hasLength(1));

      sheet.close();
      await tester.pump();
      await tester.tap(export);
      await tester.pump();
      expect(sheet.files, hasLength(2), reason: 'a later tap exports again');
      sheet.close();
      await tester.pumpAndSettle();
    });

    testWidgets('opened on one item, shows that item\'s filter and records '
        'alone', (tester) async {
      await pushLogs(tester, filter: JournalFilter.ofItem('4'));

      expect(find.widgetWithText(InputChip, 'itemId=4'), findsOneWidget);
      expect(find.text('Showing 2 of 2'), findsOneWidget);
    });

    testWidgets('the id field narrows the list to one job', (tester) async {
      final (journal, _) = await pushLogs(tester);
      _emit(journal, jobId: 'j9');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Showing 3 of 3'), findsOneWidget);

      await tester.tap(find.byType(DropdownButton<JournalIdKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('jobId').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('journal-id')), 'j9');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Showing 1 of 3'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'jobId=j9'), findsOneWidget);
      journal.flush();
    });
  });
}
