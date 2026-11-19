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
@immutable
sealed class DropEvent {
  const DropEvent();
}

/// A drag entered the window, or a nested element of it.
final class DropEnter extends DropEvent {
  /// Creates the event.
  const DropEnter(this.offer);

  /// What the drag brings.
  final DropOffer offer;
}

/// A drag moved over the window.
final class DropOver extends DropEvent {
  /// Creates the event.
  const DropOver();
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
  const DropDone(this.files, {this.refused = 0});

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
  Timer? _timer;

  /// Whether a drag is over the window.
  bool get active => _offer != null;

  /// What the active drag brings; null when none is.
  DropOffer? get offer => _offer;

  /// Feeds one event.
  void add(DropEvent event) {
    switch (event) {
      case DropEnter(:final offer):
        _depth++;
        if (_offer == null) {
          _offer = offer;
          notifyListeners();
        }
        _arm();
      case DropOver():
        if (_offer != null) _arm();
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
  final ValueChanged<List<IntakeFile>> onDrop;

  /// Builds the region, with the offer of the drag over it (null when none
  /// is).
  final Widget Function(BuildContext context, DropOffer? offer) builder;

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
    if (taken.isNotEmpty) widget.onDrop(taken);
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
    builder: (context, _) =>
        widget.source.wrap(widget.builder(context, _tracker.offer)),
  );
}

/// Reads files and image data from the system clipboard: `super_clipboard`
/// on native platforms, the web's async clipboard, or `FakeClipboardReader`.
abstract interface class ClipboardReader {
  /// The files on the clipboard, and its image data written to local files
  /// (memory on the web); empty when it holds neither.
  Future<List<IntakeFile>> readFiles();
}
