import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mpx_library/src/intake/file_intake.dart';

/// What a drag over the host's window brings: the types it says it carries
/// (empty when the platform tells none, as Safari does before a drop).
@immutable
final class DropOffer {
  /// Describes an offer.
  const DropOffer({this.types = const [], this.hasFiles = true});

  /// The MIME types (or platform type names) the drag carries.
  final List<String> types;

  /// Whether the drag carries files at all; a text or link drag does not.
  final bool hasFiles;

  @override
  String toString() => 'DropOffer($types, files: $hasFiles)';
}

/// One step of a drag over the window, as a drop source reports it.
///
/// [position] is the pointer in global logical coordinates when the
/// platform tells it (on over and drop everywhere; on enter where the
/// platform gives one); `IntakeDropRegion` turns it local to the region, so
/// a host with zones in the region (a "send as files" and a "send as media"
/// half) knows which one the drag is over and which one took the drop.
@immutable
sealed class DropEvent {
  const DropEvent({this.position});

  /// The pointer, global logical coordinates; null when the platform did
  /// not tell.
  final Offset? position;
}

/// A drag entered the window, or a nested element of it.
final class DropEnter extends DropEvent {
  /// Creates the event.
  const DropEnter(this.offer, {super.position});

  /// What the drag brings.
  final DropOffer offer;
}

/// A drag moved over the window.
final class DropOver extends DropEvent {
  /// Creates the event.
  const DropOver({super.position});
}

/// A drag left the window, or a nested element of it.
final class DropLeave extends DropEvent {
  /// Creates the event.
  const DropLeave();
}

/// A drag was dropped: the files it carried ([files]) and the items that
/// were not local files (links, remote URLs), refused.
final class DropDone extends DropEvent {
  /// Creates the event.
  const DropDone(this.files, {this.refused = 0, super.position});

  /// The local files dropped.
  final List<IntakeFile> files;

  /// How many items were not local files.
  final int refused;
}

/// Reports drags over the host's window: `super_drag_and_drop`'s drop
/// region on native platforms, the web's DOM events, or `FakeDropSource`.
abstract interface class DropSource {
  /// The drag events, in order. Broadcast.
  Stream<DropEvent> get events;

  /// Puts [child] where drags are taken: the native drop region around it,
  /// or [child] itself where the source listens to the whole window (the
  /// web's document).
  Widget wrap(Widget child);
}

/// Whether a drag is over the window, from the raw events of a
/// [DropSource].
///
/// DOM drags enter and leave every nested element, so [active] counts
/// enters against leaves instead of trusting one leave. A drag that leaves
/// the window without a leave event (the pointer left too fast, the source
/// app crashed) would keep [active] on, so a watchdog turns it off when no
/// over event came for [watchdog].
final class DropTracker extends ChangeNotifier {
  /// Creates a tracker; [watchdog] is 500 ms by default.
  DropTracker({this.watchdog = const Duration(milliseconds: 500)});

  /// How long without an over event ends a drag.
  final Duration watchdog;

  int _depth = 0;
  DropOffer? _offer;
  Offset? _position;
  Timer? _timer;

  /// Whether a drag is over the window.
  bool get active => _offer != null;

  /// What the active drag brings; null when none is.
  DropOffer? get offer => _offer;

  /// Where the active drag's pointer is (global), when known.
  Offset? get position => _position;

  /// Feeds one event.
  void add(DropEvent event) {
    final moved =
        event.position != null &&
        event.position != _position &&
        event is! DropDone &&
        event is! DropLeave;
    if (moved) _position = event.position;
    switch (event) {
      case DropEnter(:final offer):
        _depth++;
        if (_offer == null) {
          _offer = offer;
          notifyListeners();
        } else if (moved) {
          notifyListeners();
        }
        _arm();
      case DropOver():
        if (_offer != null) {
          _arm();
          if (moved) notifyListeners();
        }
      case DropLeave():
        if (_depth > 0) _depth--;
        if (_depth == 0) _end();
      case DropDone():
        _end();
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(watchdog, _end);
  }

  void _end() {
    _timer?.cancel();
    _timer = null;
    _depth = 0;
    _position = null;
    if (_offer == null) return;
    _offer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// A drag over a drop region: what it brings, and where the pointer is in
/// the region (local logical coordinates; null when the platform did not
/// tell yet).
@immutable
final class DropHover {
  /// Describes the drag.
  const DropHover(this.offer, this.position);

  /// What the drag brings.
  final DropOffer offer;

  /// The pointer, local to the region.
  final Offset? position;

  @override
  String toString() => 'DropHover($offer, $position)';
}

/// Files dropped on a drop region, and where (local to the region).
@immutable
final class IntakeDrop {
  /// Describes a drop.
  const IntakeDrop(this.files, this.position);

  /// The local files taken.
  final List<IntakeFile> files;

  /// Where the drop landed, local to the region; null when the platform
  /// did not tell.
  final Offset? position;

  @override
  String toString() => 'IntakeDrop(${files.length} files at $position)';
}

/// Why a dropped item was not taken.
enum DropRefusal {
  /// It was not a local file (a link, a remote URL, text).
  notAFile,

  /// It was larger than the host's ceiling.
  tooLarge,
}

/// A region of the host's window that takes dropped files: it shows
/// [builder]'s child with whether a drag is over it, and hands the dropped
/// local files to [onDrop].
///
/// Files only: items that are not local files are refused, and so are files
/// over [maxFileBytes]; [onRefused] hears of each. The drag's types are
/// whatever the platform tells; a drag that tells none is offered as
/// unknown files.
class IntakeDropRegion extends StatefulWidget {
  /// Creates the region over [source].
  const IntakeDropRegion({
    required this.source,
    required this.onDrop,
    required this.builder,
    this.maxFileBytes,
    this.onRefused,
    this.watchdog = const Duration(milliseconds: 500),
    super.key,
  });

  /// Where the drag events come from.
  final DropSource source;

  /// Called with the dropped files that passed.
  final ValueChanged<IntakeDrop> onDrop;

  /// Builds the region, with the drag over it (null when none is): what it
  /// brings and where its pointer is in the region.
  final Widget Function(BuildContext context, DropHover? hover) builder;

  /// The largest file taken, in bytes; null for no ceiling.
  final int? maxFileBytes;

  /// Called for each item refused, with why.
  final void Function(DropRefusal reason, IntakeFile? file)? onRefused;

  /// How long without an over event ends a drag.
  final Duration watchdog;

  @override
  State<IntakeDropRegion> createState() => _IntakeDropRegionState();
}

class _IntakeDropRegionState extends State<IntakeDropRegion> {
  late DropTracker _tracker = DropTracker(watchdog: widget.watchdog);
  StreamSubscription<DropEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(IntakeDropRegion old) {
    super.didUpdateWidget(old);
    if (old.watchdog != widget.watchdog) {
      _tracker.dispose();
      _tracker = DropTracker(watchdog: widget.watchdog);
    }
    if (!identical(old.source, widget.source)) {
      unawaited(_subscription?.cancel());
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.source.events.listen((event) {
      _tracker.add(event);
      if (event is DropDone) _take(event);
    });
  }

  void _take(DropDone drop) {
    for (var i = 0; i < drop.refused; i++) {
      widget.onRefused?.call(DropRefusal.notAFile, null);
    }
    final ceiling = widget.maxFileBytes;
    final taken = <IntakeFile>[];
    for (final file in drop.files) {
      if (ceiling != null && file.size > ceiling) {
        widget.onRefused?.call(DropRefusal.tooLarge, file);
      } else {
        taken.add(file);
      }
    }
    if (taken.isNotEmpty)
      widget.onDrop(IntakeDrop(taken, _local(drop.position)));
  }

  Offset? _local(Offset? global) {
    final box = context.findRenderObject() as RenderBox?;
    if (global == null || box == null || !box.hasSize) return null;
    return box.globalToLocal(global);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _tracker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _tracker,
    builder: (context, _) {
      final offer = _tracker.offer;
      return widget.source.wrap(
        widget.builder(
          context,
          offer == null ? null : DropHover(offer, _local(_tracker.position)),
        ),
      );
    },
  );
}

/// Reads files and image data from the system clipboard: `super_clipboard`
/// on native platforms, the web's async clipboard, or `FakeClipboardReader`.
abstract interface class ClipboardReader {
  /// The files on the clipboard, and its image data written to local files
  /// (memory on the web); empty when it holds neither.
  Future<List<IntakeFile>> readFiles();
}
