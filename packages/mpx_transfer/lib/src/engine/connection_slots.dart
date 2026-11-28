import 'dart:async';
import 'dart:collection';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/scheduler_op.dart';
import 'package:mpx_transfer/src/diagnostics/transfers_debug_snapshot.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';

/// The connections the engine's requests share: [cap] at once over both
/// directions, at most [downloadCap] of them downloads and [uploadCap]
/// uploads, so neither direction can hold every connection.
///
/// A request holds a slot while it is on the wire and none while it waits
/// to try again. Waiters are served in arrival order: a freed slot goes to
/// the earliest waiter whose direction is under its cap. Internal to the
/// package.
final class ConnectionSlots {
  /// Slots under the given caps.
  ConnectionSlots({
    this.cap = defaultCap,
    this.downloadCap = defaultDownloadCap,
    this.uploadCap = defaultUploadCap,
  }) : assert(cap > 0, 'cap must be positive'),
       assert(
         downloadCap > 0 && downloadCap <= cap,
         'downloadCap must be in 1..cap',
       ),
       assert(uploadCap > 0 && uploadCap <= cap, 'uploadCap must be in 1..cap');

  /// Connections over both directions by default: 8.
  static const int defaultCap = 8;

  /// Connections downloads may hold by default: 6.
  static const int defaultDownloadCap = 6;

  /// Connections uploads may hold by default: 6, the bytes cache's own
  /// upload cap, so two stay free for downloads.
  static const int defaultUploadCap = 6;

  /// Connections over both directions.
  final int cap;

  /// Connections downloads may hold.
  final int downloadCap;

  /// Connections uploads may hold.
  final int uploadCap;

  final Map<TransferDirection, int> _inUse = {
    for (final direction in TransferDirection.values) direction: 0,
  };
  final Queue<_Waiter> _waiters = Queue();

  /// Connections [direction] holds now.
  int inUse(TransferDirection direction) => _inUse[direction]!;

  /// A slot for a request of job [job] in [direction], once one is free.
  Future<ConnectionSlot> acquire(TransferDirection direction, TransferId job) {
    // Every waiter is at a cap (a freed slot would have gone to it), so a
    // request that fits takes its slot past them.
    if (_fits(direction)) {
      return Future.value(_take(direction, job));
    }
    final waiter = _Waiter(direction, job);
    _waiters.add(waiter);
    return waiter.completer.future;
  }

  /// The connections section of a debug snapshot.
  ConnectionsDebugSnapshot debugSnapshot() => ConnectionsDebugSnapshot(
    cap: cap,
    downloadCap: downloadCap,
    uploadCap: uploadCap,
    downloads: inUse(TransferDirection.download),
    uploads: inUse(TransferDirection.upload),
    waiting: _waiters.length,
  );

  int _capOf(TransferDirection direction) => switch (direction) {
    TransferDirection.download => downloadCap,
    TransferDirection.upload => uploadCap,
  };

  bool _fits(TransferDirection direction) =>
      _inUse.values.fold(0, (sum, n) => sum + n) < cap &&
      inUse(direction) < _capOf(direction);

  ConnectionSlot _take(TransferDirection direction, TransferId job) {
    final inUse = _inUse[direction] = this.inUse(direction) + 1;
    MpxDiagnostics.current.emit(
      MpxEventLevel.trace,
      SchedulerOp.slotAcquired,
      jobId: job,
      fields: () => {
        'direction': direction.name,
        'inUse': inUse,
        'cap': _capOf(direction),
      },
    );
    return ConnectionSlot._(this, direction, job);
  }

  void _release(ConnectionSlot slot) {
    final inUse = _inUse[slot._direction] = this.inUse(slot._direction) - 1;
    MpxDiagnostics.current.emit(
      MpxEventLevel.trace,
      SchedulerOp.slotReleased,
      jobId: slot._job,
      fields: () => {
        'direction': slot._direction.name,
        'inUse': inUse,
        'cap': _capOf(slot._direction),
      },
    );
    // The earliest waiter that fits goes first; a waiter whose direction is
    // at its cap does not hold up one of the other direction behind it.
    for (final waiter in [..._waiters]) {
      if (!_fits(waiter.direction)) continue;
      _waiters.remove(waiter);
      waiter.completer.complete(_take(waiter.direction, waiter.job));
    }
  }
}

/// One connection held by a request; [release] gives it back, once.
final class ConnectionSlot {
  ConnectionSlot._(this._slots, this._direction, this._job);

  final ConnectionSlots _slots;
  final TransferDirection _direction;
  final TransferId _job;
  bool _released = false;

  /// Gives the connection back; later calls do nothing.
  void release() {
    if (_released) return;
    _released = true;
    _slots._release(this);
  }
}

final class _Waiter {
  _Waiter(this.direction, this.job);

  final TransferDirection direction;
  final TransferId job;
  final Completer<ConnectionSlot> completer = Completer();
}
