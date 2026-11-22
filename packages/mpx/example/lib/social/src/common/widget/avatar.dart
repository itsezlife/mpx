import 'package:flutter/material.dart';
import 'package:mpx_core/mpx_core.dart';

/// An account's picture in a circle, its initial under it until it loads.
class Avatar extends StatelessWidget {
  const Avatar({
    required this.name,
    required this.picture,
    this.size = 40,
    super.key,
  });

  final String name;

  /// The picture's media, or null when the account has none.
  final MediaKey? picture;

  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final key = picture;
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colorScheme.secondaryContainer,
        ),
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            Center(
              child: Text(
                initial,
                style: TextStyle(
                  color: colorScheme.onSecondaryContainer,
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (key != null)
              AssetView(
                content: key,
                preset: AssetPresets.round(
                  diameter: size,
                  devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  profile: const AssetProfile(fit: AssetFit.cover),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
