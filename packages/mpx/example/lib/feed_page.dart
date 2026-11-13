import 'package:flutter/material.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/gallery.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

/// A list where every visible clip plays muted, gated by the device's
/// network, power and heat: `mpx`'s device signals reach the feed through
/// `FeedSignals.adapt`, mapping the enums by name.
class FeedPage extends StatefulWidget {
  const FeedPage({required this.signals, required this.clips, super.key});

  final IDeviceSignals signals;

  /// The keys the list cycles through.
  final List<MediaKey> clips;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  static const double _extent = 220;
  static const int _count = 40;

  late final FeedSignals _conditions = FeedSignals.adapt(
    network: widget.signals.network,
    toNetwork: (value) => FeedNetwork.values.byName(value.name),
    powerSaving: widget.signals.powerSaving,
    thermal: widget.signals.thermal,
    toThermal: (value) => FeedThermal.values.byName(value.name),
  );

  // The feed's clips as the viewer's gallery: silent loops.
  late final ListGallery _gallery = ListGallery([
    for (var i = 0; i < _count; i++)
      GalleryItem(
        widget.clips[i % widget.clips.length],
        kind: GalleryMediaKind.animation,
      ),
  ]);

  @override
  void dispose() {
    _gallery.dispose();
    _conditions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder<FeedConditions>(
          valueListenable: _conditions,
          builder: (context, conditions, _) => Text(
            'Feed: ${conditions.network.name}'
            '${conditions.powerSaving ? ', saving power' : ''}',
          ),
        ),
      ),
      // Each clip is a viewer origin: a tap opens the viewer from it.
      body: ViewerOriginScope(
        child: FeedListView(
          itemCount: _count,
          itemExtent: _extent,
          conditions: _conditions,
          itemOf: (index) =>
              FeedItem(widget.clips[index % widget.clips.length]),
          presetOf: (index, profile) => AssetPresets.media(
            size: const Size(360, _extent - 20),
            devicePixelRatio: dpr,
            profile: profile,
          ),
          cellBuilder: (context, index, clip) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: GestureDetector(
                onTap: () => MediaViewer.show(
                  context,
                  source: _gallery,
                  initialIndex: index,
                ),
                child: ViewerOrigin(index: index, child: clip),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
