import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';

/// The contract every [UploadSourceCopies] that keeps copies meets: a
/// job's sources read back byte for byte, a new start knows what was kept,
/// and a delete forgets it for good.
abstract final class UploadSourceCopiesContract {
  /// Runs it as a test group named after [name].
  ///
  /// [storage] is called once per test, inside its `setUp`, for fresh,
  /// empty storage; it answers how to open the copies over that storage,
  /// and each call of the answer is a new start over the same bytes. Clean
  /// the storage up with `addTearDown` inside [storage].
  static void run(
    String name,
    Future<UploadSourceCopies> Function() Function() storage,
  ) {
    group('UploadSourceCopies contract ($name)', () {
      late Future<UploadSourceCopies> Function() open;

      setUp(() => open = storage());

      test('fresh storage keeps nothing', () async {
        final copies = await open();
        expect(copies.held, isEmpty);
        expect(copies.holds(_a), isFalse);
        expect(await copies.read(_a, 0), isNull);
      });

      test("a job's sources read back byte for byte, at this start and "
          'the next', () async {
        final copies = await open();
        expect(await copies.copy(_a, [_source(3), _source(5)]), isTrue);
        expect(copies.holds(_a), isTrue);
        await _expectSources(copies, _a, [_bytes(3), _bytes(5)]);

        final again = await open();
        expect(again.held, [_a]);
        await _expectSources(again, _a, [_bytes(3), _bytes(5)]);
        expect(await again.read(_a, 2), isNull);
      });

      test('a slice of a copy reads that range', () async {
        final copies = await open();
        await copies.copy(_a, [_source(10)]);
        final copy = (await copies.read(_a, 0))!;
        expect(await copy.read(2, 6), _bytes(10).sublist(2, 6));
      });

      test('a job with no sources is kept', () async {
        final copies = await open();
        expect(await copies.copy(_a, const []), isTrue);
        expect((await open()).holds(_a), isTrue);
      });

      test('a delete forgets the job for good and keeps the others', () async {
        final copies = await open();
        await copies.copy(_a, [_source(4)]);
        await copies.copy(_b, [_source(6)]);
        await copies.delete(_a);
        expect(copies.holds(_a), isFalse);
        expect(await copies.read(_a, 0), isNull);

        final again = await open();
        expect(again.held, [_b]);
        await _expectSources(again, _b, [_bytes(6)]);
        // Deleting what is not kept does nothing.
        await again.delete(_a);
      });
    });
  }

  static const TransferId _a = TransferId.parse('u-a');
  static const TransferId _b = TransferId.parse('u-b');

  static Uint8List _bytes(int size) =>
      Uint8List.fromList(List.generate(size, (i) => (i * 7 + size) & 0xff));

  static SourceBytes _source(int size) => MemorySourceBytes(_bytes(size));

  static Future<void> _expectSources(
    UploadSourceCopies copies,
    TransferId id,
    List<Uint8List> expected,
  ) async {
    for (var index = 0; index < expected.length; index++) {
      final copy = await copies.read(id, index);
      expect(copy, isNotNull, reason: 'source $index');
      expect(copy!.size, expected[index].length);
      expect(await copy.read(), expected[index]);
    }
  }
}
