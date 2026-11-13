import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/viewer_actions.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';
import 'package:mpx_ui/src/viewer/viewer_tokens.dart';

/// The chrome the viewer draws over its pages: the top bar (back, title and
/// subtitle, bar actions, the overflow button), the "N of M" counter, the
/// caption and the thumbnail strip, and the overflow menu. It shows and
/// hides with [controls], sliding the top up and the bottom down.
class ViewerChromeOverlay extends StatefulWidget {
  /// Creates the chrome of the item at [index].
  const ViewerChromeOverlay({
    required this.chrome,
    required this.index,
    required this.source,
    required this.controls,
    required this.tokens,
    required this.policy,
    required this.onBack,
    required this.onSelectIndex,
    required this.onAction,
    super.key,
    this.scope,
    this.bottomInset = 0,
  });

  /// What the host fills in.
  final ViewerChrome chrome;

  /// The item shown.
  final int index;

  /// The gallery.
  final GallerySource source;

  /// Whether the chrome shows.
  final ValueListenable<bool> controls;

  /// Colours and type.
  final ViewerTokens tokens;

  /// Timings and layout.
  final ViewerPolicy policy;

  /// The back button.
  final VoidCallback onBack;

  /// A thumbnail was tapped.
  final ValueChanged<int> onSelectIndex;

  /// An action was chosen for [index].
  final void Function(ViewerAction action, int index) onAction;

  /// The cache the thumbnails attach to.
  final AssetCacheScope? scope;

  /// Room left at the bottom for the video controls.
  final double bottomInset;

  @override
  State<ViewerChromeOverlay> createState() => _ViewerChromeOverlayState();
}

class _ViewerChromeOverlayState extends State<ViewerChromeOverlay> {
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controls.addListener(_controlsChanged);
  }

  @override
  void didUpdateWidget(ViewerChromeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controls, widget.controls)) {
      oldWidget.controls.removeListener(_controlsChanged);
      widget.controls.addListener(_controlsChanged);
    }
    if (oldWidget.index != widget.index) _menuOpen = false;
  }

  @override
  void dispose() {
    widget.controls.removeListener(_controlsChanged);
    super.dispose();
  }

  void _controlsChanged() {
    if (!mounted) return;
    setState(() {
      if (!widget.controls.value) _menuOpen = false;
    });
  }

  List<ViewerAction> _actions(GalleryItem item) =>
      widget.chrome.actions?.call(widget.index, item) ?? const [];

  @override
  Widget build(BuildContext context) {
    final item = widget.source.itemAt(widget.index);
    final visible = widget.controls.value;
    final padding = MediaQuery.paddingOf(context);
    final metrics = widget.policy.chrome;
    final actions = item == null ? const <ViewerAction>[] : _actions(item);
    final menu = [
      for (final action in actions)
        if (!action.inBar) action,
    ];
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: _Shown(
            visible: visible,
            slide: -widget.policy.controlsSlide,
            duration: widget.policy.controlsDuration,
            hideDuration: widget.policy.controlsHideDuration,
            child: Column(
              key: const ValueKey('mpx-viewer-top'),
              mainAxisSize: MainAxisSize.min,
              children: [
                _topBar(context, item, actions, menu, padding.top),
                if (widget.source.count > 1) _counter(metrics),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _Shown(
            visible: visible,
            slide: widget.policy.controlsSlide,
            duration: widget.policy.controlsDuration,
            hideDuration: widget.policy.controlsHideDuration,
            child: Column(
              key: const ValueKey('mpx-viewer-bottom'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item != null) ?_caption(context, item, metrics),
                if (widget.chrome.thumbnails && widget.source.count > 1)
                  _strip(metrics),
                SizedBox(height: padding.bottom + widget.bottomInset),
              ],
            ),
          ),
        ),
        if (_menuOpen && visible) ..._menu(menu, padding.top, metrics),
      ],
    );
  }

  Widget _topBar(
    BuildContext context,
    GalleryItem? item,
    List<ViewerAction> actions,
    List<ViewerAction> menu,
    double top,
  ) {
    final tokens = widget.tokens;
    final metrics = widget.policy.chrome;
    final chrome = widget.chrome;
    final title = item == null
        ? null
        : chrome.title?.call(context, widget.index, item);
    final subtitle = item == null
        ? null
        : chrome.subtitle?.call(context, widget.index, item);
    return ColoredBox(
      color: tokens.barFill,
      child: Padding(
        padding: EdgeInsets.only(top: top),
        child: SizedBox(
          height: metrics.topBarHeight,
          child: Row(
            children: [
              _button(
                key: const ValueKey('mpx-viewer-back'),
                label: chrome.strings.back,
                icon: chrome.backIcon ?? _Glyph.back(tokens.foreground),
                onTap: widget.onBack,
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      DefaultTextStyle(
                        style: tokens.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: title,
                      ),
                    if (subtitle != null)
                      DefaultTextStyle(
                        style: tokens.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: subtitle,
                      ),
                  ],
                ),
              ),
              for (final action in actions)
                if (action.inBar)
                  _button(
                    label: action.label,
                    icon: action.icon!,
                    onTap: () => widget.onAction(action, widget.index),
                  ),
              if (menu.isNotEmpty)
                _button(
                  key: const ValueKey('mpx-viewer-more'),
                  label: chrome.strings.more,
                  icon: chrome.moreIcon ?? _Glyph.more(tokens.foreground),
                  onTap: () => setState(() => _menuOpen = !_menuOpen),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button({
    required String label,
    required Widget icon,
    required VoidCallback onTap,
    Key? key,
  }) {
    final extent = widget.policy.chrome.topBarHeight;
    return Semantics(
      key: key,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: extent,
          child: Center(
            child: IconTheme(
              data: IconThemeData(color: widget.tokens.foreground, size: 24),
              child: icon,
            ),
          ),
        ),
      ),
    );
  }

  Widget _counter(ViewerChromeMetrics metrics) {
    final text = widget.chrome.strings.counter(
      widget.index + 1,
      widget.source.count,
    );
    return Padding(
      padding: EdgeInsets.only(top: metrics.counterGap),
      child: Container(
        key: const ValueKey('mpx-viewer-counter'),
        height: metrics.counterHeight,
        padding: EdgeInsets.symmetric(horizontal: metrics.counterPadding),
        decoration: BoxDecoration(
          color: widget.tokens.barFill,
          borderRadius: BorderRadius.circular(metrics.counterRadius),
        ),
        alignment: Alignment.center,
        child: Text(text, style: widget.tokens.counter),
      ),
    );
  }

  Widget? _caption(
    BuildContext context,
    GalleryItem item,
    ViewerChromeMetrics metrics,
  ) {
    final caption = widget.chrome.caption?.call(context, widget.index, item);
    if (caption == null) return null;
    final style = widget.tokens.caption;
    final line = (style.fontSize ?? 16) * (style.height ?? 1.2);
    // Up to the metric's line count shows at once; a longer caption scrolls.
    final maxHeight =
        line * metrics.captionMaxLines + metrics.captionPadding.vertical;
    return ColoredBox(
      key: const ValueKey('mpx-viewer-caption'),
      color: widget.tokens.barFill,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxHeight,
          minWidth: double.infinity,
        ),
        child: SingleChildScrollView(
          padding: metrics.captionPadding,
          child: DefaultTextStyle(style: style, child: caption),
        ),
      ),
    );
  }

  Widget _strip(ViewerChromeMetrics metrics) {
    final thumb = metrics.thumbSize;
    return SizedBox(
      key: const ValueKey('mpx-viewer-strip'),
      height: metrics.stripHeight,
      child: ColoredBox(
        color: widget.tokens.barFill,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: widget.source.count,
          padding: EdgeInsets.only(top: metrics.thumbTop),
          itemBuilder: (context, index) {
            final item = widget.source.itemAt(index);
            final current = index == widget.index;
            final aspect = switch (item?.size) {
              final size? when !size.isEmpty => size.width / size.height,
              _ => thumb.width / thumb.height,
            };
            final width = current
                ? math.min(metrics.currentThumbMaxWidth, thumb.height * aspect)
                : thumb.width;
            final gap = current
                ? metrics.currentThumbPadding
                : metrics.thumbSpacing / 2;
            return GestureDetector(
              key: ValueKey(('mpx-viewer-thumb', index)),
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onSelectIndex(index),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: gap),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(metrics.thumbRadius),
                    child: SizedBox(
                      width: width,
                      height: thumb.height,
                      child: item == null
                          ? ColoredBox(color: widget.tokens.placeholder)
                          : ContentView(
                              content: item.key,
                              scope: widget.scope,
                              preset: AssetPresets.media(
                                size: Size(width, thumb.height),
                                devicePixelRatio:
                                    MediaQuery.maybeDevicePixelRatioOf(
                                      context,
                                    ) ??
                                    1,
                                profile: const AssetProfile(
                                  fit: AssetFit.cover,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _menu(
    List<ViewerAction> menu,
    double top,
    ViewerChromeMetrics metrics,
  ) {
    final tokens = widget.tokens;
    return [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _menuOpen = false),
        ),
      ),
      Positioned(
        top: top + 4,
        right: 4,
        child: Container(
          key: const ValueKey('mpx-viewer-menu'),
          constraints: BoxConstraints(minWidth: metrics.menuMinWidth),
          color: tokens.menuBackground,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final action in menu)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() => _menuOpen = false);
                      widget.onAction(action, widget.index);
                    },
                    child: SizedBox(
                      height: metrics.menuItemHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            if (action.icon != null) ...[
                              IconTheme(
                                data: IconThemeData(
                                  color: tokens.menuForeground,
                                  size: 24,
                                ),
                                child: action.icon!,
                              ),
                              const SizedBox(width: 16),
                            ],
                            Text(
                              action.label,
                              style: tokens.subtitle.copyWith(
                                color: tokens.menuForeground,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

// Slides [child] by [slide] and fades it out when not [visible], and stops it
// taking touches.
class _Shown extends StatelessWidget {
  const _Shown({
    required this.visible,
    required this.slide,
    required this.duration,
    required this.hideDuration,
    required this.child,
  });

  final bool visible;
  final double slide;
  final Duration duration;
  final Duration hideDuration;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: TweenAnimationBuilder<double>(
      tween: Tween(end: visible ? 1 : 0),
      duration: visible ? duration : hideDuration,
      builder: (context, t, child) => Transform.translate(
        offset: Offset(0, slide * (1 - t)),
        child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
      ),
      child: child,
    ),
  );
}

// A plain glyph for a host that brings no icons: a back arrow or three dots.
class _Glyph extends StatelessWidget {
  const _Glyph.back(this.color) : _back = true;

  const _Glyph.more(this.color) : _back = false;

  final Color color;
  final bool _back;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(24),
    painter: _GlyphPainter(color, back: _back),
  );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.color, {required this.back});

  final Color color;
  final bool back;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final w = size.width;
    final h = size.height;
    if (back) {
      canvas
        ..drawLine(Offset(w * 0.2, h / 2), Offset(w * 0.8, h / 2), paint)
        ..drawLine(Offset(w * 0.2, h / 2), Offset(w * 0.45, h * 0.25), paint)
        ..drawLine(Offset(w * 0.2, h / 2), Offset(w * 0.45, h * 0.75), paint);
    } else {
      paint.style = PaintingStyle.fill;
      for (final y in [0.25, 0.5, 0.75]) {
        canvas.drawCircle(Offset(w / 2, h * y), 2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.back != back;
}
