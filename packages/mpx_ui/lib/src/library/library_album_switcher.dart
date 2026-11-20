import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_ui/src/library/library_grid_policy.dart';
import 'package:mpx_ui/src/library/library_grid_tokens.dart';
import 'package:mpx_ui/src/text/mpx_text_root.dart';

/// The library album switcher: an anchor that shows the current album's
/// name and opens the list of albums under it.
///
/// [LibraryGridPolicy.$Android] opens a drop-down of rows with the cover,
/// the name and the count; [LibraryGridPolicy.$IOS] a compact menu from the
/// title, names with their counts and a small cover at the end. Choosing an
/// album calls [onSelected]; the grid then rebinds and scrolls to the top
/// (to the end for an album that `startsAtEnd`).
class LibraryAlbumSwitcher extends StatelessWidget {
  /// Creates the switcher.
  const LibraryAlbumSwitcher({
    required this.albums,
    required this.selected,
    required this.onSelected,
    required this.labels,
    this.policy = LibraryGridPolicy.$Android,
    this.tokens = const LibraryGridTokens(),
    super.key,
  });

  /// The albums, in the library's order.
  final List<LibraryAlbum> albums;

  /// The album shown.
  final LibraryAlbum selected;

  /// Called with the album chosen.
  final ValueChanged<LibraryAlbum> onSelected;

  /// Words.
  final LibraryPickerLabels labels;

  /// Android's drop-down or iOS's menu.
  final LibraryGridPolicy policy;

  /// Colours and text styles.
  final LibraryGridTokens tokens;

  bool get _ios => identical(policy, LibraryGridPolicy.$IOS);

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: labels.titleOf(selected),
    child: GestureDetector(
      key: const ValueKey('mpx-album-switcher'),
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_open(context)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                labels.titleOf(selected),
                style: tokens.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // `$Android`: the drop-down triangle, a 10 x 5 filled arrow in a
            // 24 box, right after the title. `$IOS`: a chevron 5 after it,
            // at 40% of the title's colour.
            if (_ios)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 5),
                child: Opacity(
                  opacity: 0.4,
                  child: CustomPaint(
                    key: const ValueKey('mpx-album-arrow'),
                    size: const Size(10, 6),
                    painter: _Chevron(
                      tokens.title.color ?? const Color(0xFFFFFFFF),
                    ),
                  ),
                ),
              )
            else
              CustomPaint(
                key: const ValueKey('mpx-album-arrow'),
                size: const Size.square(24),
                painter: _DropTriangle(
                  tokens.title.color ?? const Color(0xFFFFFFFF),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final text = MpxTextRoot.styleOf(context);
    final chosen = await Navigator.of(context).push<LibraryAlbum>(
      PageRouteBuilder<LibraryAlbum>(
        opaque: false,
        barrierDismissible: true,
        barrierColor: const Color(0x33000000),
        transitionDuration: const Duration(milliseconds: 150),
        reverseTransitionDuration: const Duration(milliseconds: 100),
        pageBuilder: (context, _, _) => MpxTextRoot.over(
          text,
          _AlbumMenu(
            anchor: anchor,
            albums: albums,
            selected: selected,
            labels: labels,
            tokens: tokens,
            ios: _ios,
          ),
        ),
        transitionsBuilder: (context, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
    if (chosen != null && chosen.id != selected.id) onSelected(chosen);
  }
}

class _AlbumMenu extends StatelessWidget {
  const _AlbumMenu({
    required this.anchor,
    required this.albums,
    required this.selected,
    required this.labels,
    required this.tokens,
    required this.ios,
  });

  final Rect anchor;
  final List<LibraryAlbum> albums;
  final LibraryAlbum selected;
  final LibraryPickerLabels labels;
  final LibraryGridTokens tokens;
  final bool ios;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.maybeSizeOf(context) ?? const Size(400, 800);
    final cover = ios ? 28.0 : 40.0;
    final row = ios ? 44.0 : 56.0;
    final width = ios ? 250.0 : 280.0;
    final left = anchor.left.clamp(8.0, screen.width - width - 8);
    final maxHeight = screen.height - anchor.bottom - 16;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final scope = AssetCacheProvider.maybeOf(context);
    final pixels = (cover * dpr).ceil();
    Widget coverOf(LibraryAlbum album) {
      final asset = album.cover;
      // A library key resolves only through its descriptor: tell the cache
      // the cover's thumbnail, as the grid tells its cells', or the cover
      // stays a placeholder.
      if (asset != null) {
        scope?.know(LibraryKeys.thumbnailDescriptorOf(asset, pixels));
      }
      return SizedBox.square(
        dimension: cover,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ios ? 4 : 6),
          child: asset == null
              ? ColoredBox(color: tokens.cellPlaceholder)
              : ContentView(
                  content: LibraryKeys.thumbnailKeyOf(asset, pixels),
                  preset: AssetPresets.square(
                    extent: cover,
                    devicePixelRatio: dpr,
                    profile: const AssetProfile(fit: AssetFit.cover),
                  ),
                ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned(
          left: left,
          top: anchor.bottom + 4,
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight.clamp(row, 600)),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.menuFill,
                borderRadius: BorderRadius.circular(ios ? 12 : 8),
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  for (final album in albums)
                    Semantics(
                      button: true,
                      selected: album.id == selected.id,
                      label: '${labels.titleOf(album)}, ${album.count}',
                      child: GestureDetector(
                        key: ValueKey('mpx-album-${album.id.value}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(context).pop(album),
                        child: SizedBox(
                          height: row,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                if (!ios) ...[
                                  coverOf(album),
                                  const SizedBox(width: 12),
                                ],
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        labels.titleOf(album),
                                        style: tokens.text,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        '${album.count}',
                                        style: tokens.secondaryText,
                                      ),
                                    ],
                                  ),
                                ),
                                if (ios) coverOf(album),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DropTriangle extends CustomPainter {
  const _DropTriangle(this.color);

  final Color color;

  // A 10 x 5 triangle pointing down, centred in its box.
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawPath(
      Path()
        ..moveTo(c.dx - 5, c.dy - 2.5)
        ..lineTo(c.dx + 5, c.dy - 2.5)
        ..lineTo(c.dx, c.dy + 2.5)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_DropTriangle old) => old.color != color;
}

class _Chevron extends CustomPainter {
  const _Chevron(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0),
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );

  @override
  bool shouldRepaint(_Chevron old) => old.color != color;
}
