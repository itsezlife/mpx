import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

IntakeFile _file(String name, int size) => IntakeFile(
  source: IntakeSource.path('/tmp/$name'),
  name: name,
  size: size,
  modified: DateTime.utc(2026, 11, 20),
);

void main() {
  group('DropTracker', () {
    test('nested enters and leaves keep the drag until the last leave', () {
      final tracker = DropTracker();
      addTearDown(tracker.dispose);
      tracker
        ..add(const DropEnter(DropOffer(types: ['Files'])))
        ..add(const DropEnter(DropOffer(types: ['Files'])))
        ..add(const DropLeave());
      expect(tracker.active, isTrue, reason: 'a child left, the window not');
      tracker.add(const DropLeave());
      expect(tracker.active, isFalse);
    });

    test('the watchdog ends a drag without an over for 500 ms', () {
      fakeAsync((async) {
        final tracker = DropTracker();
        final changes = <bool>[];
        tracker.addListener(() => changes.add(tracker.active));
        tracker.add(const DropEnter(DropOffer()));
        async.elapse(const Duration(milliseconds: 400));
        tracker.add(const DropOver());
        async.elapse(const Duration(milliseconds: 400));
        expect(tracker.active, isTrue, reason: 'the over re-armed it');
        async.elapse(const Duration(milliseconds: 101));
        expect(tracker.active, isFalse);
        expect(changes, [true, false]);
        tracker.dispose();
      });
    });

    test('a drop ends the drag and a later leave changes nothing', () {
      final tracker = DropTracker();
      addTearDown(tracker.dispose);
      tracker
        ..add(const DropEnter(DropOffer()))
        ..add(const DropDone([]))
        ..add(const DropLeave());
      expect(tracker.active, isFalse);
    });

    test('a drag that tells no types is offered as unknown files', () {
      final tracker = DropTracker();
      addTearDown(tracker.dispose);
      tracker.add(const DropEnter(DropOffer()));
      expect(tracker.offer?.types, isEmpty);
      expect(tracker.offer?.hasFiles, isTrue);
    });
  });

  testWidgets('the drop region takes files under the ceiling', (tester) async {
    final source = FakeDropSource();
    final drops = <IntakeDrop>[];
    final refused = <DropRefusal>[];
    DropHover? shown;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 100, top: 50),
            child: SizedBox(
              width: 200,
              height: 200,
              child: IntakeDropRegion(
                source: source,
                maxFileBytes: 100,
                onDrop: drops.add,
                onRefused: (reason, _) => refused.add(reason),
                builder: (context, hover) {
                  shown = hover;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      ),
    );
    source.add(
      const DropEnter(DropOffer(types: ['Files']), position: Offset(110, 60)),
    );
    await tester.pump();
    expect(shown?.position, const Offset(10, 10), reason: 'local');
    source.add(const DropOver(position: Offset(250, 200)));
    await tester.pump();
    expect(shown?.position, const Offset(150, 150), reason: 'follows over');
    source.add(
      DropDone(
        [_file('a.png', 10), _file('big.mov', 1000)],
        refused: 1,
        position: const Offset(260, 210),
      ),
    );
    await tester.pump();
    expect(shown, isNull);
    expect(drops.single.files.map((f) => f.name), ['a.png']);
    expect(
      drops.single.position,
      const Offset(160, 160),
      reason: 'which zone took it',
    );
    expect(refused, [DropRefusal.notAFile, DropRefusal.tooLarge]);
    await tester.pump(const Duration(seconds: 1));
  });

  test('classification table', () {
    IntakeKind of({
      String? mime,
      String? name,
      bool? animated,
      bool? hasAudio,
    }) => IntakeKind.classify(
      mimeType: mime,
      name: name,
      animated: animated,
      hasAudio: hasAudio,
    );
    expect(of(mime: 'image/jpeg'), IntakeKind.photo);
    expect(of(mime: 'image/jpg'), IntakeKind.photo);
    expect(of(mime: 'image/gif'), IntakeKind.animation);
    expect(of(mime: 'image/webp', animated: true), IntakeKind.animation);
    expect(of(mime: 'image/webp'), IntakeKind.photo);
    expect(of(mime: 'image/tiff'), IntakeKind.file);
    expect(of(mime: 'video/mp4'), IntakeKind.video);
    expect(of(mime: 'video/mp4', hasAudio: false), IntakeKind.animation);
    expect(of(mime: 'audio/mpeg'), IntakeKind.audio);
    expect(of(mime: 'application/pdf'), IntakeKind.file);
    expect(of(name: 'clip.MOV'), IntakeKind.video, reason: 'by extension');
    expect(
      of(mime: 'application/octet-stream', name: 'a.gif'),
      IntakeKind.animation,
    );
    expect(of(name: 'notes'), IntakeKind.file);
    expect(of(), IntakeKind.file);
  });

  test('plain fields map to intake files', () async {
    final directory = Directory.systemTemp.createTempSync('mpx_intake');
    addTearDown(() => directory.deleteSync(recursive: true));
    final pasted = await IntakeFiles.fromBytes(
      Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/png',
      directory: directory.path,
    );
    expect(pasted.mimeType, 'image/png');
    expect(pasted.size, 3);
    expect(pasted.name, endsWith('.png'));
    final path = (pasted.source as IntakeSource$Path).path;
    expect(File(path).readAsBytesSync(), [1, 2, 3]);

    final again = await IntakeFiles.fromPath(path);
    expect(again?.dedupKey, pasted.dedupKey);
    expect(again?.mimeType, 'image/png');
    expect(await IntakeFiles.fromPath('${directory.path}/missing'), isNull);
  });

  test('the fake clipboard answers what it holds', () async {
    final reader = FakeClipboardReader([_file('shot.png', 4)]);
    expect((await reader.readFiles()).single.name, 'shot.png');
    expect(reader.reads, 1);
  });
}
