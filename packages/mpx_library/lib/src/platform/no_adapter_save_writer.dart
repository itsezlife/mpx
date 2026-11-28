import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_result.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The writer of a platform with no save adapter: it admits no batch, so
/// every item fails `SaveFailure.unavailable` with the code `noAdapter`.
///
/// The runner checks the access first, as for every writer, so a denied
/// access or a build without the save code reads the same before and after
/// the platform's adapter lands.
final class NoAdapterSaveWriter extends SaveWriter$PerItem {
  /// The writer standing in on [platform].
  const NoAdapterSaveWriter(this.platform);

  @override
  final String platform;

  @override
  Future<SaveResult$Failed?> admit(
    String jobId,
    SaveDestination destination,
    List<SaveItem> items,
  ) async =>
      const SaveResult$Failed(SaveFailure.unavailable, code: 'noAdapter');

  @override
  Future<SaveResult> write(
    SaveWrite write, {
    required FetchProgress onProgress,
    required CancellationToken cancellation,
  }) => throw StateError('A batch this writer refused is never written.');
}
