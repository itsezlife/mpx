import 'dart:async';

import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';

/// [UploadSourceCopies] in memory that outlive the engine, as OPFS outlives
/// a reload: give the same fake to each start.
///
/// A test can hold copies back ([holdCopies]) to reload in the middle of
/// one, or make the storage refuse them ([refuseCopies]).
final class FakeUploadSourceCopies implements UploadSourceCopies {
  final Map<TransferId, List<SourceBytes>> _kept = {};
  final List<TransferId> _deleted = [];
  Completer<bool>? _hold;

  /// Whether a copy throws, as storage out of room would.
  bool refuseCopies = false;

  /// Every job whose copies were deleted, oldest first.
  List<TransferId> get deleted => List.unmodifiable(_deleted);

  /// Makes every copy wait until [releaseCopies] or [cutCopies].
  void holdCopies() => _hold ??= Completer<bool>();

  /// Lets the copies held back by [holdCopies] finish and be kept.
  void releaseCopies() => _end(keep: true);

  /// Ends the copies held back by [holdCopies] without keeping them, as a
  /// reload in the middle of a copy does.
  void cutCopies() => _end(keep: false);

  void _end({required bool keep}) {
    _hold?.complete(keep);
    _hold = null;
  }

  @override
  bool holds(TransferId id) => _kept.containsKey(id);

  @override
  Iterable<TransferId> get held => [..._kept.keys];

  @override
  Future<bool> copy(TransferId id, List<SourceBytes> sources) async {
    if (_hold case final hold?) {
      // A reload cut it short: nothing of it is kept.
      if (!await hold.future) return false;
    }
    if (refuseCopies) throw StateError('copy refused');
    _kept[id] = List.unmodifiable(sources);
    return true;
  }

  @override
  Future<SourceBytes?> read(TransferId id, int index) async {
    final sources = _kept[id];
    if (sources == null || index >= sources.length) return null;
    return sources[index];
  }

  @override
  Future<void> delete(TransferId id) async {
    if (_kept.remove(id) != null) _deleted.add(id);
  }

  @override
  String errorCode(Object error) => 'refused';
}
