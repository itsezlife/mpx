import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';

/// Thumbnail latency as the grid's user sees it, for a lab build: with
/// [enabled], every cell reports how long its thumbnail took from the cell
/// appearing to the picture standing sharp in it, or that it went before.
///
/// Lines go to [log] (by default `debugPrint`), one per cell:
/// `LABthumb sharp <photo|video> <ms>` or `LABthumb gone <photo|video> <ms>`.
abstract final class LibraryGridDiagnostics {
  /// Whether cells report; off in every build that does not turn it on.
  static bool enabled = false;

  /// Where the lines go.
  static void Function(String line) log = debugPrint;
}

/// Wraps a cell's thumbnail with the [LibraryGridDiagnostics] probe: it
/// holds a binding of its own to the thumbnail's entry (the same entry the
/// cell draws, so it costs nothing) and times the entry to its first sharp
/// stage.
class LibraryThumbnailProbe extends StatefulWidget {
  /// Probes [content] decoded as [preset].
  const LibraryThumbnailProbe({
    required this.content,
    required this.preset,
    required this.video,
    required this.child,
    super.key,
  });

  /// The thumbnail's key.
  final MediaKey content;

  /// How the cell decodes it.
  final AssetPreset preset;

  /// Whether the item is a video (the line's kind).
  final bool video;

  /// The cell's picture.
  final Widget child;

  @override
  State<LibraryThumbnailProbe> createState() => _LibraryThumbnailProbeState();
}

class _LibraryThumbnailProbeState extends State<LibraryThumbnailProbe> {
  AssetBinding? _binding;
  final Stopwatch _since = Stopwatch();
  bool _told = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_binding == null) _attach();
  }

  @override
  void didUpdateWidget(LibraryThumbnailProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _detach();
      _attach();
    }
  }

  void _attach() {
    final scope = AssetCacheProvider.maybeOf(context);
    if (scope == null) return;
    _told = false;
    _since
      ..reset()
      ..start();
    final binding = scope.attach(
      widget.content,
      widget.preset.spec,
      widget.preset.profile,
    );
    _binding = binding..addListener(_check);
    _check();
  }

  void _check() {
    final binding = _binding;
    if (_told || binding == null) return;
    if (binding.readiness.stage.index >= AssetStage.firstFrame.index) {
      _told = true;
      _tell('sharp');
    }
  }

  void _tell(String what) => LibraryGridDiagnostics.log(
    'LABthumb $what ${widget.video ? 'video' : 'photo'} '
    '${_since.elapsedMilliseconds}',
  );

  void _detach() {
    final binding = _binding;
    if (binding == null) return;
    if (!_told) _tell('gone');
    binding
      ..removeListener(_check)
      ..detach();
    _binding = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
