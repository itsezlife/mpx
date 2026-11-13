import 'package:flutter/material.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/gallery.dart';
import 'package:mpx_example/lab/corpus.dart';
import 'package:mpx_example/lab/lab.dart';
import 'package:mpx_example/lab/lab_viewer.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

/// The kinds named in [text] (`loop,video,lottie`), all when empty.
Set<CorpusKind> parseKinds(String text) {
  final names = text.split(',').map((s) => s.trim()).where((s) => s != '');
  final byName = CorpusKind.values.asNameMap();
  final kinds = {for (final n in names) ?byName[n]};
  return kinds.isEmpty ? CorpusKind.values.toSet() : kinds;
}

/// The stress feed's items: [count] items cycling through the [sources] of
/// the chosen kinds, each under a key of its own when [distinct] (its own
/// bytes, decode and playback), else one key per source (every item of a
/// source then shares one playback).
final class StressItems {
  StressItems({
    required this.count,
    required List<CorpusEntry> sources,
    required Set<CorpusKind> kinds,
    required this.distinct,
  }) : sources = [
         for (final s in sources)
           if (kinds.contains(s.kind)) s,
       ] {
    if (this.sources.isEmpty) {
      throw ArgumentError.value(kinds, 'kinds', 'No source of these kinds');
    }
  }

  final int count;
  final List<CorpusEntry> sources;
  final bool distinct;

  /// The file of every stress key made known so far.
  static final Map<MediaKey, String> _files = {};

  int _sourceOf(int index) => index % sources.length;

  CorpusEntry sourceAt(int index) => sources[_sourceOf(index)];

  /// The key of item [index], named after its file, so a key always
  /// means the same bytes whatever the switches.
  MediaKey keyAt(int index) {
    final file = sourceAt(index).file;
    final key = MediaKey.remote(distinct ? 'lab-$index-$file' : 'lab-$file');
    _files[key] = file;
    return key;
  }

  /// The file of a stress key, or null for any other key.
  static String? fileOf(MediaKey key) => _files[key];

  /// Makes every item known to [stack]'s pipeline.
  void know(MpxStack stack) {
    for (var i = 0; i < count; i++) {
      final source = sourceAt(i);
      final key = keyAt(i);
      stack.pipeline.know(
        MediaDescriptor(
          key: key,
          kind: source.kind.media,
          animated: source.kind != CorpusKind.still,
          byteSize: source.size,
        ),
      );
    }
  }

  @override
  String toString() =>
      'items=$count sources=${sources.length} '
      'kinds=${{for (final s in sources) s.kind.name}.join(',')} '
      'distinct=$distinct';
}

/// The lab's heavy feed: [items] through `FeedListView`, built as the
/// example's feed list is, so a run measures the real path. Every cell is a
/// viewer origin; a tap opens the viewer with the players.
class StressFeedPage extends StatefulWidget {
  const StressFeedPage({
    required this.items,
    required this.signals,
    this.players,
    super.key,
  });

  final StressItems items;
  final IDeviceSignals signals;
  final PlayerPool? players;

  @override
  State<StressFeedPage> createState() => _StressFeedPageState();
}

class _StressFeedPageState extends State<StressFeedPage> {
  static const double _extent = 220;

  final ScrollController _scroll = ScrollController();

  late final FeedSignals _conditions = FeedSignals.adapt(
    network: widget.signals.network,
    toNetwork: (value) => FeedNetwork.values.byName(value.name),
    powerSaving: widget.signals.powerSaving,
    thermal: widget.signals.thermal,
    toThermal: (value) => FeedThermal.values.byName(value.name),
  );

  late final ListGallery _gallery = ListGallery([
    for (var i = 0; i < widget.items.count; i++)
      GalleryItem(
        widget.items.keyAt(i),
        kind: widget.items.sourceAt(i).kind.gallery,
      ),
  ]);

  @override
  void initState() {
    super.initState();
    Lab.feedOpened(this, widget.items, _scroll, _extent);
  }

  @override
  void dispose() {
    Lab.feedClosed(this);
    _scroll.dispose();
    _gallery.dispose();
    _conditions.dispose();
    super.dispose();
  }

  AssetPreset _preset(double dpr, AssetProfile profile) => AssetPresets.media(
    size: const Size(360, _extent - 20),
    devicePixelRatio: dpr,
    profile: profile,
  );

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final items = widget.items;
    return Scaffold(
      appBar: AppBar(title: Text('Stress feed: ${items.count}')),
      body: SafeArea(
        top: false,
        child: ViewerOriginScope(
          child: FeedListView(
            controller: _scroll,
            itemCount: items.count,
            itemExtent: _extent,
            conditions: _conditions,
            itemOf: (index) => FeedItem(
              items.keyAt(index),
              hasAudio: items.sourceAt(index).kind == CorpusKind.video,
            ),
            presetOf: (index, profile) => _preset(dpr, profile),
            cellBuilder: (context, index, clip) {
              LabViewer.card(
                'stress',
                index,
                items.keyAt(index),
                _preset(dpr, const AssetProfile()).spec,
              );
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: GestureDetector(
                    // The picture paints without taking hits: the whole cell does.
                    behavior: HitTestBehavior.opaque,
                    onTap: () => MediaViewer.show(
                      context,
                      source: _gallery,
                      initialIndex: index,
                      players: widget.players,
                      controller: LabViewer.controller('stress'),
                      policy: LabViewer.policy(context),
                      onBackdropScale: LabViewer.onBackdropScale,
                    ),
                    child: ViewerOrigin(index: index, child: clip),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
