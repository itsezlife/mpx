/// The web intake in a real browser:
/// `flutter test --platform chrome test/web`. The VM gate skips it
/// (`@TestOn`), and `unit_test.dart` does not import it: `package:web`
/// does not compile for the VM.
@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:web/web.dart' as web;

void main() {
  test('the platform routes are the web ones', () async {
    expect(PlatformIntake.dropSource(), isNotNull);
    expect(PlatformIntake.clipboardReader(), isNotNull);
    final intake = await PlatformIntake.fileIntake();
    expect(intake.canCaptureWithSystemCamera, isFalse);
  });

  test('DOM drags come out as drop events with blob files', () async {
    final source = PlatformIntake.dropSource()!;
    final events = <DropEvent>[];
    final subscription = source.events.listen(events.add);
    final transfer = web.DataTransfer();
    transfer.items.add(
      web.File(
        ['abc'.toJS].toJS,
        'a.png',
        web.FilePropertyBag(type: 'image/png'),
      ),
    );
    void fire(String type) => web.document.dispatchEvent(
      web.DragEvent(
        type,
        web.DragEventInit(dataTransfer: transfer, clientX: 30, clientY: 40),
      ),
    );
    fire('dragenter');
    fire('dragover');
    fire('drop');
    await pumpEventQueue();
    await subscription.cancel();

    expect(events.first, isA<DropEnter>());
    expect((events.first as DropEnter).offer.types, contains('Files'));
    expect(events[1], isA<DropOver>());
    final done = events.last as DropDone;
    expect(done.files.single.name, 'a.png');
    expect(done.files.single.size, 3);
    expect(done.files.single.source, isA<IntakeSource$Blob>());
    expect(done.position, const Offset(30, 40));
    expect((events[1] as DropOver).position, const Offset(30, 40));
  });

  test('a pick ends empty when the window returns from the dialog with '
      'nothing', () async {
    final intake = await PlatformIntake.fileIntake();
    final pick = intake.pickFiles(filter: IntakeFilter.images);
    web.window.dispatchEvent(web.Event('focus'));
    expect(await pick.timeout(const Duration(seconds: 3)), isEmpty);
  });
}
