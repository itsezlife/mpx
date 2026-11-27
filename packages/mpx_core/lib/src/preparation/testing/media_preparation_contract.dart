import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/src/preparation/media_preparation.dart';
import 'package:mpx_core/src/preparation/preparation_input.dart';
import 'package:mpx_core/src/preparation/prepared_media.dart';

/// What a [MediaPreparation] contract run needs besides the implementation.
final class MediaPreparationHarness {
  /// Creates a harness around [preparation].
  const MediaPreparationHarness({
    required this.preparation,
    required this.input,
    required this.intent,
    required this.unpreparable,
    this.settle = _idle,
    this.dispose,
  });

  /// The implementation under test.
  final MediaPreparation preparation;

  /// An item the implementation prepares as [intent] says.
  final PreparationInput input;

  /// How [input] is prepared.
  final PreparationIntent intent;

  /// An item the implementation cannot prepare as [intent] says (a file
  /// that does not exist, bytes that are no picture).
  final PreparationInput unpreparable;

  /// Lets the implementation's work run: a real one waits for its codecs, a
  /// fake runs its script. Called until each handle under test settles.
  final Future<void> Function() settle;

  /// Releases what the harness made.
  final Future<void> Function()? dispose;

  static Future<void> _idle() => Future<void>.delayed(Duration.zero);
}

/// The contract every [MediaPreparation] meets: progress from 0 to 1 that
/// never goes back, a prepared file, a typed failure and a cancel that wins.
abstract final class MediaPreparationContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(FutureOr<MediaPreparationHarness> Function() create) {
    group('MediaPreparation contract', () {
      late MediaPreparationHarness harness;

      setUp(() async => harness = await create());
      tearDown(() async => harness.dispose?.call());

      // Settles [handle] by running the harness, and answers its outcome.
      Future<Object> outcome(PreparationHandle handle) async {
        Object? settled;
        unawaited(
          handle.result.then<void>(
            (media) => settled = media,
            onError: (Object error) => settled = error,
          ),
        );
        for (var round = 0; round < 1000 && settled == null; round++) {
          await harness.settle();
        }
        return settled ?? fail('the preparation never settled');
      }

      test('prepares the item into a file, its progress rising to 1', () async {
        final handle = harness.preparation.prepare(
          harness.input,
          harness.intent,
        );
        final seen = <double>[handle.progress.value];
        handle.progress.addListener(() => seen.add(handle.progress.value));

        final media = await outcome(handle);

        expect(media, isA<PreparedMedia>());
        media as PreparedMedia;
        expect(media.path, isNotEmpty);
        expect(media.byteSize, greaterThan(0));
        expect(media.kind, switch (harness.intent) {
          PreparationIntent$Photo() => PreparedKind.photo,
          PreparationIntent$Video() => PreparedKind.video,
          PreparationIntent$File() => anything,
        });
        expect(seen.first, inInclusiveRange(0, 1));
        expect(seen, orderedEquals([...seen]..sort()));
        expect(handle.progress.value, 1);
      });

      test('fails an item it cannot prepare with PreparationFailed', () async {
        final handle = harness.preparation.prepare(
          harness.unpreparable,
          harness.intent,
        );

        final error = await outcome(handle);

        expect(error, isA<PreparationFailed>());
        expect((error as PreparationFailed).code, isNotEmpty);
      });

      test('cancel fails the result with PreparationCancelled, once', () async {
        final handle = harness.preparation.prepare(
          harness.input,
          harness.intent,
        );

        await handle.cancel();
        await handle.cancel();

        expect(await outcome(handle), const PreparationCancelled());
      });

      test('cancel after the result does nothing', () async {
        final handle = harness.preparation.prepare(
          harness.input,
          harness.intent,
        );
        final media = await outcome(handle);

        await handle.cancel();

        expect(await handle.result, media);
        expect(handle.progress.value, 1);
      });
    });
  }
}
