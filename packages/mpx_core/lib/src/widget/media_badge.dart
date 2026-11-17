import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/src/asset/asset_binding.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/widget/media_badge_style.dart';
import 'package:mpx_core/src/widget/media_loading_style.dart';

/// The small label over media: its [duration] (or "GIF" when [gif]) and,
/// while it downloads, "received / total" ([transfer]); the total alone
/// while it waits for the user. Two rows when both show; nothing when
/// neither does.
///
/// [MediaBadge.binding] reads all of it from a binding: the descriptor's
/// duration and kind, the transfer, and the playback position, so a clip
/// that plays counts down. Only a video is timed: a GIF
/// (`MediaDescriptor.isGif`) reads "GIF" and any other content has no
/// first row. The style is the platform's
/// (`MediaLoadingStyleScope`) unless [style] is given; [width] is the
/// media's, below `MediaSizeFormat.narrowBelow` a download reads "NN%".
class MediaBadge extends StatefulWidget {
  /// A badge of the given facts.
  const MediaBadge({
    this.duration,
    this.gif = false,
    this.transfer = AssetTransfer.none,
    this.width = double.infinity,
    this.style,
    this.strings = const MediaBadgeStrings(),
    super.key,
  }) : binding = null;

  /// The badge of [binding]'s content.
  const MediaBadge.binding(
    AssetBinding this.binding, {
    this.width = double.infinity,
    this.style,
    this.strings = const MediaBadgeStrings(),
    super.key,
  }) : duration = null,
       gif = false,
       transfer = AssetTransfer.none;

  /// The binding whose content the badge describes, or null.
  final AssetBinding? binding;

  /// The content's duration, or null for none.
  final Duration? duration;

  /// Whether the content is an animated image, labelled instead of timed.
  final bool gif;

  /// The content's download.
  final AssetTransfer transfer;

  /// The width of the media under the badge.
  final double width;

  /// The style, or null for the platform's.
  final MediaBadgeStyle? style;

  /// Unit names and labels.
  final MediaBadgeStrings strings;

  /// The rows of a badge of the given facts: the time (or GIF) first, then
  /// the size; empty when nothing shows.
  static List<String> rowsOf({
    required MediaBadgeStyle style,
    required MediaBadgeStrings strings,
    Duration? duration,
    bool gif = false,
    AssetTransfer transfer = AssetTransfer.none,
    double width = double.infinity,
  }) {
    final format = style.sizeFormat;
    final narrow = width < format.narrowBelow;
    final size = switch (transfer) {
      AssetTransfer$Receiving(:final received, :final total) =>
        narrow && total != null
            ? format.percent(received, total)
            : format.progress(received, total, strings),
      AssetTransfer$Waiting(:final total?) =>
        narrow ? format.percent(0, total) : format.progress(0, total, strings),
      // A download that stopped short shows the bytes it left.
      AssetTransfer$AwaitingUser(:final received, :final total?)
          when received > 0 =>
        narrow
            ? format.percent(received, total)
            : format.progress(received, total, strings),
      AssetTransfer$AwaitingUser(:final total?) ||
      AssetTransfer$Failed(:final total?) => format.size(total, strings),
      _ => null,
    };
    return [
      if (gif)
        strings.gif
      else if (duration != null)
        MediaSizeFormat.duration(duration),
      ?size,
    ];
  }

  @override
  State<MediaBadge> createState() => _MediaBadgeState();
}

class _MediaBadgeState extends State<MediaBadge>
    with SingleTickerProviderStateMixin {
  // Made when a clip first plays under the badge.
  Ticker? _ticker;
  AssetBinding? _listened;
  List<String> _rows = const [];
  // The last rows shown, kept while the badge fades out.
  List<String> _shownRows = const [];
  MediaBadgeStyle? _style;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _style = widget.style ?? MediaLoadingStyleScope.resolve(context).badge;
    _rows = _read();
    if (_rows.isNotEmpty) _shownRows = _rows;
  }

  @override
  void didUpdateWidget(MediaBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding, widget.binding)) _listen();
    _style = widget.style ?? MediaLoadingStyleScope.resolve(context).badge;
    _rows = _read();
    if (_rows.isNotEmpty) _shownRows = _rows;
  }

  void _listen() {
    _listened?.removeListener(_refresh);
    _listened = widget.binding?..addListener(_refresh);
  }

  List<String> _read() {
    final style = _style;
    if (style == null) return const [];
    final binding = widget.binding;
    if (binding == null) {
      return MediaBadge.rowsOf(
        style: style,
        strings: widget.strings,
        duration: widget.duration,
        gif: widget.gif,
        transfer: widget.transfer,
        width: widget.width,
      );
    }
    final descriptor = binding.descriptor;
    final gif = descriptor?.isGif ?? false;
    // Only a video with a timeline is timed: a GIF reads "GIF", and an
    // animation (a sticker, an emoji) has no label.
    var duration = descriptor?.kind == MediaKind.video && !gif
        ? descriptor?.duration
        : null;
    final playing = binding.isPlaying && duration != null;
    if (playing) {
      final position = binding.paintable.playbackPosition;
      if (position != null) duration -= position;
    }
    _syncTicker(playing: playing && !gif);
    return MediaBadge.rowsOf(
      style: style,
      strings: widget.strings,
      duration: duration,
      gif: gif,
      transfer: binding.transfer,
      width: widget.width,
    );
  }

  // A clip that plays counts down: its position is read every frame, and
  // the badge rebuilds only when the text changes.
  void _syncTicker({required bool playing}) {
    final ticker = _ticker;
    if (playing && !(ticker?.isActive ?? false)) {
      (_ticker ??= createTicker((_) => _refresh())).start();
    } else if (!playing && (ticker?.isActive ?? false)) {
      ticker!.stop();
    }
  }

  void _refresh() {
    if (!mounted) return;
    final rows = _read();
    if (_same(rows, _rows)) return;
    setState(() {
      _rows = rows;
      if (rows.isNotEmpty) _shownRows = rows;
    });
  }

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _listened?.removeListener(_refresh);
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = _style!;
    final rows = _shownRows;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _rows.isEmpty ? 0 : 1,
        duration: style.fade,
        child: rows.isEmpty
            ? const SizedBox.shrink()
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: style.background,
                  borderRadius: BorderRadius.circular(style.radius),
                ),
                child: Padding(
                  padding: style.padding,
                  child: AnimatedSize(
                    duration: style.resize,
                    alignment: Alignment.topLeft,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final row in rows)
                          Text(
                            row,
                            style: style.textStyle,
                            maxLines: 1,
                            softWrap: false,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
