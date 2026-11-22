import 'package:flutter/material.dart';
import 'package:mpx_core/mpx_core.dart';

/// SVG drawn as one more media kind: the same `ContentView`, locator and
/// descriptor as every other tile, with `SvgDecoder` registered for
/// `MediaKind.vectorImage`.
///
/// Three tiles: an SVG from the example's own origin, one from the public
/// network (through the real network, cached by the bytes store like any
/// download), and a one-colour icon decoded as a template and tinted by the
/// view.
abstract final class SvgDemo {
  /// The bundled mark, served by the example's origin.
  static const MediaKey bundled = MediaKey.remote('svg-mark');

  /// A one-colour icon: drawn as a template, it takes the view's tint.
  static const MediaKey icon = MediaKey.remote('svg-icon');

  /// A public SVG on the network. Its key is its URL only because the
  /// example has no backend to name it; a host keys media by its own ids.
  static const MediaKey network = MediaKey.external(_networkUrl);

  static const String _networkUrl =
      'https://dev.w3.org/SVG/tools/svgweb/samples/svg-files/tiger.svg';

  /// What the host knows of each: that it is a vector image.
  static const List<MediaDescriptor> descriptors = [
    MediaDescriptor(key: bundled, kind: MediaKind.vectorImage),
    MediaDescriptor(key: network, kind: MediaKind.vectorImage),
    MediaDescriptor(key: icon, kind: MediaKind.vectorImage),
  ];

  /// Where the bytes of [key] are, or null for a key that is not the demo's.
  static String? urlOf(MediaKey key) => switch (key) {
    bundled => 'https://media.example/mark.svg',
    network => _networkUrl,
    icon => 'https://media.example/icon.svg',
    _ => null,
  };
}

/// The demo's tiles in a row.
class SvgDemoRow extends StatelessWidget {
  /// Creates the row.
  const SvgDemoRow({super.key});

  static const double _extent = 96;

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    AssetPreset preset({
      AssetDecodeMode decodeMode = AssetDecodeMode.original,
    }) => AssetPresets.square(
      extent: _extent,
      devicePixelRatio: ratio,
      profile: const AssetProfile(),
      decodeMode: decodeMode,
    );
    Widget tile(String label, Widget picture) => Column(
      children: [
        SizedBox.square(dimension: _extent, child: picture),
        const SizedBox(height: 8),
        Text(label),
      ],
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        tile(
          'Bundled',
          ContentView(content: SvgDemo.bundled, preset: preset()),
        ),
        tile(
          'Network',
          ContentView(content: SvgDemo.network, preset: preset()),
        ),
        tile(
          'Tinted',
          ContentView(
            content: SvgDemo.icon,
            preset: preset(decodeMode: AssetDecodeMode.template),
            tint: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }
}
