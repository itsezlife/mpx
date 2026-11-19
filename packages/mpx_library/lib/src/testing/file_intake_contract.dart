import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/src/intake/file_intake.dart';

/// What a [FileIntake] contract run needs.
///
/// The system dialogs need a user, so the harness arranges what the next
/// dialog answers: a fake scripts it, a device run asks a person to pick.
final class FileIntakeHarness {
  /// Creates a harness over [intake].
  const FileIntakeHarness({
    required this.intake,
    required this.arrangeTwoFiles,
    required this.arrangeDismissal,
  });

  /// The intake under test, fresh for each test.
  final FileIntake intake;

  /// Makes the next pick answer two different files.
  final Future<void> Function() arrangeTwoFiles;

  /// Makes the next pick or capture answer as dismissed.
  final Future<void> Function() arrangeDismissal;
}

/// The contract every [FileIntake] meets; see its documentation.
abstract final class FileIntakeContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(FileIntakeHarness Function() create) {
    group('FileIntake contract', () {
      late FileIntakeHarness harness;

      setUp(() => harness = create());

      test('a multiple pick answers every chosen file', () async {
        await harness.arrangeTwoFiles();
        final files = await harness.intake.pickFiles();
        expect(files, hasLength(2));
        expect(files.map((f) => f.dedupKey).toSet(), hasLength(2));
        for (final file in files) {
          expect(file.name, isNotEmpty);
          expect(file.size, greaterThanOrEqualTo(0));
        }
      });

      test('a single pick answers at most one file', () async {
        await harness.arrangeTwoFiles();
        final files = await harness.intake.pickFiles(multiple: false);
        expect(files.length, lessThanOrEqualTo(1));
      });

      test('a dismissed dialog answers no file', () async {
        await harness.arrangeDismissal();
        expect(
          await harness.intake.pickFiles(filter: IntakeFilter.images),
          isEmpty,
        );
      });

      test('the system camera answers null when cancelled, and is refused '
          'where it is missing', () async {
        if (harness.intake.canCaptureWithSystemCamera) {
          await harness.arrangeDismissal();
          expect(
            await harness.intake.captureWithSystemCamera(
              IntakeCaptureKind.photo,
            ),
            isNull,
          );
        } else {
          expect(
            () =>
                harness.intake.captureWithSystemCamera(IntakeCaptureKind.photo),
            throwsUnsupportedError,
          );
        }
      });
    });
  }
}
