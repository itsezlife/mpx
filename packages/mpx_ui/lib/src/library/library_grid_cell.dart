import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_ui/src/library/library_grid_policy.dart';
import 'package:mpx_ui/src/library/library_grid_tokens.dart';
import 'package:mpx_ui/src/viewer/viewer_origin.dart';

/// One cell of the library grid: the thumbnail through the asset cache, the
/// check with its order number, the duration or GIF badge, the subtype
/// marks, and the host's decoration.
///
/// Built by `LibraryGrid`; public so a host's own grid can draw the same
/// cell.
class LibraryGridCell extends StatelessWidget {
  /// Creates a cell of [asset] (null while its page loads).
  const LibraryGridCell({
    required this.asset,
    required this.extent,
    required this.thumbnailPixels,
    required this.policy,
    required this.tokens,
    required this.labels,
    required this.order,
    required this.dimmed,
    required this.onToggle,
    required this.onOpen,
    this.radius = BorderRadius.zero,
    this.decoration,
    this.originIndex,
    super.key,
  });

  /// The asset's index in the gallery a viewer pages, so the picture is the
  /// viewer's origin under a `ViewerOriginScope` (it opens from and closes
  /// to it, and hides while the viewer covers it); null for none.

  /// The asset, or null while its page loads.
  final LibraryAsset? asset;

  /// The cell's side.
  final double extent;

  /// The thumbnail's pixel size.
  final int thumbnailPixels;

  /// The grid's policy.
  final LibraryGridPolicy policy;

  /// Colours and text styles.
  final LibraryGridTokens tokens;

  /// Words.
  final LibraryGridLabels labels;

  /// The 1-based order of the asset in the selection, or null.
  final int? order;

  /// Whether the selection would refuse the asset now.
  final bool dimmed;

  /// Called by a tap on the check.
  final VoidCallback onToggle;

  /// Called by a tap on the picture.
  final VoidCallback onOpen;

  /// The cell's corners (the first row's outer ones on Android).
  final BorderRadius radius;

  /// The host's mark over the picture (a spoiler, say), or null.
  final Widget? decoration;

  /// See the constructor.
  final int? originIndex;

  bool get _selected => order != null;

  @override
  Widget build(BuildContext context) {
    final asset = this.asset;
    if (asset == null) {
      return ClipRRect(
        borderRadius: radius,
        child: ColoredBox(color: tokens.cellPlaceholder),
      );
    }
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    Widget picture = ContentView(
      content: LibraryKeys.thumbnailKeyOf(asset, thumbnailPixels),
      preset: AssetPresets.square(
        extent: extent,
        devicePixelRatio: dpr,
        profile: const AssetProfile(fit: AssetFit.cover),
      ),
    );
    if (originIndex case final index?) {
      picture = ViewerOrigin(
        index: index,
        borderRadius: radius,
        child: picture,
      );
    }
    if (policy.selectedImageScale != 1) {
      picture = AnimatedScale(
        scale: _selected ? policy.selectedImageScale : 1,
        duration: policy.selectionDuration,
        curve: Curves.easeOut,
        child: picture,
      );
    }
    final cell = Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: tokens.cellPlaceholder),
        Semantics(
          label: labels.describe(asset),
          selected: _selected,
          button: true,
          onTapHint: labels.open,
          onTap: onOpen,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: picture,
          ),
        ),
        ?decoration,
        ..._badges(asset),
        PositionedDirectional(
          top: 0,
          end: 0,
          width: policy.checkHitSize,
          height: policy.checkHitSize,
          child: Semantics(
            checked: _selected,
            label: labels.select,
            value: order?.toString(),
            onTap: onToggle,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggle,
              child: Align(
                alignment: AlignmentDirectional.topEnd,
                child: Padding(
                  padding: EdgeInsets.all(
                    math.max(
                      0,
                      (policy.checkHitSize - policy.checkFrame) / 2 - 4,
                    ),
                  ),
                  child: _Check(policy: policy, tokens: tokens, order: order),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return Opacity(
      opacity: dimmed && !_selected ? policy.disabledOpacity : 1,
      child: ClipRRect(borderRadius: radius, child: cell),
    );
  }

  List<Widget> _badges(LibraryAsset asset) {
    final style = TextStyle(
      color: tokens.badgeForeground,
      fontSize: policy.durationFontSize,
      fontWeight: policy.durationFontWeight,
    );
    final text = switch (asset) {
      LibraryAsset(kind: LibraryAssetKind.video, :final duration?) =>
        LibraryGridLabels.formatDuration(duration),
      _ when asset.has(LibraryAssetSubtype.animated) => labels.gif,
      _ => null,
    };
    final marks = policy.subtypeIcons
        ? [
            for (final subtype in const [
              LibraryAssetSubtype.live,
              LibraryAssetSubtype.slowMotion,
              LibraryAssetSubtype.timeLapse,
            ])
              if (asset.has(subtype)) subtype,
          ]
        : const <LibraryAssetSubtype>[];
    if (text == null && marks.isEmpty) return const [];
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final mark in marks)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 3),
            child: CustomPaint(
              size: Size.square(policy.durationFontSize + 3),
              painter: _SubtypePainter(mark, tokens.badgeForeground),
            ),
          ),
        if (text != null) Text(text, style: style, maxLines: 1),
      ],
    );
    if (policy.durationShade) {
      return [
        PositionedDirectional(
          start: 0,
          end: 0,
          bottom: 0,
          height: 26,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [tokens.shade.withValues(alpha: 0), tokens.shade],
              ),
            ),
          ),
        ),
        Align(
          alignment: policy.durationAlignment,
          child: Padding(padding: const EdgeInsets.all(5), child: row),
        ),
      ];
    }
    return [
      Align(
        alignment: policy.durationAlignment,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Container(
            height: 17,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              color: tokens.badgeFill,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Center(widthFactor: 1, child: row),
          ),
        ),
      ),
    ];
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.policy, required this.tokens, this.order});

  final LibraryGridPolicy policy;
  final LibraryGridTokens tokens;
  final int? order;

  @override
  Widget build(BuildContext context) {
    final selected = order != null;
    Widget check = Container(
      width: policy.checkSize,
      height: policy.checkSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? tokens.checkFill : tokens.checkIdleFill,
        border: Border.all(
          color: tokens.checkRing,
          width: (policy.checkFrame - policy.checkSize) / 2 + 1.5,
        ),
      ),
      child: selected
          ? Text('$order', style: tokens.checkNumber, maxLines: 1)
          : null,
    );
    if (policy.checkSpring > Duration.zero) {
      // A spring on selecting: the check pops from 0.6 and settles.
      check = TweenAnimationBuilder<double>(
        key: ValueKey(selected),
        tween: Tween(begin: selected ? 0.6 : 1, end: 1),
        duration: policy.checkSpring,
        curve: Curves.elasticOut,
        builder: (context, scale, child) =>
            Transform.scale(scale: scale, child: child),
        child: check,
      );
    }
    return SizedBox.square(
      dimension: policy.checkFrame,
      child: Center(child: check),
    );
  }
}

// Small marks for live, slow-motion and time-lapse items, drawn so the
// package needs no icon font.
class _SubtypePainter extends CustomPainter {
  const _SubtypePainter(this.subtype, this.color);

  final LibraryAssetSubtype subtype;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 1;
    switch (subtype) {
      case LibraryAssetSubtype.live:
        canvas
          ..drawCircle(c, r, paint)
          ..drawCircle(c, r * 0.55, paint)
          ..drawCircle(c, r * 0.18, paint..style = PaintingStyle.fill);
      case LibraryAssetSubtype.slowMotion || LibraryAssetSubtype.timeLapse:
        final ticks = subtype == LibraryAssetSubtype.slowMotion ? 12 : 24;
        for (var i = 0; i < ticks; i++) {
          final a = 2 * math.pi * i / ticks;
          final d = Offset(math.cos(a), math.sin(a));
          canvas.drawLine(c + d * (r * 0.7), c + d * r, paint);
        }
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(_SubtypePainter old) =>
      old.subtype != subtype || old.color != color;
}
