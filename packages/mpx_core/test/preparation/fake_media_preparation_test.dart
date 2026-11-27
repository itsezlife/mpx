import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _input = PreparationInput('/picked/a.jpg', byteSize: 2000);
const _intent = PreparationIntent.photo();

void main() {
  // The script a real preparer would follow: half way, then done, unless the
  // input is the one it cannot read.
  MediaPreparationContract.run(() {
    final fake = FakeMediaPreparation();
    return MediaPreparationHarness(
      preparation: fake,
      input: _input,
      intent: _intent,
      unpreparable: const PreparationInput('/picked/missing.jpg'),
      settle: () async {
        for (final handle in fake.pending) {
          if (handle.input.path.contains('missing')) {
            handle.fail();
          } else if (handle.progress.value < 0.5) {
            handle.report(0.5);
          } else {
            handle.complete();
          }
        }
        await Future<void>.delayed(Duration.zero);
      },
    );
  });

  group('FakeMediaPreparation', () {
    late FakeMediaPreparation fake;

    setUp(() => fake = FakeMediaPreparation());

    test('records each item and hands its handle to onPrepare', () {
      final scripted = <FakePreparationHandle>[];
      fake.onPrepare = scripted.add;

      final handle = fake.prepare(_input, _intent);

      expect(fake.handles, [handle]);
      expect(fake.last, same(handle));
      expect(scripted, [handle]);
      expect(handle.input, _input);
      expect(handle.intent, _intent);
    });

    test('progress never goes back and is clamped', () {
      final handle = fake.prepare(_input, _intent)
        ..report(0.6)
        ..report(0.2);
      expect(handle.progress.value, 0.6);

      handle.report(4);
      expect(handle.progress.value, 1);
    });

    test('completes with a prepared file named beside the input', () async {
      final handle = fake.prepare(_input, const PreparationIntent.video())
        ..complete();

      final media = await handle.result;
      expect(media.kind, PreparedKind.video);
      expect(media.path, '/picked/a.jpg.prepared');
      expect(media.thumbnailPath, '/picked/a.jpg.thumbnail.jpg');
      expect(fake.pending, isEmpty);
    });

    test('fails with the code given', () async {
      final handle = fake.prepare(_input, _intent)..fail('noSpace');

      await expectLater(
        handle.result,
        throwsA(const PreparationFailed('noSpace')),
      );
    });

    test('counts cancels and reports one cancelled outcome', () async {
      final handle = fake.prepare(_input, _intent);

      await handle.cancel();
      await handle.cancel();
      handle.complete();

      expect(handle.cancels, 2);
      expect(handle.isCancelled, isTrue);
      await expectLater(handle.result, throwsA(const PreparationCancelled()));
    });
  });

  group('preparation values', () {
    test('compare by value', () {
      expect(
        const PreparationInput('/a', mimeType: 'image/png'),
        const PreparationInput('/a', mimeType: 'image/png'),
      );
      expect(const PreparationInput('/a'), isNot(const PreparationInput('/b')));
      expect(
        const PreparationIntent.video(preset: CompressionPreset.low),
        const PreparationIntent.video(preset: CompressionPreset.low),
      );
      expect(
        const PreparationIntent.video(preset: CompressionPreset.low),
        isNot(const PreparationIntent.video(preset: CompressionPreset.high)),
      );
      expect(
        const PreparationIntent.photo(),
        isNot(const PreparationIntent.photo(highQuality: true)),
      );
      expect(const PreparationIntent.file(), const PreparationIntent.file());
    });

    test('a failure code carries no cause into its text', () {
      const failed = PreparationFailed(
        'unreadable',
        cause: '/home/me/secret.jpg',
      );

      expect(failed.toString(), 'PreparationFailed(unreadable)');
    });
  });
}
